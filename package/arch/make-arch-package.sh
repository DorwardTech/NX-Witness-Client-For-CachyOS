#!/usr/bin/env bash
#
# Build a pacman package from the .deb produced by build/build-nx-client.sh.
#
#     ./make-arch-package.sh [path/to/*.deb]
#
# Produces nx-witness-client-opensource-<version>-1-x86_64.pkg.tar.zst next to the PKGBUILD.
# Install it with:  sudo pacman -U <file>
#
# pkgver tracks the upstream VMS version: <release>.<buildNumber>, so 6.1.3.43301 corresponds
# to nx_open tag vms/6.1.3/release_43301_all. The PKGBUILD's pkgver is rewritten from the .deb
# filename, so packaging a different build needs no manual edit.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v makepkg >/dev/null 2>&1 || die "makepkg not found - install base-devel"

DEB="${1:-}"
if [ -z "$DEB" ]; then
    DEB="$(ls -1 "$HOME"/nx_open-build/distrib/*.deb 2>/dev/null | head -1 || true)"
fi
[ -n "$DEB" ] && [ -f "$DEB" ] || die "no .deb given and none found in \$HOME/nx_open-build/distrib/"

BASE="$(basename "$DEB")"
# metavms-client-open-source-6.1.3.43301-linux_x64-local.deb -> 6.1.3.43301
VERSION="$(printf '%s' "$BASE" | sed -n 's/.*open-source-\([0-9][0-9.]*\)-linux.*/\1/p')"
[ -n "$VERSION" ] || die "cannot read a version out of $BASE"

log "Packaging $BASE"
note "version: $VERSION"

# Keep the PKGBUILD's dependency list honest against the shell installer's.
log "Checking dependency lists agree"
deps_installer="$(sed -n '/^RUNTIME_DEPS=(/,/^)/p' "$REPO/package/install-cachyos.sh" \
    | grep -vE '^\s*#|^RUNTIME_DEPS=\(|^\)' | tr -s ' \n' '\n' | grep -v '^$' | sort -u)"
deps_pkgbuild="$(sed -n '/^depends=(/,/^)/p' "$HERE/PKGBUILD" \
    | grep -oE "'[a-z0-9._+-]+'" | tr -d "'" | sort -u)"
drift="$(comm -3 <(echo "$deps_installer") <(echo "$deps_pkgbuild") || true)"
if [ -n "$drift" ]; then
    note "WARNING: PKGBUILD depends() and install-cachyos.sh RUNTIME_DEPS differ:"
    comm -3 <(echo "$deps_installer") <(echo "$deps_pkgbuild") \
        | sed 's/^\t/      only in PKGBUILD: /; s/^\([^ \t]\)/      only in installer: \1/'
else
    note "dependency lists agree ($(echo "$deps_pkgbuild" | wc -l) packages)"
fi

log "Staging"
cp -f "$DEB" "$HERE/$BASE"
sed -i "s/^pkgver=.*/pkgver=$VERSION/" "$HERE/PKGBUILD"
sed -i "s|^source=(.*|source=(\"$BASE\")|" "$HERE/PKGBUILD"

log "Running makepkg"
cd "$HERE"
makepkg -f --noconfirm

PKGFILE="$(ls -1t "$HERE"/*.pkg.tar.* 2>/dev/null | head -1)"
[ -n "$PKGFILE" ] || die "makepkg produced no package"

log "Package ready"
note "file  : $PKGFILE"
note "size  : $(du -h "$PKGFILE" | cut -f1)"
note "sha256: $(sha256sum "$PKGFILE" | awk '{print $1}')"
echo
note "Install with:  sudo pacman -U \"$PKGFILE\""
