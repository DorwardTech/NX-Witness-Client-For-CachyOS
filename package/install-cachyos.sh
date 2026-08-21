#!/usr/bin/env bash
#
# Installer for the Nx Witness / Nx Meta open-source VMS Desktop Client on CachyOS (Arch).
#
# Run as root from the directory that contains this script:
#     sudo ./install-cachyos.sh
#
# Options:
#     --no-deps      skip the pacman runtime dependency step
#     --no-ini       do not write ~/.config/nx_ini/desktop_client.ini
#
# The script is self-describing: it discovers the company id, version and client binary
# name from the bundled opt/ tree, so it is not tied to one customization or build number.
#
set -euo pipefail

SKIP_DEPS=0
SKIP_INI=0
for arg in "$@"; do
    case "$arg" in
        --no-deps) SKIP_DEPS=1 ;;
        --no-ini)  SKIP_INI=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root (use: sudo ./install-cachyos.sh)"

# ------------------------------------------------------------------------------------------------
# Discover what we are installing.
#
# Upstream layout (vms/distribution/deb/client/build_distribution.sh):
#     opt/<companyId>/client/<version>/bin/{client,<installerName>_client,applauncher,...}
#     opt/<companyId>/client/<version>/lib/...
# ------------------------------------------------------------------------------------------------
CLIENT_WRAPPER="$(find "$HERE/opt" -type f -path '*/client/*/bin/client' 2>/dev/null | head -1)"
[ -n "$CLIENT_WRAPPER" ] || die "no opt/<company>/client/<version>/bin/client found next to this script"

BIN_DIR="$(dirname "$CLIENT_WRAPPER")"
MODULE_DIR="$(dirname "$BIN_DIR")"
VERSION="$(basename "$MODULE_DIR")"
COMPANY_ID="$(basename "$(dirname "$(dirname "$MODULE_DIR")")")"
# The real ELF client next to the wrapper. cmake/properties.cmake:82 defines this on Linux as
# "${customization.installerName}_client", e.g. metavms_client.
CLIENT_BIN="$(find "$BIN_DIR" -maxdepth 1 -type f -name '*_client' -printf '%f\n' | head -1)"
[ -n "$CLIENT_BIN" ] || die "no *_client executable found in $BIN_DIR"
CUSTOMIZATION="${COMPANY_ID##*-}"

TARGET="/opt/$COMPANY_ID/client/$VERSION"

log "Installing Nx VMS Desktop Client"
note "company id    : $COMPANY_ID"
note "customization : $CUSTOMIZATION"
note "version       : $VERSION"
note "client binary : $CLIENT_BIN"
note "install path  : $TARGET"

# ------------------------------------------------------------------------------------------------
# Runtime dependencies
#
# Translated from upstream vms/distribution/deb/client/deb_dependencies.yaml. These are RUNTIME
# libraries only - building the client is a separate concern and needs none of the build tools.
# ------------------------------------------------------------------------------------------------
RUNTIME_DEPS=(
    # Core graphics / GL   (libegl1, libgl1, libopengl0 -> libglvnd; libglu1-mesa -> glu)
    libglvnd glu mesa
    # Fonts and text
    fontconfig freetype2
    # Audio                (libasound2 -> alsa-lib; libpulse0 + libpulse-mainloop-glib0 -> libpulse)
    alsa-lib libpulse
    # Secrets / keyring
    libsecret
    # X11 and XCB - needed by Qt's "xcb" platform plugin
    libx11 libxcb xcb-util xcb-util-cursor xcb-util-image xcb-util-keysyms
    xcb-util-renderutil xcb-util-wm
    libxext libxfixes libxkbcommon libxkbcommon-x11 libxss
    libxcomposite libxi libxkbfile libxrandr libxrender libxtst
    # Misc
    zlib glib2 dbus expat libxml2 libxslt
    # Qt WebEngine extras
    nspr nss
)

