#!/usr/bin/env bash
#
# Verify a staged CachyOS package before shipping or installing it.
#
#     ./verify-package.sh [staging-dir]        (default: the directory holding this script)
#
# Checks:
#   1. the expected layout exists and the scripts are executable
#   2. install-cachyos.sh refers only to files that are actually in the tree
#   3. every shared-library dependency of the client binary either resolves inside the
#      bundled lib dir (via RPATH) or is on the documented pacman runtime list
#
# Unresolved libraries are reported with the pacman package that provides them, so a
# genuine gap is distinguishable from "this host simply is not the target".
#
set -uo pipefail

STAGE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FAIL=0
WARN=0

ok()   { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Debian/Ubuntu soname -> Arch package, mirroring install-cachyos.sh's RUNTIME_DEPS.
soname_to_arch() {
    case "$1" in
        libEGL.so*|libGL.so*|libGLX.so*|libOpenGL.so*|libGLdispatch.so*) echo libglvnd ;;
        libGLU.so*)             echo glu ;;
        libfontconfig.so*)      echo fontconfig ;;
        libfreetype.so*)        echo freetype2 ;;
        libasound.so*)          echo alsa-lib ;;
        libpulse*.so*)          echo libpulse ;;
        libsecret-1.so*)        echo libsecret ;;
        libX11.so*|libX11-xcb.so*) echo libx11 ;;
        libxcb-cursor.so*)      echo xcb-util-cursor ;;
        libxcb-image.so*)       echo xcb-util-image ;;
        libxcb-keysyms.so*)     echo xcb-util-keysyms ;;
        libxcb-render-util.so*) echo xcb-util-renderutil ;;
        libxcb-icccm.so*|libxcb-ewmh.so*) echo xcb-util-wm ;;
        libxcb-util.so*)        echo xcb-util ;;
        libxcb*.so*)            echo libxcb ;;
        libXext.so*)            echo libxext ;;
        libXfixes.so*)          echo libxfixes ;;
        libxkbcommon-x11.so*)   echo libxkbcommon-x11 ;;
        libxkbcommon.so*)       echo libxkbcommon ;;
        libXss.so*)             echo libxss ;;
        libXcomposite.so*)      echo libxcomposite ;;
        libXi.so*)              echo libxi ;;
        libxkbfile.so*)         echo libxkbfile ;;
        libXrandr.so*)          echo libxrandr ;;
        libXrender.so*)         echo libxrender ;;
        libXtst.so*)            echo libxtst ;;
        libz.so*)               echo zlib ;;
        libglib-2.0.so*|libgobject-2.0.so*|libgio-2.0.so*|libgmodule-2.0.so*) echo glib2 ;;
        libdbus-1.so*)          echo dbus ;;
        libexpat.so*)           echo expat ;;
        libxml2.so*)            echo libxml2 ;;
        libxslt.so*)            echo libxslt ;;
        libnspr4.so*|libplc4.so*|libplds4.so*) echo nspr ;;
        libnss3.so*|libnssutil3.so*|libsmime3.so*|libssl3.so*) echo nss ;;
        libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|ld-linux*) echo glibc ;;
        libstdc++.so*|libgcc_s.so*) echo "gcc-libs (or the bundled lib/stdcpp)" ;;
        *) echo "" ;;
    esac
}

# ------------------------------------------------------------------------------------------------
log "Layout"
# ------------------------------------------------------------------------------------------------
CLIENT_WRAPPER="$(find "$STAGE/opt" -type f -path '*/client/*/bin/client' 2>/dev/null | head -1)"
if [ -z "$CLIENT_WRAPPER" ]; then
    bad "no opt/<company>/client/<version>/bin/client in $STAGE"
    echo; echo "verify: $FAIL failure(s)"; exit 1
fi
BIN_DIR="$(dirname "$CLIENT_WRAPPER")"
MODULE_DIR="$(dirname "$BIN_DIR")"
LIB_DIR="$MODULE_DIR/lib"
VERSION="$(basename "$MODULE_DIR")"
COMPANY_ID="$(basename "$(dirname "$(dirname "$MODULE_DIR")")")"
CLIENT_BIN_NAME="$(find "$BIN_DIR" -maxdepth 1 -type f -name '*_client' -printf '%f\n' | head -1)"
CLIENT_BIN="$BIN_DIR/$CLIENT_BIN_NAME"

