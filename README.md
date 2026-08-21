# Nx Witness VMS Desktop Client for CachyOS

Build tooling and an installable package for the **Network Optix VMS Desktop Client**, built from
the open-source [`nx_open`](https://github.com/networkoptix/nx_open) sources and pinned to the
**Nx Witness 6.1.3** release, so it can be installed on CachyOS and other Arch-based distributions.

Network Optix ships official Linux clients only as Ubuntu `.deb` packages. There is no Arch build,
and the `.deb` cannot simply be converted — it expects Debian library packages and paths. This
repository builds the client from source and repackages it with a plain shell installer.

**Status: working.** Built, installed and connected to a live Nx Witness 6.1.x server on CachyOS
(KDE/Wayland, Intel graphics).

```
source  : https://github.com/networkoptix/nx_open
tag     : vms/6.1.3/release_43301_all
commit  : a49c2c1c254f2758cd16231c1183c2fc93e6d2ba
version : 6.1.3.43301
protocol: 6113        (identical across 6.1.0 - 6.1.3, so any 6.1.x server pairs)
target  : x86_64
```

## Quick start

On the CachyOS machine:

```bash
paru -S dpkg libxml2-legacy          # see Prerequisites
git clone https://github.com/DorwardTech/NX-Witness-Client-For-CachyOS
cd NX-Witness-Client-For-CachyOS
./install-on-cachyos.sh
```

That builds from source, packages, verifies and installs in one go. Budget **1–6 hours** for the
build depending on core count (72 minutes on 4 cores in testing) and about **25 GB** of free disk.

Then launch **Nx Witness Client (Open Source)** from the application menu, or run
`nxwitness-client`. Connect to `https://<server-ip>:7001` with your Nx Witness credentials.

## Prerequisites

| Package | Why | Where |
| --- | --- | --- |
| `dpkg` | The upstream build's final step runs `fakeroot dpkg-deb -b` (`build_distribution.sh:454`) | **AUR** |
| `libxml2-legacy` | The client links `libxml2.so.2`; current `libxml2` provides `libxml2.so.16` | `extra` |

`build-nx-client.sh` attempts the AUR install itself and prompts if it cannot. If you would rather
not add `dpkg`, the client still builds — only the `.deb` step fails — and
`make-cachyos-package.sh` can package straight from the staging tree left behind in
`nx_open-build/vms/distribution/deb/client/client_build_distribution_tmp/`.

## CachyOS gotchas

Four things break on Arch that never surface on the Ubuntu hosts upstream targets. All are handled
automatically by the scripts; they are recorded here because the failure messages are misleading.

| Symptom | Cause | Handling |
| --- | --- | --- |
| `Invalid setting '16' is not a valid 'settings.compiler.version'` | Conan auto-detects the host GCC; `conan_config/settings.yml` stops at `14.1` | Build profile pinned to `min(host gcc, 14)` |
| `pacman -S dpkg` finds nothing | `dpkg` is not in Arch's official repositories | Installed from the AUR, with a staging-tree fallback |
| `zlib and zlib-ng-compat are in conflict` | CachyOS substitutes `zlib-ng-compat`, which *provides* `zlib` | Dependencies resolved with `pacman -T`, which honours `provides` |
| `error while loading shared libraries: libxml2.so.2` | libxml2 bumped its soname; the package is installed but the soname is not | Depends on `libxml2-legacy` |

The last one is the general lesson: **package presence does not imply soname presence.**
`verify-package.sh` therefore treats any unresolved soname as a hard failure rather than trusting
a package name on the dependency list.

## Running the steps separately

```bash
./build/build-nx-client.sh                                       # build
./package/make-cachyos-package.sh ~/nx_open-build/distrib/*.deb  # package
./package/verify-package.sh ~/nx-client-cachyos                  # check
sudo ~/nx-client-cachyos/install-cachyos.sh                      # install
```

`build-nx-client.sh` is self-contained: it checks disk and network, installs host build tools,
fetches the pinned release commit, builds a Python 3.12 toolchain venv, and runs the upstream
build. The C++ compiler and Qt are **downloaded as Conan artifacts** from Network Optix's
Artifactory — the host distribution's compiler is not used, which is precisely what makes an Arch
build viable.

`make-cachyos-package.sh` also produces a relocatable tarball, so you can build once and install on
other CachyOS machines without rebuilding:

```bash
tar --zstd -xf nx-witness-client-6.1.3.43301-cachyos-x86_64.tar.zst
cd nx-client-cachyos && sudo ./install-cachyos.sh
```

## Building a pacman package

For a proper Arch package managed by pacman, rather than the shell installer:

```bash
./package/arch/make-arch-package.sh ~/nx_open-build/distrib/*.deb
sudo pacman -U package/arch/nx-witness-client-opensource-6.1.3.43301-1-x86_64.pkg.tar.zst
```

`pkgver` tracks the upstream VMS version exactly — `<release>.<buildNumber>`, so `6.1.3.43301`
is nx_open tag `vms/6.1.3/release_43301_all`. The helper reads it from the `.deb` filename, so
packaging a different build needs no edit.

This is a `-bin` style PKGBUILD: it repackages the built `.deb` rather than rebuilding inside
`makepkg`, since a from-source build pulls ~13 GB of Conan artifacts and takes hours. It installs
the same layout as the shell installer, plus a `.install` hook explaining `demoMode`, and
`pacman -R` cleans up properly.

One nicety of going through pacman: `depends=('zlib')` is matched against `provides`, so
CachyOS's `zlib-ng-compat` satisfies it — unlike `pacman -S zlib`, which is what made the shell
installer offer to remove it.

## If it does not start

```bash
./package/diagnose.sh
```

Reports the session type, XWayland availability, every unresolved library together with the object
that needs it, the ini contents, and a timed launch with `QT_DEBUG_PLUGINS=1`. The launcher and
desktop entry both swallow stderr, so a client that aborts before creating a window otherwise
leaves no trace of why.

## Repository layout

| Path | Purpose |
| --- | --- |
| `install-on-cachyos.sh` | One-shot: build → package → verify → install |
| `release.sh` | Tags, builds both artifacts, and publishes a GitHub release |
| `build/build-nx-client.sh` | Reproducible from-source build of the client |
| `package/make-cachyos-package.sh` | Repackages the built `.deb` into a CachyOS tarball |
| `package/install-cachyos.sh` | Root installer (ships inside the tarball) |
| `package/uninstall-cachyos.sh` | Uninstaller (ships inside the tarball) |
| `package/verify-package.sh` | Checks a staged package before it is installed |
| `package/arch/PKGBUILD` | Builds a pacman package, versioned to the VMS release |
| `package/arch/make-arch-package.sh` | Runs `makepkg`, with a dependency-drift check |
| `package/diagnose.sh` | Diagnostics for a client that will not start |
| `docs/BUILD-NOTES.md` | Findings, pitfalls, and source citations |

## Three things worth knowing

**1. `demoMode=1` is mandatory.** An Nx Witness server reports its customization as `default`;
this build is branded `metavms`. Without `demoMode=1` the client refuses to connect with a
customization mismatch. The setting is per user, in `~/.config/nx_ini/desktop_client.ini`. The
installer writes it, and the `nxwitness-client` launcher recreates it for any other user on first
run. A system-wide `/etc/nx_ini/` file is **not** a substitute — `nx_kit` only falls back there
when `$HOME` is unset. Confirmed sufficient on its own against a live 6.1.x server;
`developerMode=1` is documented in [BUILD-NOTES](docs/BUILD-NOTES.md) as a fallback.

**2. The UI says "Nx Meta", not "Nx Witness".** Branding comes from a Customization Package, and
the only one available without a Network Optix developer account is Nx Meta — Network Optix's own
developer-edition branding of the same product. It is cosmetic; it is the same client speaking to
the same server.

**3. Expect a "Beta version" dialog on every launch,** and occasional update notifications. The
publication type is `local`, which is not in the set that suppresses the dialog. Automatic updates
*cannot* replace this build, so the notifications are cosmetic — but decline them anyway: an
official package would not run on Arch. Move VMS versions by rebuilding from the matching tag.

## Releases

Releases are versioned to the upstream VMS release, not independently: the tag is `v` plus
`<release>.<buildNumber>`, so **`v6.1.3.43301`** is nx_open tag `vms/6.1.3/release_43301_all`.
Knowing the client version tells you exactly which server build it was made to match.

To cut one:

```bash
./release.sh                 # reads the version from the built .deb
```

It builds the pacman package and the portable tarball, tags the commit, pushes the tag, and
publishes the release with both artifacts attached (via `gh`, if installed).

The artifacts are ~300 MB each and are **never committed** — they are published as release
assets. The two GitHub limits are easy to conflate:

| | Limit |
| --- | --- |
| File committed into the repository | **100 MB** hard block (50 MB warns) |
| Release asset | **2 GB** per file |

So the package is comfortably within limits as a release asset, and would be rejected outright as
a repository file. `makepkg`'s `pkg/` directory alone is ~875 MB, so `package/arch/{pkg,src}/`
and every artifact extension are gitignored.

## Licence

The `nx_open` sources are licensed under MPL 2.0 by Network Optix. The scripts in this repository
are provided as-is for building and packaging that software.