if [ "$SKIP_DEPS" -eq 0 ]; then
    log "Installing runtime dependencies with pacman"
    command -v pacman >/dev/null 2>&1 || die "pacman not found - this installer targets Arch/CachyOS"
    pacman -S --needed --noconfirm "${RUNTIME_DEPS[@]}"
    # Not a hard dependency, but with no fonts installed at all the UI renders blank.
    if ! fc-list 2>/dev/null | grep -q .; then
        note "No fonts detected - installing ttf-dejavu so the UI has something to render with."
        pacman -S --needed --noconfirm ttf-dejavu || true
    fi
else
    log "Skipping dependency installation (--no-deps)"
fi

# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------
log "Copying client tree to $TARGET"
rm -rf "$TARGET"
mkdir -p "$(dirname "$TARGET")"
cp -a "$HERE/opt/$COMPANY_ID/client/$VERSION" "$TARGET"
chmod 755 "$TARGET/bin/client" "$TARGET/bin/$CLIENT_BIN"
[ -f "$TARGET/bin/applauncher" ] && chmod 755 "$TARGET/bin/applauncher"
[ -f "$TARGET/lib/stdcpp/choose_newer_stdcpp.sh" ] && chmod 755 "$TARGET/lib/stdcpp/choose_newer_stdcpp.sh"

if [ -d "$HERE/usr/share/icons" ]; then
    log "Installing icons"
    cp -a "$HERE/usr/share/icons/." /usr/share/icons/
fi

# ------------------------------------------------------------------------------------------------
# Launcher
#
# The launcher also bootstraps desktop_client.ini for whoever runs it. nx_kit resolves the ini
# directory as: $NX_INI_DIR, else $HOME/.config/nx_ini/, else /etc/nx_ini/
# (artifacts/nx_kit/src/nx/kit/ini_config.cpp, determineIniFilesDir()). Because $HOME is set on
# any normal desktop session, /etc/nx_ini is effectively never consulted - so a system-wide file
# is NOT a working substitute, and each user genuinely needs their own. Doing it here means a
# second desktop user does not have to know that.
# ------------------------------------------------------------------------------------------------
log "Installing command-line launcher /usr/local/bin/nxwitness-client"
install -d /usr/local/bin
cat > /usr/local/bin/nxwitness-client <<WRAPPER
#!/bin/sh
# Nx VMS Desktop Client $VERSION (open-source build).
#
# Ensures this user has demoMode=1 in desktop_client.ini, then delegates to the bundled
# wrapper (which sets up the bundled libstdc++ / libOpenGL), see:
#   /opt/$COMPANY_ID/client/$VERSION/bin/client
#
# Without demoMode=1 the client rejects an Nx Witness server with a customization mismatch:
# this build is branded "$CUSTOMIZATION" while an Nx Witness server reports "default".
INI_DIR="\${NX_INI_DIR:-\$HOME/.config/nx_ini}"
INI="\$INI_DIR/desktop_client.ini"
if [ -n "\$INI_DIR" ]; then
    if [ ! -e "\$INI" ]; then
        mkdir -p "\$INI_DIR" 2>/dev/null && printf 'demoMode=1\n' > "\$INI" 2>/dev/null
    elif ! grep -q 'demoMode' "\$INI" 2>/dev/null; then
        printf 'demoMode=1\n' >> "\$INI" 2>/dev/null
    fi
fi
exec "$TARGET/bin/client" "\$@"
WRAPPER
chmod 755 /usr/local/bin/nxwitness-client

log "Installing desktop entry"
install -d /usr/share/applications
ICON_NAME="vmsclient-$CUSTOMIZATION"
cat > /usr/share/applications/nxwitness-client.desktop <<DESKTOP
[Desktop Entry]
Name=Nx Witness Client (Open Source)
GenericName=Video Management System Client
Comment=Connect to an Nx Witness / Nx Meta VMS server
Exec=/usr/local/bin/nxwitness-client %u
Icon=$ICON_NAME
Terminal=false
Type=Application
StartupNotify=true
StartupWMClass=$CUSTOMIZATION
Categories=AudioVideo;Video;Player;Network;
DESKTOP

