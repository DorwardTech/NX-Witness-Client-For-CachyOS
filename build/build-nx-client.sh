#!/usr/bin/env bash
#
# Reproducible build of the Nx Meta / Nx Witness open-source VMS Desktop Client
# pinned to the Nx Witness 6.1.3 release.
#
#   upstream : https://github.com/networkoptix/nx_open
#   tag      : vms/6.1.3/release_43301_all
#   commit   : a49c2c1c254f2758cd16231c1183c2fc93e6d2ba
#   build    : 43301   (must match the tag, it is baked into the version string)
#
# The C++ toolchain (sdk-gcc 9.5) and Qt 6.9.1 are downloaded as Conan artifacts from
# Network Optix's Artifactory during the CMake generation stage. The host distribution's
# compiler is NOT used, which is what makes an Arch/CachyOS build possible at all.
#
# Usage:  ./build-nx-client.sh [workdir]
#         workdir defaults to $HOME
#
set -euo pipefail

NX_TAG="vms/6.1.3/release_43301_all"
NX_COMMIT="a49c2c1c254f2758cd16231c1183c2fc93e6d2ba"
NX_BRANCH="vms_6.1.3"
NX_BUILD_NUMBER="43301"
NX_REPO="https://github.com/networkoptix/nx_open"

WORKDIR="${1:-$HOME}"
SRC="$WORKDIR/nx_open"
BUILD="$WORKDIR/nx_open-build"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------------------------
# 0. Preflight
# ------------------------------------------------------------------------------------------------
log "Preflight"

avail_gb=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc '0-9')
echo "Free space in $WORKDIR: ${avail_gb}G"
[ "$avail_gb" -ge 25 ] || die "Need at least ~25G free in $WORKDIR (Conan cache lives inside $BUILD/.conan)."

for url in "$NX_REPO" "https://pypi.org" "https://artifactory.nxvms.dev/artifactory/api/conan/conan/v1/ping"; do
    echo -n "  reachable: $url ... "
    if [[ "$url" == *github.com* ]]; then
        git ls-remote "$url" HEAD >/dev/null 2>&1 && echo yes || die "cannot reach $url"
    else
        curl -sSf -o /dev/null --max-time 30 "$url" && echo yes || die "cannot reach $url"
    fi
done

# ------------------------------------------------------------------------------------------------
# 1. Host packages
#
#    Build-time host tools only. The client's *runtime* libraries are handled by
#    package/install-cachyos.sh on the target machine.
#
#    NOTE: never pass -DinstallSystemRequirements=ON on Arch - it is implemented with
#    Conan's Apt tool and is Debian-only.
# ------------------------------------------------------------------------------------------------
log "Installing host build dependencies"

if command -v pacman >/dev/null 2>&1; then
    HOST_MODE=arch
    # NOTE: dpkg is deliberately NOT in this list - it is not in Arch's official repositories.
    # It is handled separately below, because the upstream distribution step needs dpkg-deb.
    sudo pacman -S --needed --noconfirm \
        git curl zip unzip zstd chrpath pkgconf fakeroot python patchelf binutils

    # vms/distribution/deb/client/build_distribution.sh:454 runs:
    #     fakeroot dpkg-deb -Zxz -z $LEVEL -b "$STAGE" "$DEB"
    # so the final packaging step genuinely needs dpkg-deb. On Arch it lives in the AUR.
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo
        echo "  dpkg-deb was not found, and the build's final packaging step requires it."
        for helper in paru yay pikaur trizen; do
            if command -v "$helper" >/dev/null 2>&1; then
                echo "  Installing dpkg from the AUR with $helper ..."
                "$helper" -S --needed --noconfirm dpkg && break
            fi
        done
    fi
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo
        echo "  Could not install dpkg automatically. Install it from the AUR:"
        echo "      paru -S dpkg      # or: yay -S dpkg"
        echo
        echo "  Alternatively, run the build anyway: the client itself will build fine and the"
        echo "  distribution step will be the only thing that fails. You can then package"
        echo "  straight from the staging tree that step leaves behind:"
        echo "      package/make-cachyos-package.sh \\"
        echo "          $BUILD/vms/distribution/deb/client/client_build_distribution_tmp/*"
        echo
        read -r -p "  Continue without dpkg-deb? [y/N] " reply || reply=""
        case "$reply" in [Yy]*) ;; *) die "install dpkg and re-run" ;; esac
    fi