ok "company id    : $COMPANY_ID"
ok "version       : $VERSION"
[ -n "$CLIENT_BIN_NAME" ] && ok "client binary : $CLIENT_BIN_NAME" || bad "no *_client binary in $BIN_DIR"
[ -x "$CLIENT_BIN" ] && ok "client binary is executable" || bad "client binary not executable"
[ -d "$LIB_DIR" ] && ok "bundled lib dir: $(find "$LIB_DIR" -name '*.so*' | wc -l) shared objects" \
                  || bad "no lib/ directory at $LIB_DIR"

for f in install-cachyos.sh uninstall-cachyos.sh README.txt; do
    [ -f "$STAGE/$f" ] && ok "present: $f" || bad "missing: $f"
done
for f in install-cachyos.sh uninstall-cachyos.sh; do
    [ -x "$STAGE/$f" ] && ok "executable: $f" || bad "not executable: $f"
    bash -n "$STAGE/$f" 2>/dev/null && ok "syntax ok: $f" || bad "syntax error: $f"
done
[ -d "$STAGE/usr/share/icons" ] && ok "icons: $(find "$STAGE/usr/share/icons" -name '*.png' | wc -l) png" \
                                || warn "no usr/share/icons in the package - the menu entry will have no icon"

# ------------------------------------------------------------------------------------------------
log "Installer references real paths"
# ------------------------------------------------------------------------------------------------
# The installer discovers paths at run time; the fixed things it copies must exist.
for rel in "opt/$COMPANY_ID/client/$VERSION" "opt/$COMPANY_ID/client/$VERSION/bin/client"; do
    [ -e "$STAGE/$rel" ] && ok "installer source exists: $rel" || bad "installer would copy missing $rel"
done
if grep -q 'lib/stdcpp/choose_newer_stdcpp.sh' "$STAGE/install-cachyos.sh"; then
    [ -f "$LIB_DIR/stdcpp/choose_newer_stdcpp.sh" ] \
        && ok "lib/stdcpp/choose_newer_stdcpp.sh present" \
        || warn "installer chmods lib/stdcpp/choose_newer_stdcpp.sh but it is not in the tree"
fi

# ------------------------------------------------------------------------------------------------
log "RPATH of the client binary"
# ------------------------------------------------------------------------------------------------
if command -v readelf >/dev/null 2>&1; then
    RPATH="$(readelf -d "$CLIENT_BIN" 2>/dev/null | grep -E 'RPATH|RUNPATH' | sed 's/.*\[\(.*\)\]/\1/')"
    [ -n "$RPATH" ] && ok "RPATH/RUNPATH = $RPATH" \
                    || warn "client binary has no RPATH/RUNPATH - it will rely on the wrapper's LD_LIBRARY_PATH"
else
    warn "readelf not available - skipping RPATH check"
fi

# ------------------------------------------------------------------------------------------------
log "Shared library resolution"
# ------------------------------------------------------------------------------------------------
if ! command -v ldd >/dev/null 2>&1; then
    warn "ldd not available - skipping"
else
    MISSING="$(LD_LIBRARY_PATH="$LIB_DIR" ldd "$CLIENT_BIN" 2>/dev/null | awk '/not found/ {print $1}' | sort -u)"
    if [ -z "$MISSING" ]; then
        ok "every dependency of $CLIENT_BIN_NAME resolves"
    else
        echo "  Unresolved against the bundled lib dir:"
        while read -r so; do
            [ -n "$so" ] || continue
            if [ -n "$(find "$LIB_DIR" -name "$so" -print -quit 2>/dev/null)" ]; then
                ok "$so -> bundled in lib/"
            else
                pkg="$(soname_to_arch "$so")"
                if [ -n "$pkg" ]; then
                    warn "$so -> expected from pacman package: $pkg"
                else
                    bad "$so -> UNEXPLAINED: not bundled and not on the runtime dependency list"
                fi
            fi
        done <<< "$MISSING"
    fi
fi

# ------------------------------------------------------------------------------------------------
log "Summary"
# ------------------------------------------------------------------------------------------------
echo "  failures : $FAIL"
echo "  warnings : $WARN"
echo
if [ "$FAIL" -gt 0 ]; then
    echo "verify: FAILED"
    exit 1
fi
echo "verify: passed${WARN:+ (with $WARN warning(s))}"
