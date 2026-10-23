#!/usr/bin/env bash
# When downloaded with `curl .../install.sh | bash`, fetch the complete source
# bundle and continue from a real directory so relative assets are available.
INPUT_SCRIPT="${BASH_SOURCE[0]:-/dev/stdin}"
INPUT_DIR="$(cd "$(dirname "$INPUT_SCRIPT")" 2>/dev/null && pwd || true)"
if [[ ! -f "$INPUT_DIR/vietfox/__init__.py" ]]; then
    for tool in curl tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Thiếu lệnh $tool. Hãy cài $tool rồi chạy lại." >&2
            exit 1
        fi
    done
    TEMP_SOURCE="$(mktemp -d)"
    ARCHIVE="$TEMP_SOURCE/vietfox-source.tar.gz"
    echo "Đang tải mã nguồn Vietfox từ GitHub…"
    if ! curl -fL --retry 3 \
        "https://github.com/adfoxtheme/vietfox/archive/refs/heads/main.tar.gz" \
        -o "$ARCHIVE"; then
        rm -rf "$TEMP_SOURCE"
        exit 1
    fi
    if ! tar -xzf "$ARCHIVE" --strip-components=1 -C "$TEMP_SOURCE"; then
        rm -rf "$TEMP_SOURCE"
        exit 1
    fi
    rm -f "$ARCHIVE"
    bash "$TEMP_SOURCE/install.sh" --with-engine "$@"
    STATUS=$?
    rm -rf "$TEMP_SOURCE"
    exit "$STATUS"
fi

# Cài Vietfox (ứng dụng Vietfox + engine Vietfox dựa trên lõi Ngó Sen).
#
#   ./install.sh                     chỉ cài giao diện vào ~/.local
#   ./install.sh --with-engine       cài thêm engine Vietfox vào /usr (cần sudo)
#   ./install.sh --with-engine --force-engine
#                                    bí danh tương thích cũ của --with-engine
#   sudo ./install.sh --system       cài giao diện vào /usr/local
#   ./install.sh --uninstall         gỡ giao diện (thêm --with-engine để gỡ engine)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
WITH_ENGINE=0
UNINSTALL=0

usage() {
    cat <<'EOF'
Cài Vietfox (ứng dụng Vietfox + engine Vietfox dựa trên lõi Ngó Sen).

  ./install.sh                     chỉ cài giao diện vào ~/.local
  ./install.sh --with-engine       cài giao diện và engine vào máy (cần sudo)
  ./install.sh --system            cài giao diện vào /usr/local
  ./install.sh --uninstall         gỡ giao diện (thêm --with-engine để gỡ engine)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --system)
            PREFIX="/usr/local"
            ;;
        --with-engine)
            WITH_ENGINE=1
            ;;
        --force-engine)
            WITH_ENGINE=1
            ;;
        --uninstall)
            UNINSTALL=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Tham số không hợp lệ: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

DATA_DIR="$PREFIX/share/vietfox"
BIN_DIR="$PREFIX/bin"
APPS_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/scalable/apps"
DESKTOP="$APPS_DIR/io.github.vietfox.Vietfox.desktop"
ICON="$ICON_DIR/io.github.vietfox.Vietfox.svg"
SETTINGS_ICON="$ICON_DIR/io.github.vietfox.Settings.svg"
LAUNCHER="$BIN_DIR/vietfox"
DOC_DIR="$PREFIX/share/doc/vietfox"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    SUDO="sudo"
fi

USER_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi

# Nhận diện Distro & Base Codename (Hỗ trợ Ubuntu và Linux Mint)
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
fi

RESOLVED_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
PACKAGE_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# Tìm thư mục chứa prebuilt binary engine phù hợp
find_variant_dir() {
    local base_dir="$SRC_DIR/engine/variants/ubuntu"
    if [[ -d "$base_dir/$RESOLVED_CODENAME/$PACKAGE_ARCH" ]]; then
        echo "$base_dir/$RESOLVED_CODENAME/$PACKAGE_ARCH"
        return 0
    fi
    # Fallback tìm variant tương thích gần nhất nếu tồn tại
    local fallback
    fallback=$(find "$base_dir" -maxdepth 2 -type d -name "$PACKAGE_ARCH" 2>/dev/null | head -n 1 || true)
    if [[ -n "$fallback" && -f "$fallback/libvietfox.so" ]]; then
        echo "$fallback"
        return 0
    fi
    return 1
}

