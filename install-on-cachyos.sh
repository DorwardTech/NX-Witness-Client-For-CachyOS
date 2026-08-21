#!/usr/bin/env bash
#
# One-shot: build the Nx VMS Desktop Client from source and install it on CachyOS.
#
#     ./install-on-cachyos.sh
#
# Runs, in order:
#   1. build/build-nx-client.sh          fetch pinned sources, toolchain, build (~1-6 h)
#   2. package/make-cachyos-package.sh   assemble the CachyOS package
#   3. package/verify-package.sh         check the result before touching the system
#   4. install-cachyos.sh                install it (asks for sudo)
#
# Each step can also be run on its own; see README.md.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${1:-$HOME}"

log()  { printf '\n\033[1;35m######## %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

log "STEP 1/4  Building from source"
"$HERE/build/build-nx-client.sh" "$WORKDIR"

log "STEP 2/4  Packaging for CachyOS"
"$HERE/package/make-cachyos-package.sh" "" "$WORKDIR"

STAGE="$WORKDIR/nx-client-cachyos"
[ -d "$STAGE" ] || die "packaging did not produce $STAGE"

log "STEP 3/4  Verifying the package"
if ! "$HERE/package/verify-package.sh" "$STAGE"; then
    die "verification failed - not installing. Investigate before continuing."
fi

log "STEP 4/4  Installing (sudo)"
sudo "$STAGE/install-cachyos.sh"

log "Done"
cat <<SUMMARY

    Launch:  nxwitness-client        (or "Nx Witness Client (Open Source)" in the menu)
    Connect: https://<your-server-ip>:7001

    The package tarball was also written to $WORKDIR, if you want to copy this
    build to another CachyOS machine instead of rebuilding there.

SUMMARY
