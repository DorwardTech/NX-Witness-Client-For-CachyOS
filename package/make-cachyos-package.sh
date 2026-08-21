#!/usr/bin/env bash
#
# Turn the .deb produced by build-nx-client.sh into a self-contained CachyOS package.
#
#     ./make-cachyos-package.sh [path/to/*.deb] [outdir]
#
# The .deb is used purely as a convenient bundle: it already contains the client plus every
# bundled Qt / ffmpeg / WebEngine library with correct RPATHs under
# /opt/<companyId>/client/<version>/. CachyOS never sees dpkg - we extract the payload and
# ship it with a plain shell installer.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:-}"
OUTDIR="${2:-$HOME}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

if [ -z "$DEB" ]; then
    DEB="$(ls -1 "$HOME"/nx_open-build/distrib/*.deb 2>/dev/null | head -1 || true)"
fi
[ -n "$DEB" ] && [ -f "$DEB" ] || die "no .deb given and none found in \$HOME/nx_open-build/distrib/"
log "Source package: $DEB"

STAGE="$OUTDIR/nx-client-cachyos"
PKGROOT="$OUTDIR/.nx-pkgroot"

rm -rf "$PKGROOT" "$STAGE"
mkdir -p "$PKGROOT" "$STAGE"

# ------------------------------------------------------------------------------------------------
# Extract the .deb payload
# ------------------------------------------------------------------------------------------------
log "Extracting payload"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$DEB" "$PKGROOT"
else
    # Arch has no dpkg-deb by default; ar + tar handles it. Compression varies by build.
    note "dpkg-deb not present, falling back to ar + tar"
    tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$DEB" )
    data="$(ls "$tmp"/data.tar.* | head -1)"
    case "$data" in
        *.zst) tar --zstd -xf "$data" -C "$PKGROOT" ;;
        *.xz)  tar -Jxf     "$data" -C "$PKGROOT" ;;
        *.gz)  tar -zxf     "$data" -C "$PKGROOT" ;;
        *.bz2) tar -jxf     "$data" -C "$PKGROOT" ;;
        *)     die "unknown data archive compression: $data" ;;
    esac
    rm -rf "$tmp"
fi

# ------------------------------------------------------------------------------------------------
# Identify the payload
# ------------------------------------------------------------------------------------------------
CLIENT_WRAPPER="$(find "$PKGROOT/opt" -type f -path '*/client/*/bin/client' | head -1)"
[ -n "$CLIENT_WRAPPER" ] || die "unexpected .deb layout: no opt/*/client/*/bin/client"
BIN_DIR="$(dirname "$CLIENT_WRAPPER")"
MODULE_DIR="$(dirname "$BIN_DIR")"
VERSION="$(basename "$MODULE_DIR")"
COMPANY_ID="$(basename "$(dirname "$(dirname "$MODULE_DIR")")")"
CLIENT_BIN="$(find "$BIN_DIR" -maxdepth 1 -type f -name '*_client' -printf '%f\n' | head -1)"
CUSTOMIZATION="${COMPANY_ID##*-}"

note "company id    : $COMPANY_ID"
note "customization : $CUSTOMIZATION"
note "version       : $VERSION"
note "client binary : $CLIENT_BIN"

# ------------------------------------------------------------------------------------------------
# Assemble the staging directory
# ------------------------------------------------------------------------------------------------
log "Assembling $STAGE"
cp -a "$PKGROOT/opt" "$STAGE/"
mkdir -p "$STAGE/usr/share"
[ -d "$PKGROOT/usr/share/icons" ]        && cp -a "$PKGROOT/usr/share/icons"        "$STAGE/usr/share/"
[ -d "$PKGROOT/usr/share/applications" ] && cp -a "$PKGROOT/usr/share/applications" "$STAGE/usr/share/"

install -m 755 "$HERE/install-cachyos.sh"   "$STAGE/"
install -m 755 "$HERE/uninstall-cachyos.sh" "$STAGE/"
[ -f "$HERE/verify-package.sh" ] && install -m 755 "$HERE/verify-package.sh" "$STAGE/"