VARIANT_DIR=""
if [[ $WITH_ENGINE -eq 1 && $UNINSTALL -eq 0 ]]; then
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "linuxmint" && "${ID_LIKE:-}" != *"ubuntu"* ]]; then
        echo "Lỗi: Hệ điều hành không thuộc họ Ubuntu/Linux Mint; chưa thể cài đặt." >&2
        exit 1
    fi

    if ! VARIANT_DIR="$(find_variant_dir)"; then
        echo "Lỗi: Không tìm thấy engine Vietfox pre-built cho kiến trúc $PACKAGE_ARCH (codename: $RESOLVED_CODENAME)." >&2
        exit 1
    fi

    if [[ ! -f "$VARIANT_DIR/libvietfox.so" || ! -f "$VARIANT_DIR/libvietfoxmigrate.so" ]]; then
        echo "Bản tải xuống thiếu engine Vietfox hoàn chỉnh ($VARIANT_DIR); chưa cài đặt gì." >&2
        exit 1
    fi

    for legacy_file in \
        /usr/lib/x86_64-linux-gnu/fcitx5/libngosen.so \
        /usr/lib/x86_64-linux-gnu/fcitx5/libngosenmigrate.so \
        /usr/share/fcitx5/addon/ngosen.conf \
        /usr/share/fcitx5/addon/ngosenmigrate.conf \
        /usr/share/fcitx5/inputmethod/ngosen.conf; do
        if [[ -e "$legacy_file" ]] && dpkg-query -S "$legacy_file" >/dev/null 2>&1; then
            echo "$legacy_file thuộc gói hệ thống. Hãy gỡ gói Ngó Sen bằng apt trước khi cài Vietfox:" >&2
            echo "  sudo apt remove fcitx5-ngosen" >&2
            exit 1
        fi
    done
fi

