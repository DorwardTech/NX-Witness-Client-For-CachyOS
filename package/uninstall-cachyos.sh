#!/usr/bin/env bash
#
# Uninstaller for the Nx Witness / Nx Meta open-source VMS Desktop Client on CachyOS.
#
#     sudo ./uninstall-cachyos.sh            # remove the client, keep per-user settings
#     sudo ./uninstall-cachyos.sh --purge    # also remove ~/.config/nx_ini/desktop_client.ini
#
# Runtime libraries installed with pacman are NOT removed - other packages may need them.
# Remove leftovers yourself with:  sudo pacman -Rns $(pacman -Qdtq)
#
set -euo pipefail

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root (use: sudo ./uninstall-cachyos.sh)"

# Find what the launcher points at, so we remove exactly what was installed rather than
# guessing at a path.
TARGET=""
if [ -f /usr/local/bin/nxwitness-client ]; then
    TARGET="$(grep -o '/opt/[^"]*/client/[^"]*' /usr/local/bin/nxwitness-client | head -1)"
fi
if [ -z "$TARGET" ]; then
    TARGET="$(find /opt -maxdepth 3 -type d -path '*/client/*' -name '6.*' 2>/dev/null | head -1)"
fi

if [ -n "$TARGET" ] && [ -d "$TARGET" ]; then
    log "Removing $TARGET"
    CUSTOMIZATION="$(basename "$(dirname "$(dirname "$TARGET")")")"
    CUSTOMIZATION="${CUSTOMIZATION##*-}"
    rm -rf "$TARGET"
    # Drop now-empty parents, but never touch a company dir that still holds another version.
    rmdir --ignore-fail-on-non-empty "$(dirname "$TARGET")" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$(dirname "$(dirname "$TARGET")")" 2>/dev/null || true
else
    note "No installed client tree found under /opt - skipping."
    CUSTOMIZATION=""
fi

log "Removing launcher and desktop entries"
rm -f /usr/local/bin/nxwitness-client
rm -f /usr/share/applications/nxwitness-client.desktop
for d in /usr/share/applications/*.desktop; do
    [ -f "$d" ] || continue
    if grep -q 'nxwitness-client' "$d" 2>/dev/null; then
        note "removing $d"
        rm -f "$d"
    fi
done

if [ -n "$CUSTOMIZATION" ]; then
    log "Removing icons (vmsclient-$CUSTOMIZATION.*)"
    find /usr/share/icons -name "vmsclient-$CUSTOMIZATION.*" -delete 2>/dev/null || true
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -qtf /usr/share/icons/hicolor 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
    log "Purging per-user ini files"
    while IFS=: read -r user _ uid _ _ home _; do
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        [ -f "$home/.config/nx_ini/desktop_client.ini" ] || continue
        note "removing $home/.config/nx_ini/desktop_client.ini"
        rm -f "$home/.config/nx_ini/desktop_client.ini"
        rmdir --ignore-fail-on-non-empty "$home/.config/nx_ini" 2>/dev/null || true
    done < /etc/passwd
else
    note "Per-user settings kept. Use --purge to remove ~/.config/nx_ini/desktop_client.ini too."
    note "Client state and logs live in ~/.local/share/Network Optix/ and ~/.config/Network Optix/."
fi

log "Done"