elif command -v apt-get >/dev/null 2>&1; then
    HOST_MODE=debian
    export DEBIAN_FRONTEND=noninteractive
    ${SUDO:-sudo} apt-get update
    ${SUDO:-sudo} apt-get install -y \
        git curl zip unzip zstd chrpath pkg-config fakeroot dpkg-dev binutils patchelf
else
    die "Neither pacman nor apt-get found; install git curl zip unzip chrpath pkgconf fakeroot dpkg by hand."
fi
echo "Host mode: $HOST_MODE"

# ------------------------------------------------------------------------------------------------
# 2. Sources, pinned to the exact release commit
#
#    A *branch* name must be present (the build reads VCS info), so the release commit is
#    fetched and then checked out onto a local branch named after the release branch.
#    A shallow single-commit fetch keeps the source tree at ~180 MB instead of ~2 GB.
# ------------------------------------------------------------------------------------------------
log "Fetching nx_open @ $NX_TAG"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$NX_REPO"
fi
git -C "$SRC" fetch --depth 1 origin "$NX_COMMIT"
git -C "$SRC" checkout -q -B "$NX_BRANCH" FETCH_HEAD
git -C "$SRC" tag -f "$NX_TAG" FETCH_HEAD >/dev/null

actual=$(git -C "$SRC" rev-parse HEAD)
[ "$actual" = "$NX_COMMIT" ] || die "checked out $actual, expected $NX_COMMIT"
echo "HEAD      : $(git -C "$SRC" log -1 --oneline)"
echo "branch    : $(git -C "$SRC" symbolic-ref --short HEAD)"
echo "describe  : $(git -C "$SRC" describe --tags)"

# ------------------------------------------------------------------------------------------------
# 3. Pinned Python toolchain
#
#    Conan 1.66 pulls in dependencies that import the stdlib `cgi` module, which was removed
#    in Python 3.13 - so the toolchain MUST run on Python <= 3.12 regardless of what the host
#    ships. uv fetches a standalone 3.12 so the host Python is irrelevant.
#    Versions come from the checked-out branch's requirements.txt, never from memory.
# ------------------------------------------------------------------------------------------------
log "Building pinned Python 3.12 toolchain venv"

if ! command -v uv >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm uv
    else
        python3 -m pip install --user --break-system-packages uv 2>/dev/null \
            || python3 -m pip install --user uv \
            || pipx install uv
    fi
fi
export PATH="$HOME/.local/bin:$PATH"

uv python install 3.12
[ -d "$SRC/.venv" ] || uv venv --python 3.12 "$SRC/.venv"
# shellcheck disable=SC1091
source "$SRC/.venv/bin/activate"
uv pip install -r "$SRC/requirements.txt"

echo "python : $(python --version 2>&1)   (must be 3.12.x)"
echo "conan  : $(conan --version 2>&1)    (must be 1.66.0)"
echo "cmake  : $(cmake --version | head -1)  (must be 3.30.4)"
echo "ninja  : $(ninja --version)         (must be 1.10.2)"
case "$(python --version 2>&1)" in *" 3.12."*) ;; *) die "venv is not Python 3.12";; esac

