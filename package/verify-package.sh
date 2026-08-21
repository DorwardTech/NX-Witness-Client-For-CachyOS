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
        libxml2.so.2*)          echo libxml2-legacy ;;   #< soname bump: see install-cachyos.sh
        libxml2.so*)            echo libxml2 ;;
        libxslt.so*)            echo libxslt ;;
        libnspr4.so*|libplc4.so*|libplds4.so*) echo nspr ;;
        libnss3.so*|libnssutil3.so*|libsmime3.so*|libssl3.so*) echo nss ;;
        libgudev-1.0.so*)       echo libgudev ;;
        libigdgmm.so*)          echo intel-gmmlib ;;
        libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|ld-linux*) echo glibc ;;
        libstdc++.so*|libgcc_s.so*) echo "gcc-libs (or the bundled lib/stdcpp)" ;;
        *) echo "" ;;
    esac
}

# Sonames that are legitimately unresolved: they belong to bundled Qt platform plugins the
# client does not use. Nx ships plugins/platforms/libqwayland-*.so and libqeglfs.so but not the
# Qt Wayland / EGLFS libraries they link against. This is why install-cachyos.sh pins
# QT_QPA_PLATFORM=xcb - on a Wayland session Qt would otherwise pick a plugin it cannot load.
benign_unresolved() {
    case "$1" in
        libQt6WaylandClient.so*|libQt6WaylandEglClientHwIntegration.so*)
            echo "Qt Wayland plugin dep; unused - launcher pins QT_QPA_PLATFORM=xcb" ;;
        libQt6EglFSDeviceIntegration.so*)
            echo "Qt EGLFS (embedded) plugin dep; unused on a desktop" ;;
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
#
# Scans the client binary, every bundled .so, and the Qt plugins - the platform plugin
# (plugins/platforms/libqxcb.so) is what actually pulls the xcb libraries, so checking only the
# client binary would miss most of the real requirement.
#
# Much more is bundled than deb_dependencies.yaml implies: build_distribution.sh copies ffmpeg,
# OpenSSL 1.1, ICU, OpenAL, gstreamer, libxkbcommon(-x11), libXss, libxcb-cursor/xinerama/shape,
# libpng16, libOpenGL and the VA/QSV/CUDA stack into lib/. So the genuine system requirement is
# small, and this pass derives it empirically rather than trusting the mapping table.
# ------------------------------------------------------------------------------------------------
if ! command -v ldd >/dev/null 2>&1; then
    warn "ldd not available - skipping"
else
    SCAN_LIST="$(mktemp)"
    {
        [ -f "$CLIENT_BIN" ] && echo "$CLIENT_BIN"
        find "$LIB_DIR" -name '*.so*' -type f 2>/dev/null
        find "$MODULE_DIR/plugins" -name '*.so' -type f 2>/dev/null
        find "$MODULE_DIR/libexec" -type f 2>/dev/null
    } | sort -u > "$SCAN_LIST"
    ok "scanning $(wc -l < "$SCAN_LIST") ELF objects"

    export LD_LIBRARY_PATH="$LIB_DIR:$LIB_DIR/opengl:$LIB_DIR/stdcpp"
    MISSING_ALL="$(mktemp)"
    # Extract the soname sitting immediately before "=> not found", wherever it appears on the
    # line. Taking $1 is wrong: glibc's ldd prefixes output with "<path>:" in some versions
    # (newer glibc, as on Arch/CachyOS), which yields the FILE NAME instead of the soname and
    # makes every object with a missing dependency look like an unexplained library.
    # Requiring the token to contain ".so" and no "/" keeps paths and headers out.
    extract_missing='s|.*[[:space:]]\([^[:space:]/]*\.so[^[:space:]]*\)[[:space:]]*=>[[:space:]]*not found.*|\1|p'
    while read -r obj; do
        [ -f "$obj" ] || continue
        # Only real ELF objects; skip scripts and data files.
        head -c 4 "$obj" 2>/dev/null | grep -q 'ELF' || continue
        ldd "$obj" 2>/dev/null | sed -n "$extract_missing"
    done < "$SCAN_LIST" | sort -u > "$MISSING_ALL"

    if [ ! -s "$MISSING_ALL" ]; then
        ok "every dependency of every scanned object resolves against the bundled tree"
    else
        echo "  Sonames not satisfied by the bundled tree (expected: system libraries):"
        NEEDED_PKGS="$(mktemp)"
        while read -r so; do
            [ -n "$so" ] || continue
            pkg="$(soname_to_arch "$so")"
            benign="$(benign_unresolved "$so")"
            if [ -n "$benign" ]; then
                warn "$so -> $benign"
            elif [ -n "$pkg" ]; then
                # Unresolved is unresolved. Naming a package that would supply it is a hint, not
                # a pass: the client aborts at startup on a missing soname regardless of whether
                # some package on the list is installed. libxml2 is exactly this trap - the
                # package is present but provides libxml2.so.16, not the libxml2.so.2 needed.
                bad "$so -> MISSING at runtime; install: $pkg"
                echo "$pkg" >> "$NEEDED_PKGS"
            else
                bad "$so -> UNEXPLAINED: not bundled and not on the runtime dependency list"
            fi
        done < "$MISSING_ALL"
        echo
        echo "  Distinct pacman packages implied by the scan:"
        sort -u "$NEEDED_PKGS" 2>/dev/null | sed 's/^/    /'
        echo
        echo "  These are real startup failures - the client will not launch until they resolve."
        echo
        echo "  Cross-check against install-cachyos.sh RUNTIME_DEPS:"
        for pkg in $(sort -u "$NEEDED_PKGS" 2>/dev/null); do
            case "$pkg" in
                glibc|"gcc-libs"*) continue ;;   # always present on any Linux system
            esac
            if grep -qE "(^|[[:space:]])$pkg([[:space:]]|$)" "$STAGE/install-cachyos.sh"; then
                ok "$pkg is on the installer's dependency list"
            else
                bad "$pkg is REQUIRED by the binaries but MISSING from install-cachyos.sh"
            fi
        done
        rm -f "$NEEDED_PKGS"
    fi
    rm -f "$SCAN_LIST" "$MISSING_ALL"
    unset LD_LIBRARY_PATH
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
