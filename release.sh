#!/usr/bin/env bash
#
# Cut a release: tag it, build the artifacts, and publish them.
#
#     ./release.sh [path/to/*.deb]
#
# The version is read from the built .deb and tracks the upstream VMS release exactly:
# <release>.<buildNumber>, so 6.1.3.43301 is nx_open tag vms/6.1.3/release_43301_all.
# The git tag is that version prefixed with "v".
#
# Produces and attaches:
#   nx-witness-client-opensource-<version>-1-x86_64.pkg.tar.zst   pacman package
#   nx-witness-client-<version>-cachyos-x86_64.tar.zst            portable tarball
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

DEB="${1:-}"
[ -n "$DEB" ] || DEB="$(ls -1 "$HOME"/nx_open-build/distrib/*.deb 2>/dev/null | head -1 || true)"
[ -n "$DEB" ] && [ -f "$DEB" ] || die "no .deb given and none found in \$HOME/nx_open-build/distrib/"

VERSION="$(basename "$DEB" | sed -n 's/.*open-source-\([0-9][0-9.]*\)-linux.*/\1/p')"
[ -n "$VERSION" ] || die "cannot read a version out of $(basename "$DEB")"
TAG="v$VERSION"

log "Releasing $TAG"
note "source .deb: $DEB"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty - commit or stash first"

log "Building the pacman package"
./package/arch/make-arch-package.sh "$DEB"
PKG="$(ls -1t package/arch/*.pkg.tar.* 2>/dev/null | head -1)"
[ -n "$PKG" ] || die "no pacman package produced"

log "Building the portable tarball"
./package/make-cachyos-package.sh "$DEB" "$HOME"
TARBALL="$HOME/nx-witness-client-$VERSION-cachyos-x86_64.tar.zst"
[ -f "$TARBALL" ] || TARBALL="$(ls -1t "$HOME"/nx-witness-client-"$VERSION"-cachyos-x86_64.tar.* | head -1)"

log "Tagging"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    note "tag $TAG already exists locally"
else
    git tag -a "$TAG" -m "Nx Witness / Nx Meta VMS Desktop Client $VERSION for CachyOS

Version tracks the upstream VMS release exactly: <release>.<buildNumber>,
corresponding to nx_open tag vms/${VERSION%.*}/release_${VERSION##*.}_all."
fi
git push origin "$TAG"

log "Publishing the release"
if command -v gh >/dev/null 2>&1; then
    gh release create "$TAG" "$PKG" "$TARBALL" \
        --title "Nx Witness Client $VERSION for CachyOS" \
        --notes "Open-source build of the Network Optix VMS Desktop Client, tracking upstream
VMS release \`$VERSION\` (nx_open tag \`vms/${VERSION%.*}/release_${VERSION##*.}_all\`).

**Install (pacman, recommended)**
\`\`\`
sudo pacman -U $(basename "$PKG")
\`\`\`

**Install (portable tarball)**
\`\`\`
tar --zstd -xf $(basename "$TARBALL")
cd nx-client-cachyos && sudo ./install-cachyos.sh
\`\`\`

Requires \`libxml2-legacy\` from \`extra\` — the client links \`libxml2.so.2\`, which current
\`libxml2\` no longer provides. The pacman package depends on it automatically.

Launch with \`nxwitness-client\`, connect to \`https://<server-ip>:7001\`. The UI is branded
Nx Meta; see the README for why, and for the \`demoMode\` setting the launcher creates for you."
else
    note "gh CLI not installed - the tag is pushed, create the release from it at:"
    note "  https://github.com/DorwardTech/NX-Witness-Client-For-CachyOS/releases/new?tag=$TAG"
    note "and attach:"
    note "  $PKG"
    note "  $TARBALL"
fi

log "Done"
note "tag     : $TAG"
note "package : $PKG"
note "tarball : $TARBALL"