# ------------------------------------------------------------------------------------------------
# README shipped inside the package
# ------------------------------------------------------------------------------------------------
log "Writing README.txt"
cat > "$STAGE/README.txt" <<README
================================================================================
 Nx Witness / Nx Meta VMS Desktop Client $VERSION - open-source build for CachyOS
================================================================================

WHAT THIS IS
------------
The Network Optix VMS Desktop Client, built from the public open-source sources
at https://github.com/networkoptix/nx_open, pinned to the Nx Witness 6.1.3
release:

    tag    : vms/6.1.3/release_43301_all
    commit : a49c2c1c254f2758cd16231c1183c2fc93e6d2ba
    version: $VERSION
    arch   : x86_64

Network Optix publishes official clients only as Ubuntu .deb packages. This
package repackages a from-source build so it installs cleanly on CachyOS and
other Arch-based distributions. Every Qt / ffmpeg / WebEngine library the client
needs is bundled inside the tree with correct RPATHs; only a small set of system
libraries is pulled in from pacman.

Matches Nx Witness Server 6.1.x. The client and server negotiate a binary
protocol version, which for this build is 6113 - identical across the 6.1.0,
6.1.1, 6.1.2 and 6.1.3 releases, so any 6.1.x server is compatible.


INSTALL
-------
    tar --zstd -xf nx-witness-client-$VERSION-cachyos-x86_64.tar.zst
    cd nx-client-cachyos
    sudo ./install-cachyos.sh

This installs:
    /opt/$COMPANY_ID/client/$VERSION/   the client and its bundled libraries
    /usr/local/bin/nxwitness-client                    command-line launcher
    /usr/share/applications/nxwitness-client.desktop   application menu entry
    ~/.config/nx_ini/desktop_client.ini                required setting, see below

Runtime libraries are installed with "pacman -S --needed". Pass --no-deps to
skip that step if you manage them yourself.


CONNECTING TO YOUR SERVER
-------------------------
1. Launch "Nx Witness Client (Open Source)" from the application menu, or run
   "nxwitness-client" in a terminal.
2. Choose "Connect to Server".
3. Host: your server's address, e.g.   https://192.168.1.50:7001
   (7001 is the Nx Witness default port.)
4. Enter your Nx Witness server login and password.


THE demoMode SETTING - REQUIRED, DO NOT REMOVE
----------------------------------------------
    ~/.config/nx_ini/desktop_client.ini
    demoMode=1

An Nx Witness server reports its customization as "default". This open-source
build is branded "$CUSTOMIZATION" (Nx Meta - see below). Without demoMode the client
refuses the connection with a customization mismatch error.

In the sources, demoMode sets two developer flags on the compatibility validator
(vms/client/nx_vms_client_desktop/.../application_context.cpp):
    ignoreCustomization   - lets the client accept a differently branded server
    ignoreCloudHost       - enables automatic cloud host deduction

The setting is PER USER. nx_kit looks for the ini in \$NX_INI_DIR, then
\$HOME/.config/nx_ini/, then /etc/nx_ini/ - and since \$HOME is always set in a
desktop session, a system-wide /etc/nx_ini file is never read and is NOT a
working substitute. The nxwitness-client launcher creates the per-user file
automatically on first run, so additional desktop users need no manual step.


BRANDING: THIS SHOWS AS "Nx Meta"
---------------------------------
The client's branding comes from a Customization Package. The default one, and
the only one obtainable without a Network Optix developer account, is Nx Meta -
Network Optix's own developer-edition branding of the same product. So window
titles, the logo and the About box read "Nx Meta" rather than "Nx Witness".
This is cosmetic: it is the same client talking to the same server.


TWO HARMLESS PROMPTS YOU WILL SEE, AND WHY
------------------------------------------
1. A "Beta version" dialog on every launch.
   This build's publication type is "local", which is not in the set
   {patch, release} that suppresses the dialog. Just dismiss it.