if [[ $UNINSTALL -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    APT_PACKAGES=(python3-gi gir1.2-gtk-4.0 gir1.2-adw-1)
    if [[ $WITH_ENGINE -eq 1 ]]; then
        APT_PACKAGES+=(fcitx5 im-config fcitx5-frontend-gtk3 fcitx5-frontend-gtk4
            fcitx5-frontend-qt5)
        # Bổ sung qt6 nếu repo hiện hành có hỗ trợ
        if apt-cache show fcitx5-frontend-qt6 >/dev/null 2>&1; then
            APT_PACKAGES+=(fcitx5-frontend-qt6)
        fi
    fi
    MISSING_PACKAGES=()
    for package in "${APT_PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
            MISSING_PACKAGES+=("$package")
        fi
    done
    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
        echo "Đang cài các gói cần thiết: ${MISSING_PACKAGES[*]}"
        $SUDO apt-get update
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"
    fi
fi

FORWARD_KEYS_UUID="forward-keys@adfoxtheme.github.io"
FORWARD_KEYS_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$FORWARD_KEYS_UUID"
LEGACY_FORWARD_KEYS_UUID="forward-keys@ngosen.github.io"
LEGACY_FORWARD_KEYS_DIR="$USER_HOME/.local/share/gnome-shell/extensions/$LEGACY_FORWARD_KEYS_UUID"

set_shell_extension_enabled() {
    local uuid="$1" action="$2" current updated
    command -v gsettings >/dev/null 2>&1 || return 2
    current="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null)" || return 2
    updated="$(python3 - "$current" "$uuid" "$action" <<'PY'
import ast
import sys

raw, uuid, action = sys.argv[1:]
if raw.startswith("@as "):
    raw = raw[4:]
try:
    extensions = ast.literal_eval(raw)
except (SyntaxError, ValueError):
    raise SystemExit(2)
if not isinstance(extensions, list) or not all(isinstance(item, str) for item in extensions):
    raise SystemExit(2)
if action == "enable" and uuid not in extensions:
    extensions.append(uuid)
elif action == "disable":
    extensions = [item for item in extensions if item != uuid]
print("[" + ", ".join(repr(item) for item in extensions) + "]")
PY
    )" || return 2
    [[ "$updated" != "$current" ]] || return 0
    gsettings set org.gnome.shell enabled-extensions "$updated" >/dev/null 2>&1 || return 2
    return 0
}

configure_desktop_input_env() {
    local config_dir="$USER_HOME/.config"
    local env_dir="$config_dir/environment.d"
    local env_file="$env_dir/90-vietfox.conf"
    local pam_env="$USER_HOME/.pam_environment"
    local autostart_dir="$config_dir/autostart"
    local autostart_file="$autostart_dir/org.fcitx.Fcitx5.desktop"

    # Cấu hình biến môi trường Fcitx5 (Hỗ trợ systemd environment.d và Cinnamon session)
    install -d "$env_dir"
    if [[ ! -f "$env_file" ]]; then
        cat > "$env_file" <<'EOF'
# Managed by Vietfox installer
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF
    fi

    # Thêm fallback vào ~/.xprofile cho Cinnamon / X11 nếu chưa có
    local xprofile="$USER_HOME/.xprofile"
    if ! grep -qs 'GTK_IM_MODULE=fcitx' "$xprofile" 2>/dev/null; then
        cat >> "$xprofile" <<'EOF'
# Managed by Vietfox installer
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
EOF
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$xprofile" 2>/dev/null || true
    fi

    # Đảm bảo Fcitx5 autostart trên session Cinnamon
    if [[ ! -e "$autostart_file" && -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
        install -d "$autostart_dir"
        cp /usr/share/applications/org.fcitx.Fcitx5.desktop "$autostart_file"
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$autostart_dir" 2>/dev/null || true
        echo "Đã thêm Fcitx5 vào danh sách khởi động cùng hệ thống."
    fi
}

if [[ $UNINSTALL -eq 1 ]]; then
    if [[ -f "$FORWARD_KEYS_DIR/.vietfox-managed" ]]; then
        set_shell_extension_enabled "$FORWARD_KEYS_UUID" disable || true
        rm -rf "$FORWARD_KEYS_DIR"
    fi
    if [[ -f "$LEGACY_FORWARD_KEYS_DIR/.vietfox-managed" ]]; then
        set_shell_extension_enabled "$LEGACY_FORWARD_KEYS_UUID" disable || true
        rm -rf "$LEGACY_FORWARD_KEYS_DIR"
    fi
    ENV_FILE="$USER_HOME/.config/environment.d/90-vietfox.conf"
    [[ -f "$ENV_FILE" ]] && rm -f "$ENV_FILE"
    
    USER_AUTOSTART="$USER_HOME/.config/autostart/org.fcitx.Fcitx5.desktop"
    [[ -f "$USER_AUTOSTART" ]] && rm -f "$USER_AUTOSTART"

    SETTINGS_LAUNCHER="/usr/bin/fcitx5-ngosen-settings"
    $SUDO rm -f /usr/share/icons/hicolor/scalable/apps/io.github.vietfox.Settings.svg
    $SUDO rm -f /usr/share/icons/hicolor/scalable/apps/io.github.vietfox.Menu.*.svg
    $SUDO rm -f /usr/share/icons/hicolor/scalable/actions/vietfox-*.svg
    $SUDO gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
    if [[ -f "$SETTINGS_LAUNCHER" ]] && grep -q '^# Managed by Vietfox installer$' "$SETTINGS_LAUNCHER"; then
        $SUDO rm -f "$SETTINGS_LAUNCHER"
    fi
    if [[ $WITH_ENGINE -eq 1 ]]; then
        if [[ -f /usr/bin/vietfox ]] && grep -q '^# Managed by Vietfox installer$' /usr/bin/vietfox; then
            $SUDO rm -f /usr/bin/vietfox
        fi
        case "$PACKAGE_ARCH" in
            amd64|x86_64) ENGINE_TRIPLET="x86_64-linux-gnu" ;;
            arm64|aarch64) ENGINE_TRIPLET="aarch64-linux-gnu" ;;
            *) ENGINE_TRIPLET="" ;;
        esac
        if [[ -n "$ENGINE_TRIPLET" ]]; then
            $SUDO rm -f "/usr/lib/$ENGINE_TRIPLET/fcitx5/libvietfox.so" \
                "/usr/lib/$ENGINE_TRIPLET/fcitx5/libvietfoxmigrate.so" \
                /usr/share/fcitx5/addon/vietfox.conf \
                /usr/share/fcitx5/addon/vietfoxmigrate.conf \
                /usr/share/fcitx5/inputmethod/vietfox.conf \
                /usr/share/locale/vi/LC_MESSAGES/fcitx5-vietfox.mo
        fi
        $SUDO rm -f /usr/share/icons/hicolor/scalable/apps/fcitx-vietfox*.svg \
            /usr/share/icons/hicolor/scalable/status/fcitx-vietfox*.svg
        $SUDO gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi
    rm -rf "$DATA_DIR"
    rm -f "$LAUNCHER" "$DESKTOP" "$ICON" "$SETTINGS_ICON"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" || true
    echo "Đã gỡ bỏ Vietfox hoàn tất."
    exit 0
