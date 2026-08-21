# Nx Witness VMS Desktop Client for CachyOS

Build tooling and an installable package for the **Network Optix VMS Desktop Client**, built
from the open-source [`nx_open`](https://github.com/networkoptix/nx_open) sources and pinned to
the **Nx Witness 6.1.3** release, so it can be installed on CachyOS and other Arch-based
distributions.

Network Optix ships official Linux clients only as Ubuntu `.deb` packages. There is no Arch
build, and the `.deb` cannot simply be converted — it expects Debian library packages and paths.
This repository builds the client from source and repackages it with a plain shell installer.

```
source  : https://github.com/networkoptix/nx_open
tag     : vms/6.1.3/release_43301_all
commit  : a49c2c1c254f2758cd16231c1183c2fc93e6d2ba
version : 6.1.3.43301
target  : x86_64
```

## Quick start (installing a prebuilt package)

```bash
tar --zstd -xf nx-witness-client-6.1.3.43301-cachyos-x86_64.tar.zst
cd nx-client-cachyos
sudo ./install-cachyos.sh
```

Then launch **Nx Witness Client (Open Source)** from the application menu, or run
`nxwitness-client`. Connect to `https://<server-ip>:7001` with your Nx Witness credentials.

## Building it yourself

```bash
./build/build-nx-client.sh                                  # ~1-6 h depending on cores
./package/make-cachyos-package.sh ~/nx_open-build/distrib/*.deb
./package/verify-package.sh ~/nx-client-cachyos
```

`build-nx-client.sh` is self-contained: it checks disk and network, installs host build tools,
fetches the pinned release commit, builds a Python 3.12 toolchain venv, and runs the upstream
build. The C++ compiler and Qt are **downloaded as Conan artifacts** from Network Optix's
Artifactory — the host distribution's GCC is not used, which is precisely what makes an Arch
build viable.

## Repository layout

| Path | Purpose |
| --- | --- |
| `build/build-nx-client.sh` | Reproducible from-source build of the client |
| `package/make-cachyos-package.sh` | Repackages the built `.deb` into a CachyOS tarball |
| `package/install-cachyos.sh` | Root installer (ships inside the tarball) |
| `package/uninstall-cachyos.sh` | Uninstaller (ships inside the tarball) |
| `package/verify-package.sh` | Pre-flight checks on a staged package |
| `docs/BUILD-NOTES.md` | Findings, pitfalls, and source citations |

## Two things that will bite you

**1. `demoMode=1` is mandatory.** An Nx Witness server reports its customization as `default`;
this build is branded `metavms`. Without `demoMode=1` the client refuses to connect with a
customization mismatch. The setting is per user, in `~/.config/nx_ini/desktop_client.ini`.
The installer writes it, and the `nxwitness-client` launcher recreates it for any other user on
first run. A system-wide `/etc/nx_ini/` file is **not** a substitute — see
[docs/BUILD-NOTES.md](docs/BUILD-NOTES.md).

**2. The UI says "Nx Meta", not "Nx Witness".** Branding comes from a Customization Package, and
the only one available without a Network Optix developer account is Nx Meta — Network Optix's own
developer-edition branding of the same product. It is cosmetic; it is the same client speaking to
the same server.

## Licence

The `nx_open` sources are licensed under MPL 2.0 by Network Optix. The scripts in this
repository are provided as-is for building and packaging that software.