2. A "<version> is available" update notification.
   The client polls for releases on a 60-minute timer. Ignore it.

Automatic updates CANNOT replace this build, for two independent reasons: the
"local" publication type is rejected outright when selecting a client release,
and this build identifies as the "open-source" custom-client variant, which
Nx's public release packages do not carry. So the notification is cosmetic -
but decline any update anyway, since a stock Nx build would not run on Arch.
To move to a different VMS version, rebuild from the matching release tag.


IF THE SERVER STILL REFUSES THE CONNECTION
------------------------------------------
demoMode=1 suppresses the client-side customization check, which is the check
that actually rejects an Nx Witness server in practice. It does not, however,
blank the branding the client ADVERTISES to the server - only developerMode
does that. Whether a server independently rejects a differently branded peer
could not be verified, because the Nx mediaserver is not open-source.

If, and only if, the connection is still refused with demoMode=1 in place, add
a second line to ~/.config/nx_ini/desktop_client.ini:

    demoMode=1
    developerMode=1

developerMode blanks the advertised brand and customization, and additionally
relaxes the protocol-version check. The cost is that developer UI affordances
become visible in the client. Try demoMode alone first.

As a last resort for a protocol-version mismatch specifically (it should not
occur against any 6.1.x server - they all report protocol 6113), the client
also accepts:

    nxwitness-client --override-protocol-version <N>


UNINSTALL
---------
    sudo ./uninstall-cachyos.sh            # keep per-user settings
    sudo ./uninstall-cachyos.sh --purge    # also remove the per-user ini files

Runtime libraries installed via pacman are left in place.


TROUBLESHOOTING
---------------
"Failed to connect" / customization mismatch
    demoMode=1 is missing for the user running the client. Check
    ~/.config/nx_ini/desktop_client.ini

"could not load the Qt platform plugin xcb"
    A system X/XCB library is missing. Re-run: sudo ./install-cachyos.sh --no-ini
    Run with QT_DEBUG_PLUGINS=1 to see which library failed to load.

Blank or boxes instead of text
    No fonts installed:  sudo pacman -S ttf-dejavu

Client starts but video is black
    Missing or mismatched GPU drivers. Confirm mesa / your vendor driver is
    installed, and try software rendering to isolate it:
        LIBGL_ALWAYS_SOFTWARE=1 nxwitness-client

Server is actually 6.0.x, not 6.1.x
    Protocol versions differ across minor releases. Rebuild from the matching
    tag - list them with:
        git ls-remote --tags https://github.com/networkoptix/nx_open | grep 'vms/6\.'

Still refused after all of the above
    Run the client from a terminal and read the log it prints; the compatibility
    error names which of the four checks failed (customization, cloud host,
    protocol version, or version too low).
README

# ------------------------------------------------------------------------------------------------
# Tarball
# ------------------------------------------------------------------------------------------------
log "Creating tarball"
# zstd is the default (CachyOS has it - pacman itself uses it), but fall back rather than
# emit a truncated archive on a host without it.
if command -v zstd >/dev/null 2>&1; then
    TARBALL="$OUTDIR/nx-witness-client-$VERSION-cachyos-x86_64.tar.zst"
    COMPRESS=(--zstd)
else
    note "zstd not found - falling back to gzip"
    TARBALL="$OUTDIR/nx-witness-client-$VERSION-cachyos-x86_64.tar.gz"
    COMPRESS=(-z)
fi
rm -f "$TARBALL"
if ! tar "${COMPRESS[@]}" -cf "$TARBALL" -C "$OUTDIR" nx-client-cachyos; then
    rm -f "$TARBALL"
    die "tar failed; no archive written"
fi
rm -rf "$PKGROOT"

SHA="$(sha256sum "$TARBALL" | awk '{print $1}')"
echo "$SHA  $(basename "$TARBALL")" > "$TARBALL.sha256"

log "Package ready"
note "tarball : $TARBALL"
note "size    : $(du -h "$TARBALL" | cut -f1)"
note "sha256  : $SHA"
note "staging : $STAGE"