fi

if ! python3 - <<'PY'
import sys
try:
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Gtk, Adw
except Exception as error:
    print(f"Thiếu thư viện: {error}", file=sys.stderr)
    sys.exit(1)
PY
then
    echo "Lỗi: Cần PyGObject, GTK 4 và libadwaita 1 để mở giao diện cài đặt Vietfox."
    echo "Chạy lệnh: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1"
    exit 1
fi

# ---------------------------------------------------------------- Giao diện
install -d "$DATA_DIR" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR" "$DOC_DIR"
rm -rf "$DATA_DIR/vietfox" "$DATA_DIR/data"
cp -r "$SRC_DIR/vietfox" "$DATA_DIR/vietfox"
cp -r "$SRC_DIR/data" "$DATA_DIR/data"
find "$DATA_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} +
cp "$SRC_DIR/data/io.github.vietfox.Vietfox.svg" "$ICON"
cp "$SRC_DIR/data/io.github.vietfox.Settings.svg" "$SETTINGS_ICON"
sed "s|^Exec=.*|Exec=$LAUNCHER|" \
    "$SRC_DIR/data/io.github.vietfox.Vietfox.desktop" > "$DESKTOP"

# Thiết lập biến môi trường Desktop
if [[ $WITH_ENGINE -eq 1 ]]; then
    configure_desktop_input_env

    # Nếu đang dùng GNOME Shell (Ubuntu gốc), cấu hình extension. Trên Linux Mint Cinnamon, bước này tự động bỏ qua.
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && command -v gnome-shell >/dev/null 2>&1; then
        GNOME_SHELL_VERSION="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
        if [[ -d "$SRC_DIR/gnome-shell/$FORWARD_KEYS_UUID" ]]; then
            install -d "$FORWARD_KEYS_DIR"
            install -m 644 "$SRC_DIR/gnome-shell/$FORWARD_KEYS_UUID/extension.js" "$FORWARD_KEYS_DIR/extension.js"
            install -m 644 "$SRC_DIR/gnome-shell/$FORWARD_KEYS_UUID/metadata.json" "$FORWARD_KEYS_DIR/metadata.json"
            touch "$FORWARD_KEYS_DIR/.vietfox-managed"
            set_shell_extension_enabled "$FORWARD_KEYS_UUID" enable || true
        fi
    fi
fi

cat > "$LAUNCHER" <<EOF
#!/bin/sh
export PYTHONPATH="$DATA_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m vietfox "\$@"
EOF
chmod +x "$LAUNCHER"
cp "$SRC_DIR/LICENSE" "$DOC_DIR/LICENSE" 2>/dev/null || true
[[ -f "$SRC_DIR/engine/COPYRIGHT" ]] && cp "$SRC_DIR/engine/COPYRIGHT" "$DOC_DIR/engine-COPYRIGHT" || true

# ------------------------------------------------------------------- Engine
install_settings_launcher() {
    local settings_launcher="/usr/bin/fcitx5-ngosen-settings"
    $SUDO install -D -m 644 "$SRC_DIR/data/io.github.vietfox.Settings.svg" \
        /usr/share/icons/hicolor/scalable/apps/io.github.vietfox.Settings.svg
    $SUDO rm -f /usr/share/icons/hicolor/scalable/apps/io.github.vietfox.Menu.*.svg
    $SUDO rm -f /usr/share/icons/hicolor/scalable/actions/vietfox-*.svg
    $SUDO gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
    if [[ -e "$settings_launcher" ]] && ! grep -q '^# Managed by Vietfox installer$' "$settings_launcher"; then
        return 0
    fi

    local quoted_launcher launcher_script
    printf -v quoted_launcher '%q' "$LAUNCHER"
    launcher_script=$(mktemp)
    cat > "$launcher_script" <<EOF
#!/bin/sh
# Managed by Vietfox installer
user_launcher="\${HOME}/.local/bin/vietfox"
if [ -x "\$user_launcher" ]; then
    exec "\$user_launcher" "\$@"
fi
exec $quoted_launcher "\$@"
EOF
    $SUDO install -m 755 "$launcher_script" "$settings_launcher"
    rm -f "$launcher_script"
}

