#!/usr/bin/env bash
#
# Collect diagnostics for a client that will not start.
#
#     ./diagnose.sh [/opt/<company>/client/<version>]
#
# Writes a report to ./nx-diagnose.txt and prints it. Paste the whole thing when asking for help.
#
set -uo pipefail

OUT="${PWD}/nx-diagnose.txt"
exec > >(tee "$OUT") 2>&1

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    if [ -f /usr/local/bin/nxwitness-client ]; then
        TARGET="$(grep -o '/opt/[^"]*/client/[^"/]*' /usr/local/bin/nxwitness-client | head -1)"
    fi
fi
[ -n "$TARGET" ] && [ -d "$TARGET" ] || TARGET="$(find /opt -maxdepth 3 -type d -path '*/client/*' 2>/dev/null | head -1)"

hdr() { printf '\n===== %s =====\n' "$*"; }

hdr "install"
echo "target: ${TARGET:-NOT FOUND}"
[ -n "$TARGET" ] || { echo "No installed client found under /opt."; exit 1; }
ls -la "$TARGET/bin/" 2>/dev/null | head -20
CLIENT_BIN="$(find "$TARGET/bin" -maxdepth 1 -type f -name '*_client' -printf '%f\n' 2>/dev/null | head -1)"
echo "client binary: ${CLIENT_BIN:-NONE}"

hdr "session"
echo "XDG_SESSION_TYPE : ${XDG_SESSION_TYPE:-unset}"
echo "WAYLAND_DISPLAY  : ${WAYLAND_DISPLAY:-unset}"
echo "DISPLAY          : ${DISPLAY:-unset}"
echo "XDG_CURRENT_DESKTOP: ${XDG_CURRENT_DESKTOP:-unset}"
echo "QT_QPA_PLATFORM  : ${QT_QPA_PLATFORM:-unset}"
echo -n "XWayland present : "
command -v Xwayland >/dev/null 2>&1 && echo yes || echo "no (pacman -S xorg-xwayland)"
echo -n "glxinfo renderer : "
command -v glxinfo >/dev/null 2>&1 && glxinfo -B 2>/dev/null | grep -i 'OpenGL renderer' || echo "(glxinfo not installed)"

hdr "unresolved libraries across the INSTALLED tree"
export LD_LIBRARY_PATH="$TARGET/lib:$TARGET/lib/opengl:$TARGET/lib/stdcpp"
extract='s|.*[[:space:]]\([^[:space:]/]*\.so[^[:space:]]*\)[[:space:]]*=>[[:space:]]*not found.*|\1|p'
{
    echo "$TARGET/bin/$CLIENT_BIN"
    find "$TARGET/lib" -name '*.so*' -type f 2>/dev/null
    find "$TARGET/plugins" -name '*.so' -type f 2>/dev/null
} | while read -r o; do
    [ -f "$o" ] || continue
    head -c 4 "$o" 2>/dev/null | grep -q ELF || continue
    ldd "$o" 2>/dev/null | sed -n "$extract"
done | sort -u | sed 's/^/  MISSING: /'
echo "(nothing above = every library resolves)"

hdr "which objects need each missing library"
{
    echo "$TARGET/bin/$CLIENT_BIN"
    find "$TARGET/lib" -name '*.so*' -type f 2>/dev/null
    find "$TARGET/plugins" -name '*.so' -type f 2>/dev/null
} | while read -r o; do
    [ -f "$o" ] || continue
    head -c 4 "$o" 2>/dev/null | grep -q ELF || continue
    miss="$(ldd "$o" 2>/dev/null | sed -n "$extract" | tr '\n' ' ')"
    [ -n "$miss" ] && echo "  ${o#$TARGET/} <- $miss"
done
unset LD_LIBRARY_PATH

hdr "ini"
for f in "$HOME/.config/nx_ini/desktop_client.ini"; do
    echo "--- $f"; cat "$f" 2>/dev/null || echo "(absent)"
done

hdr "launch attempt (30s timeout, Qt plugin debug)"
export QT_DEBUG_PLUGINS=1
timeout 30 "$TARGET/bin/client" 2>&1 | head -120
echo "--- exit: $? (124 = still running after 30s, which is GOOD) ---"

hdr "done"
echo "Report written to $OUT"