# ------------------------------------------------------------------------------------------------
# 4. Build
#
#    -DdeveloperBuild=OFF    Release configuration; also turns distribution packaging on,
#                            which is what produces the .deb we repackage for CachyOS.
#    -DbuildNumber=43301     must match the release tag; skips fragile git-tag autodetection.
#    -Dwith{MobileClient,Tests,Documentation,Sdk}=OFF  trims build time and disk.
#
#    Set NX_CONAN_DOWNLOAD_CACHE to a directory OUTSIDE the build dir if you have the disk
#    to spare (>= 40G): it keeps a second, tarball copy of the ~10 GB of Conan artifacts so a
#    *clean* rebuild does not re-download them. Skip it when disk is tight - the extracted
#    cache in "$BUILD/.conan" already makes ordinary re-runs cheap.
# ------------------------------------------------------------------------------------------------
# ------------------------------------------------------------------------------------------------
# Conan build profile
#
# Conan is invoked with "--profile:build=default", and auto-generates that profile by detecting
# the host compiler. nx_open ships its own conan_config/settings.yml whose gcc version list stops
# at 14.1, so on a rolling distro like CachyOS (GCC 15/16) detection yields a value Conan then
# rejects:
#
#     ERROR: Invalid setting '16' is not a valid 'settings.compiler.version' value.
#
# Pin a supported version instead. This is only the BUILD profile - it selects build tooling. The
# client itself is compiled with the Conan-supplied clang toolchain named by the HOST profile
# (conan_profiles/linux_x64.profile), so clamping this has no effect on the produced binaries.
#
# conan_config/ ships no profiles directory, so "conan config install" will not overwrite this.
# ------------------------------------------------------------------------------------------------
log "Pinning the Conan build profile"

CONAN_MAX_GCC=14   #< Highest gcc in nx_open's conan_config/settings.yml for this branch.
host_gcc="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
profile_gcc="$CONAN_MAX_GCC"
if [ -n "$host_gcc" ] && [ "$host_gcc" -lt "$CONAN_MAX_GCC" ] 2>/dev/null; then
    profile_gcc="$host_gcc"
fi
echo "host gcc: ${host_gcc:-unknown}  ->  build profile compiler.version=$profile_gcc"

mkdir -p "$BUILD/.conan/profiles"
cat > "$BUILD/.conan/profiles/default" <<PROFILE
[settings]
os=Linux
os_build=Linux
arch=x86_64
arch_build=x86_64
compiler=gcc
compiler.version=$profile_gcc
compiler.libcxx=libstdc++
build_type=Release
[options]
[build_requires]
[env]
PROFILE

# A CMakeCache.txt without conan_paths.cmake means a previous generation died partway (Conan is
# run during generation). The upstream readme is explicit that the cache must be removed before
# retrying, so do it rather than letting build.sh reuse a half-configured cache.
if [ -f "$BUILD/CMakeCache.txt" ] && [ ! -f "$BUILD/conan_paths.cmake" ]; then
    echo "Previous generation did not complete - removing CMakeCache.txt before retrying."
    rm -f "$BUILD/CMakeCache.txt"
fi

log "Building (this takes 1-6 hours depending on core count)"

# Cap parallelism on small-RAM machines; the linker is the memory hog.
ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
cores=$(nproc)
jobs=$cores
[ "$ram_gb" -lt 16 ] && jobs=$(( cores < 4 ? cores : 4 ))
[ "$ram_gb" -lt 8 ]  && jobs=2
echo "cores=$cores ram=${ram_gb}G -> -j$jobs"
export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"

cd "$SRC"
./build.sh \
    -DdeveloperBuild=OFF \
    -DbuildNumber="$NX_BUILD_NUMBER" \
    -DwithMobileClient=OFF \
    -DwithTests=OFF \
    -DwithDocumentation=OFF \
    -DwithSdk=OFF

# ------------------------------------------------------------------------------------------------
# 5. Results
# ------------------------------------------------------------------------------------------------
log "Build artifacts"
ls -la "$BUILD/bin/"*client* 2>/dev/null || true
ls -la "$BUILD/distrib/"*.deb 2>/dev/null || die "no .deb produced in $BUILD/distrib"

echo
echo "Next: package/make-cachyos-package.sh $BUILD/distrib/<name>.deb"