# The upstream .deb also registers a URI scheme handler so "nx-vms://..." links open the client.
PROTOCOL_DESKTOP="$(grep -rl 'x-scheme-handler/' "$HERE/usr/share/applications" 2>/dev/null | head -1)"
if [ -n "$PROTOCOL_DESKTOP" ]; then
    sed "s|^Exec=.*|Exec=/usr/local/bin/nxwitness-client %u|" "$PROTOCOL_DESKTOP" \
        > "/usr/share/applications/$(basename "$PROTOCOL_DESKTOP")"
    note "URI scheme handler installed: $(basename "$PROTOCOL_DESKTOP")"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -qtf /usr/share/icons/hicolor 2>/dev/null || true

# ------------------------------------------------------------------------------------------------
# desktop_client.ini for the invoking user (the launcher covers everyone else on first run).
#
# Why this is required, from the sources:
#   vms/client/nx_vms_client_desktop/.../application_context.cpp  initializeServerCompatibilityValidator()
#       if (ini().developerMode || ini().demoMode)
#           developerFlags.setFlag(DeveloperFlag::ignoreCustomization);
#       if (ini().isAutoCloudHostDeductionMode())          //< true when demoMode && cloudHost empty
#           developerFlags.setFlag(DeveloperFlag::ignoreCloudHost);
#   vms/libs/nx_vms_common/.../server_compatibility_validator.cpp  isCompatibleCustomization()
#       returns true early when ignoreCustomization is set.
# ------------------------------------------------------------------------------------------------
write_ini() {
    local user="$1" home grp ini_dir ini
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] && [ -d "$home" ] || { note "skipping $user (no home directory)"; return; }
    grp="$(id -gn "$user")"
    ini_dir="$home/.config/nx_ini"
    ini="$ini_dir/desktop_client.ini"
    install -d -o "$user" -g "$grp" "$ini_dir"
    if [ -f "$ini" ] && grep -q 'demoMode' "$ini"; then
        note "$ini already mentions demoMode - leaving it alone"
        return
    fi
    if [ -f "$ini" ]; then
        printf 'demoMode=1\n' >> "$ini"
        note "appended demoMode=1 to existing $ini"
    else
        printf 'demoMode=1\n' > "$ini"
        note "wrote $ini"
    fi
    chown "$user:$grp" "$ini"
}

if [ "$SKIP_INI" -eq 0 ]; then
    log "Writing desktop_client.ini (demoMode=1)"
    TARGET_USER="${SUDO_USER:-}"
    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ]; then
        write_ini "$TARGET_USER"
    else
        note "Could not determine the invoking desktop user (SUDO_USER is unset)."
        note "The launcher will create the file on first run; or do it by hand:"
        note "    mkdir -p ~/.config/nx_ini && echo demoMode=1 > ~/.config/nx_ini/desktop_client.ini"
    fi
else
    log "Skipping desktop_client.ini (--no-ini)"
fi

# ------------------------------------------------------------------------------------------------
log "Done"
cat <<SUMMARY

    Launch from the application menu ("Nx Witness Client (Open Source)")
    or from a terminal:

        nxwitness-client

    Connecting: click "Connect to Server", enter  https://<server-ip>:7001
    and your Nx Witness server credentials.

    Every desktop user needs demoMode=1 in ~/.config/nx_ini/desktop_client.ini.
    The nxwitness-client launcher writes it automatically on first run, so no
    manual step is normally needed. To do it by hand:

        mkdir -p ~/.config/nx_ini
        echo demoMode=1 > ~/.config/nx_ini/desktop_client.ini

    Note that a system-wide /etc/nx_ini/desktop_client.ini does NOT work as a
    substitute: nx_kit only falls back to /etc/nx_ini when \$HOME is unset,
    which is never the case in a desktop session.

SUMMARY
