# Build notes

Findings from building the Nx VMS Desktop Client 6.1.3.43301 for CachyOS. Every claim here was
checked against the sources at commit `a49c2c1c254f2758cd16231c1183c2fc93e6d2ba`
(tag `vms/6.1.3/release_43301_all`); file references are to that commit.

---

## Toolchain

The build does **not** use the host compiler. `readme.md` in `nx_open` is explicit:

> The compiler is downloaded as a Conan artifact during the CMake Generation stage — compilers
> installed in the Linux system (if any) are not used.

The generation stage pulls an `sdk-gcc/9.5` toolchain and a prebuilt Qt 6.9.1 from Network
Optix's Artifactory. That is what makes building on Arch practical: the host's GCC version,
glibc headers and Qt packages are all irrelevant.

Versions are pinned by the checked-out branch's `requirements.txt` — always install from that
file rather than from memory, since the pins differ per branch. For this commit:

| Tool | Version |
| --- | --- |
| conan | 1.66.0 |
| cmake | 3.30.4 |
| ninja | 1.10.2 |

**Conan 1.66 requires Python ≤ 3.12.** Its dependency chain imports the stdlib `cgi` module,
removed in Python 3.13. `build-nx-client.sh` uses `uv` to fetch a standalone CPython 3.12 so the
host's Python version does not matter.

**Never pass `-DinstallSystemRequirements=ON` on Arch.** It is implemented with Conan's Apt
tool and is Debian-only. Install runtime libraries with pacman instead.

---

## Disk: the Conan cache lives inside the build directory

`cmake/conan_utils.cmake:29-33`:

```cmake
if(customConanHome)
    set(ENV{CONAN_USER_HOME} ${customConanHome})
else()
    message(STATUS "Using local CONAN_USER_HOME: ${CMAKE_BINARY_DIR}")
    set(ENV{CONAN_USER_HOME} ${CMAKE_BINARY_DIR})
endif()
```

So the ~13 GB Conan cache is created at `nx_open-build/.conan`, not `~/.conan`. Two consequences:

- Total build-directory size is Conan cache **plus** object files. Budget ~25 GB.
- Deleting the build directory also deletes the Conan cache. `NX_CONAN_DOWNLOAD_CACHE` exists to
  survive exactly that: it keeps a second, tarball-shaped copy elsewhere. It costs several extra
  GB, so it is worth setting only when disk is plentiful. Ordinary re-runs (which keep the build
  directory) do not need it.

Release builds compile without `-g`, and `cmake/process_target_debug_symbols.cmake` only does
anything on macOS, so object files stay comparatively small on Linux.

Source checkout is ~180 MB when fetched as a single shallow commit, versus roughly 2 GB for a
full clone.

---

## Pinning to the release tag

The release tag is *not* the tip of its branch — `vms_6.1.3` has moved past
`vms/6.1.3/release_43301_all`. The build reads VCS information and wants a branch name, so a
plain `git clone --branch <tag>` (detached HEAD) is the wrong shape.

`build-nx-client.sh` fetches the release commit shallowly and checks it out onto a local branch
named `vms_6.1.3`, which satisfies both constraints and keeps the checkout small:

```bash
git fetch --depth 1 origin a49c2c1c254f2758cd16231c1183c2fc93e6d2ba
git checkout -B vms_6.1.3 FETCH_HEAD
```

`git describe --tags` then correctly reports `vms/6.1.3/release_43301_all`.

`-DbuildNumber=43301` is passed explicitly. It must match the tag, and passing it skips the
build's git-tag autodetection.

---

## Installed layout

From `vms/distribution/deb/client/build_distribution.sh`:

```
opt/<companyId>/client/<version>/bin/     client, <installerName>_client, applauncher,
                                          applauncher-bin, client-bin -> client,
                                          translations/, help/, *.dat
opt/<companyId>/client/<version>/lib/     bundled Qt / ffmpeg / WebEngine, plus stdcpp/
opt/<companyId>/client/<version>/libexec/
usr/share/icons/hicolor/<size>/apps/vmsclient-<customization>.png
usr/share/applications/<installerName>.desktop, <uriProtocol>.desktop
```

For the default customization that is `/opt/networkoptix-metavms/client/6.1.3.43301/`. Note this
is **not** a flat `/opt/networkoptix-metavms/` — the version is part of the path, which is how
the applauncher supports several installed versions side by side.

`bin/client` is a shell wrapper, not the ELF binary. It selects a bundled or system `libstdc++`
via `lib/stdcpp/choose_newer_stdcpp.sh`, falls back to a bundled `libOpenGL` when the system has
none, and then execs `bin/<installerName>_client`. **Always launch through the wrapper.**

Binary names, `cmake/properties.cmake:82`:

```cmake
set(client.binary.name "${customization.installerName}_client")   # e.g. metavms_client
set(applauncher.binary.name "applauncher-bin")
```

The installer and packaging scripts discover all of this from the extracted tree rather than
hardcoding it, so they keep working for a different customization or version.

### Why the launcher, not the applauncher

The upstream `.desktop` entry runs `bin/applauncher`, whose job is to pick the newest installed
client version and to support the update mechanism. With a single installed version and updates
disabled it adds only failure modes, so `install-cachyos.sh` points the menu entry at
`bin/client` through `/usr/local/bin/nxwitness-client`.

---

## `demoMode=1` — the customization gate

An Nx Witness server reports customization `default`. This build reports `metavms`. The
compatibility check, `vms/libs/nx_vms_common/src/nx/vms/common/network/server_compatibility_validator.cpp`:

```cpp
bool ServerCompatibilityValidator::isCompatibleCustomization(const QString& remoteCustomization)
{
    ensureInitialized();
    if (s_developerFlags.testFlag(DeveloperFlag::ignoreCustomization))
        return true;
    if (remoteCustomization == nx::branding::customization())
        return true;
    return s_localPeerType == Peer::mobileClient
        ? nx::branding::compatibleCustomizations().contains(remoteCustomization)
        : false;
}
```

For a desktop client the last branch is `false`, so without `ignoreCustomization` the connection
is rejected with `Reason::customizationDiffers`.

`ignoreCustomization` is set from the ini,
`vms/client/nx_vms_client_desktop/src/nx/vms/client/desktop/application_context.cpp:534-546`:

```cpp
ServerCompatibilityValidator::DeveloperFlags developerFlags;
if (ini().developerMode || ini().demoMode)
    developerFlags.setFlag(DeveloperFlag::ignoreCustomization);

if (ini().isAutoCloudHostDeductionMode())
    developerFlags.setFlag(DeveloperFlag::ignoreCloudHost);

if (ini().developerMode || startupParameters.isVideoWallLauncherMode())
    developerFlags.setFlag(DeveloperFlag::ignoreProtocolVersion);
```

and `isAutoCloudHostDeductionMode()` (`ini.cpp`) is true when `demoMode` is set and no explicit
cloud host is configured:

```cpp
return cloudHost == "auto" || (cloudHost.isEmpty() && demoMode);
```

So a single `demoMode=1` clears **both** the customization check and the cloud-host check. The
flag is declared in `ini.h:30`:

```cpp
NX_INI_FLAG(false, demoMode,
    "[Dev] Allow client to connect to servers of all customizations. Enables automatic \n"
    "cloud host deduction if it is not passed explicitly.");
```

### Where the ini file goes

`Ini(): IniConfig("desktop_client.ini")` fixes the filename. The directory comes from
`artifacts/nx_kit/src/nx/kit/ini_config.cpp`, `determineIniFilesDir()`:

```cpp
const std::string env_NX_INI_DIR = getEnv("NX_INI_DIR");
if (!env_NX_INI_DIR.empty())
    return std::string(env_NX_INI_DIR) + kPathSeparator;

const std::string env = getEnv(kIniDirEnvVar);          // HOME
if (!env.empty())
    return std::string(env) + kPathSeparator + extraDir + "nx_ini" + kPathSeparator;

return defaultDir;                                       // "/etc/nx_ini/"
```

This returns the **first** match and does not merge locations. Because `$HOME` is set in any
desktop session, `/etc/nx_ini/` is only ever reached when `HOME` is unset — a system-wide file is
therefore *not* a working way to configure all users. The setting is genuinely per user, which is
why `nxwitness-client` bootstraps it on first run.

Syntax: `name=value`, one per line, `#` comments — the format the client itself writes in
`createDefaultIniFile()`. Booleans are parsed by `nx::kit::utils::fromString`:

```cpp
if (s == "true" || s == "True" || s == "TRUE" || s == "1")
```

so `demoMode=1` is correct. Write it without spaces around `=`.

---

## Version compatibility: 6.1.3 client against any 6.1.x server

`ignoreProtocolVersion` is set by `developerMode`, **not** by `demoMode` — so it is worth knowing
whether the protocol version actually differs across 6.1 releases. It does not.

`cmake/versions/vms_protocol_version.cmake` composes it as major, minor, and an in-version
number:

```cmake
set(_vmsInVersionProtocolNumber 13)
set(vmsProtocolVersion "${PROJECT_VERSION_MAJOR}${PROJECT_VERSION_MINOR}${_vmsInVersionProtocolNumber}")
```

Fetching that file at each 6.1 release tag gives `_vmsInVersionProtocolNumber = 13` for **all**
of 6.1.0, 6.1.1, 6.1.2 and 6.1.3 — protocol version `6113` throughout:

| Release | tag | protocol |
| --- | --- | --- |
| 6.1.0 | `vms/6.1.0/release_42176_all` | 6113 |
| 6.1.1 | `vms/6.1.1/release_42624_all` | 6113 |
| 6.1.2 | `vms/6.1.2/release_42921_all` | 6113 |
| 6.1.3 | `vms/6.1.3/release_43301_all` | 6113 |

So a 6.1.3 client connects to any 6.1.x server without `developerMode`, and `demoMode=1` alone is
sufficient. A 6.0.x or 7.x server is a different matter — the in-version number resets on a
minor-version bump, so rebuild from the matching tag.

The four rejection reasons, and what clears each:

| `Reason` | Cleared by |
| --- | --- |
| `customizationDiffers` | `demoMode=1` (or `developerMode=1`) |
| `cloudHostDiffers` | `demoMode=1`, or `cloudHost=auto` |
| `binaryProtocolVersionDiffers` | `developerMode=1` — not needed for 6.1.x, see above |
| `versionIsTooLow` | nothing; server must be ≥ 4.0 for `connect` |

---

## Runtime dependencies

Authoritative list: `vms/distribution/deb/client/deb_dependencies.yaml`. Everything else is
bundled inside `lib/` with RPATHs already set, so the system list is short. Debian → Arch:

| Debian | Arch |
| --- | --- |
| `libegl1`, `libgl1`, `libopengl0` | `libglvnd` |
| `libglu1-mesa` | `glu` |
| `libfontconfig1` | `fontconfig` |
| `libfreetype6` | `freetype2` |
| `libasound2` / `libasound2t64` | `alsa-lib` |
| `libpulse0`, `libpulse-mainloop-glib0` | `libpulse` |
| `libsecret-1-0` | `libsecret` |
| `libx11-6`, `libx11-xcb1` | `libx11` |
| `libxcb-glx0`, `-randr0`, `-shape0`, `-shm0`, `-sync1`, `-xfixes0`, `-xinerama0`, `-xkb1` | `libxcb` |
| `libxcb-cursor0` | `xcb-util-cursor` |
| `libxcb-image0` | `xcb-util-image` |
| `libxcb-keysyms1` | `xcb-util-keysyms` |
| `libxcb-render-util0` | `xcb-util-renderutil` |
| `libxcb-icccm4` | `xcb-util-wm` |
| `libxcb-util1` | `xcb-util` |
| `libxext6` | `libxext` |
| `libxfixes3` | `libxfixes` |
| `libxkbcommon0` | `libxkbcommon` |
| `libxss1` | `libxss` |
| `zlib1g` | `zlib` |
| `libglib2.0-0` / `-0t64` | `glib2` |
| `libdbus-1-3` | `dbus` |
| `libexpat1` | `expat` |
| `libnspr4` | `nspr` |
| `libnss3` | `nss` |
| `libxcomposite1` | `libxcomposite` |
| `libxi6` | `libxi` |
| `libxkbfile1` | `libxkbfile` |
| `libxml2` | `libxml2` |
| `libxrandr2` | `libxrandr` |
| `libxrender1` | `libxrender` |
| `libxslt1.1` | `libxslt` |
| `libxtst6` | `libxtst` |
| `debconf` | n/a — Debian packaging only |

Two additions that are not in the yaml but matter in practice:

- **`libxkbcommon-x11`** — Qt's `xcb` platform plugin needs `libxkbcommon-x11.so.0`. On Ubuntu it
  arrives transitively; on Arch it is a separate package and its absence produces the classic
  "could not load the Qt platform plugin xcb".
- **`mesa`** — provides the actual GL driver, as opposed to `libglvnd`'s dispatch layer.

The yaml also *recommends* `binutils`; it is not required to run the client.

---

## Automatic updates

Open-source builds are not updated in place — an official update package would replace this
build with a stock Nx build that does not run on Arch. Decline any client update the server
offers, and move VMS versions by rebuilding from the matching release tag instead.

---

## Troubleshooting the build

| Symptom | Cause / fix |
| --- | --- |
| Conan cannot reach `artifactory.nxvms.dev` | Network policy or outage. Nothing can be built without it; fix access and re-run `./build.sh`. |
| `ModuleNotFoundError: cgi` | The venv is Python ≥ 3.13. Recreate with `uv venv --python 3.12`. |
| "VCS info cannot be read" | Detached HEAD or non-git directory — use the branch checkout described above. |
| Generation fails, odd cache state | `rm -f nx_open-build/CMakeCache.txt`, then re-run. The upstream readme calls this out explicitly. |
| Linker killed, exit 137 | RAM exhaustion. Resume with `cmake --build nx_open-build -- -j2`; ninja picks up where it stopped. |
| Transient Conan download failure | Just re-run the same `./build.sh` command. |