install_engine() {
    local arch_triplet libdir sharedir
    case "$PACKAGE_ARCH" in
        amd64|x86_64) arch_triplet="x86_64-linux-gnu" ;;
        arm64|aarch64) arch_triplet="aarch64-linux-gnu" ;;
        *)
            echo "Kiến trúc $PACKAGE_ARCH chưa được hỗ trợ." >&2
            return 1
            ;;
    esac

    libdir="/usr/lib/$arch_triplet/fcitx5"
    sharedir="/usr/share/fcitx5"

    echo "Cài engine Vietfox ($VARIANT_DIR) vào $libdir…"
    $SUDO install -d "$libdir" "$sharedir/addon" "$sharedir/inputmethod" "$sharedir/ngosen"
    $SUDO install -m 644 "$VARIANT_DIR/libvietfox.so" "$libdir/"
    $SUDO install -m 644 "$VARIANT_DIR/libvietfoxmigrate.so" "$libdir/"
    $SUDO install -m 644 "$SRC_DIR/engine/share/fcitx5/addon/vietfox.conf" "$sharedir/addon/"
    $SUDO install -m 644 "$SRC_DIR/engine/share/fcitx5/addon/vietfoxmigrate.conf" "$sharedir/addon/"
    $SUDO install -m 644 "$SRC_DIR/engine/share/fcitx5/inputmethod/vietfox.conf" "$sharedir/inputmethod/"
    
    $SUDO rm -f "$libdir/libngosen.so" "$libdir/libngosenmigrate.so" \
        "$sharedir/addon/ngosen.conf" "$sharedir/addon/ngosenmigrate.conf" \
        "$sharedir/inputmethod/ngosen.conf"
        
    $SUDO cp -a "$SRC_DIR/engine/share/icons/." /usr/share/icons/ 2>/dev/null || true
    $SUDO rm -f /usr/share/icons/hicolor/scalable/actions/vietfox-*.svg
    $SUDO gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
    
    if [[ -f "$SRC_DIR/engine/share/locale/vi/LC_MESSAGES/fcitx5-vietfox.mo" ]]; then
        $SUDO install -D -m 644 "$SRC_DIR/engine/share/locale/vi/LC_MESSAGES/fcitx5-vietfox.mo" \
            /usr/share/locale/vi/LC_MESSAGES/fcitx5-vietfox.mo
    fi
    if [[ -f "$SRC_DIR/engine/share/fcitx5/vietfox/vietnamese.cm.dict" ]]; then
        $SUDO install -m 644 "$SRC_DIR/engine/share/fcitx5/vietfox/vietnamese.cm.dict" "$sharedir/ngosen/"
    fi

    local engine_lib="$libdir/libvietfox.so"
    if ldd "$engine_lib" 2>/dev/null | grep -q "not found"; then
        echo "Cảnh báo: Engine libvietfox.so thiếu thư viện liên kết:" >&2
        ldd "$engine_lib" | grep "not found" >&2
    fi

    local launcher_script quoted_launcher
    printf -v quoted_launcher '%q' "$LAUNCHER"
    launcher_script=$(mktemp)
    cat > "$launcher_script" <<EOF
#!/bin/sh
# Managed by Vietfox installer
user_launcher="\${HOME}/.local/bin/vietfox"
if [ -x "\$user_launcher" ]; then
    exec "\$user_launcher" "\$@"
fi
exec $quoted_launcher "\$@"
EOF
    $SUDO install -m 755 "$launcher_script" /usr/bin/vietfox
    rm -f "$launcher_script"

    # Thiết lập Fcitx5 qua im-config
    if command -v im-config >/dev/null 2>&1; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "$SUDO_USER" im-config -n fcitx5
        else
            im-config -n fcitx5
        fi
        echo "Đã thiết lập Fcitx5 làm bộ gõ mặc định."
    fi
}

if [[ $WITH_ENGINE -eq 1 ]]; then
    install_engine
elif dpkg -s fcitx5-ngosen >/dev/null 2>&1 || [[ -f "/usr/lib/$(uname -m)-linux-gnu/fcitx5/libngosen.so" ]]; then
    install_settings_launcher
