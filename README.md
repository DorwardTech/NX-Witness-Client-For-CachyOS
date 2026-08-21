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
| `build/build-nx-client.sh` | Reproducible from-source build of the client |
| `package/make-cachyos-package.sh` | Repackages the built `.deb` into a CachyOS tarball |
| `package/install-cachyos.sh` | Root installer (ships inside the tarball) |
| `package/uninstall-cachyos.sh` | Uninstaller (ships inside the tarball) |
| `package/verify-package.sh` | Checks a staged package before it is installed |
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

## Licence

The `nx_open` sources are licensed under MPL 2.0 by Network Optix. The scripts in this repository
are provided as-is for building and packaging that software.
