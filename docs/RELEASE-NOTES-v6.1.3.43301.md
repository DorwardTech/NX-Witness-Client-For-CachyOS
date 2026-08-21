Nx Witness / Nx Meta VMS Desktop Client for **CachyOS and other Arch-based distributions**, built
from the open-source [`nx_open`](https://github.com/networkoptix/nx_open) sources. Network Optix
ships official Linux clients only as Ubuntu `.deb` packages, so this is built from source and
repackaged for Arch.

Version tracks the upstream VMS release exactly — `<release>.<buildNumber>`:

| | |
| --- | --- |
| VMS version | `6.1.3.43301` |
| nx_open tag | `vms/6.1.3/release_43301_all` |
| commit | `a49c2c1c254f2758cd16231c1183c2fc93e6d2ba` |
| binary protocol | `6113` |
| architecture | `x86_64` |

**Server compatibility:** any **Nx Witness 6.1.x** server. Protocol `6113` is identical across
6.1.0, 6.1.1, 6.1.2 and 6.1.3, so the client is not tied to 6.1.3 servers specifically. A 6.0.x
or 7.x server needs a rebuild from the matching tag.

## Install

```bash
sudo pacman -S libxml2-legacy
tar --zstd -xf nx-witness-client-6.1.3.43301-cachyos-x86_64.tar.zst
cd nx-client-cachyos
sudo ./install-cachyos.sh
```

The installer pulls the remaining runtime libraries with pacman, installs the client under
`/opt/networkoptix-metavms/client/6.1.3.43301/`, and adds a `nxwitness-client` launcher plus a
menu entry.

### `libxml2-legacy` is required

The client links `libxml2.so.2`. Current `libxml2` (2.15) provides `libxml2.so.16`, so **the
package being installed is not enough** — without `libxml2-legacy` the client exits immediately
with no window and this in the terminal:

```
error while loading shared libraries: libxml2.so.2: cannot open shared object file
```

On a Wayland session you also need `xorg-xwayland`; the client uses Qt's `xcb` platform plugin.

## Connecting

Launch **Nx Witness Client (Open Source)** from the menu, or run `nxwitness-client`. Choose
*Connect to Server* and enter `https://<server-ip>:7001` with your Nx Witness credentials.

## Expected behaviour worth knowing about

**The UI is branded "Nx Meta", not "Nx Witness."** Branding comes from a Customization Package,
and the only one available without a Network Optix developer account is Nx Meta — Network Optix's
own developer-edition branding of the same product. Cosmetic only; same client, same server.

**A "Beta version" dialog appears on every launch.** The publication type is `local`, which isn't
in the set that suppresses it. Dismiss it.

**Automatic updates cannot work, by design.** An official update package would replace this build
with a stock Nx one that doesn't run on Arch. Update notifications may still appear — decline
them. To move VMS versions, rebuild from the matching release tag.

**`demoMode=1` is required and handled for you.** An Nx Witness server reports its customization
as `default` while this build is `metavms`; without the flag the client refuses to connect. The
launcher writes `~/.config/nx_ini/desktop_client.ini` on first run for each user, so no manual
step is needed. It must be per user — `/etc/nx_ini/` is only consulted when `$HOME` is unset.

## Verified

Built, installed and connected to a live Nx Witness 6.1.x server on CachyOS (KDE / Wayland, Intel
graphics). Package verification resolves 143 ELF objects against the bundled tree with no
unexplained libraries.

## Also available

- **pacman package** — `./package/arch/make-arch-package.sh` builds
  `nx-witness-client-opensource-6.1.3.43301-1-x86_64.pkg.tar.zst`, installable with `pacman -U`
  and removable with `pacman -R`.
- **Build from source** — `./install-on-cachyos.sh` builds, packages, verifies and installs in one
  step. Roughly 1–6 hours and ~25 GB of disk; needs `dpkg` from the AUR.

Uninstall with `sudo ./uninstall-cachyos.sh` (add `--purge` to drop per-user settings).

See the [README](https://github.com/DorwardTech/NX-Witness-Client-For-CachyOS) and
[BUILD-NOTES](https://github.com/DorwardTech/NX-Witness-Client-For-CachyOS/blob/main/docs/BUILD-NOTES.md)
for the build process and the Arch-specific pitfalls.