else
    echo
    echo "Lưu ý: chưa cài engine Vietfox. Muốn cài kèm, chạy lại với --with-engine."
fi

# ------------------------------------------------- Kích hoạt trong Fcitx5 profile
enable_input_method() {
    local profile="$USER_HOME/.config/fcitx5/profile"
    local input_method="${1:-ngosen}"
    if [[ ! -f "$profile" ]]; then
        mkdir -p "$(dirname "$profile")"
        cat > "$profile" <<EOF
[Groups/0]
Name="Mặc định"
Default Layout=us
DefaultIM=$input_method

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=$input_method
Layout=

[GroupOrder]
0="Mặc định"
EOF
        echo "Đã khởi tạo profile Fcitx5 và chọn Vietfox làm bộ gõ."
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$(dirname "$profile")" 2>/dev/null || true
        return 0
    fi
    python3 - "$profile" "$input_method" <<'PY'
import re
import sys

path = sys.argv[1]
input_method = sys.argv[2]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
start = next((i for i, line in enumerate(lines) if line.strip() == "[Groups/0]"), None)
if start is None:
    sys.exit(0)

in_group = False
has_method = False
has_default = False
indices = []
for index, line in enumerate(lines):
    if line.startswith("["):
        in_group = line == "[Groups/0]" or line.startswith("[Groups/0/Items/")
        match = re.fullmatch(r"\[Groups/0/Items/(\d+)\]", line)
        if match:
            indices.append(int(match.group(1)))
    if not in_group:
        continue
    if line.startswith("DefaultIM="):
        has_default = True
        if input_method == "vietfox" and line != "DefaultIM=vietfox":
            lines[index] = "DefaultIM=vietfox"
    if line == f"Name={input_method}":
        has_method = True
    elif input_method == "vietfox" and line == "Name=ngosen":
        lines[index] = "Name=vietfox"
        has_method = True

if not has_method:
    new_index = max(indices, default=-1) + 1
    insert_at = next((i for i, line in enumerate(lines) if line == "[GroupOrder]"), len(lines))
    if insert_at > 0 and lines[insert_at - 1] != "":
        lines.insert(insert_at, "")
        insert_at += 1
    lines[insert_at:insert_at] = [f"[Groups/0/Items/{new_index}]", f"Name={input_method}", "Layout="]

if not has_default:
    group_end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    lines.insert(group_end, f"DefaultIM={input_method}")

open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$profile" 2>/dev/null || true
}

PROFILE="$USER_HOME/.config/fcitx5/profile"
INPUT_METHOD_ID="ngosen"
if [[ -f "/usr/share/fcitx5/inputmethod/vietfox.conf" ]]; then
    INPUT_METHOD_ID="vietfox"
fi

if command -v fcitx5 >/dev/null && [[ -f "/usr/share/fcitx5/inputmethod/$INPUT_METHOD_ID.conf" ]]; then
    FCITX5_WAS_RUNNING=0
    if pgrep -x fcitx5 >/dev/null 2>&1; then
        FCITX5_WAS_RUNNING=1
        fcitx5-remote -e >/dev/null 2>&1 || true
        for _ in {1..10}; do
            pgrep -x fcitx5 >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
    enable_input_method "$INPUT_METHOD_ID"
    FCITX5_CONFIG="$USER_HOME/.config/fcitx5/config"
    if ! grep -qs '^\[Hotkey/TriggerKeys\]$' "$FCITX5_CONFIG" 2>/dev/null; then
        install -d "$(dirname "$FCITX5_CONFIG")"
        cat >> "$FCITX5_CONFIG" <<'EOF'

[Hotkey/TriggerKeys]
0=Control+Shift_L
1=Control+Shift_R
2=Shift+Control_L
3=Shift+Control_R
EOF
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$(dirname "$FCITX5_CONFIG")" 2>/dev/null || true
    fi
    if [[ $FCITX5_WAS_RUNNING -eq 1 ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "$SUDO_USER" fcitx5 -d >/dev/null 2>&1 || true
        else
            fcitx5 -d >/dev/null 2>&1 || true
        fi
    fi
fi

# ------------------------------------------------------------------- Hoàn tất
if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$APPS_DIR" || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Đã cài đặt Vietfox hoàn tất vào $PREFIX."
echo "Để chạy cấu hình: $LAUNCHER"
