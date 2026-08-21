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

Several of these are *also* bundled. The Conan package
`os_deps_for_desktop_linux/ubuntu_focal` contributes `libXss.so.1`, `libxcb-cursor.so.0`,
`libxcb-xinerama.so.0`, `libxcb-shape.so.0`, `libxkbcommon.so.0`, `libxkbcommon-x11.so.0` and
`libOpenGL.so.0`, pulled in through `-L` flags that package injects into
`CMAKE_EXE_LINKER_FLAGS` (`os_deps.cmake:26-35`), carried via `build_distribution.conf.in`, and
copied into the bundle by `copy_system_library.py`. `cmake/dependencies.cmake:11` even sets
`CMAKE_FIND_USE_CMAKE_SYSTEM_PATH OFF`. Installing the pacman equivalents anyway is harmless and
guards against a bundled copy being unusable, which is why they stay on the list.

The same mechanism is why **`gstreamer`, `gst-plugins-base-libs` and `libpng` must NOT be added**
to the pacman list — they come from Conan and are bundled, not taken from the distro.

Two additions that are not in the yaml but matter in practice:

- **`libxkbcommon-x11`** — Qt's `xcb` platform plugin needs `libxkbcommon-x11.so.0`. On Ubuntu it
  arrives transitively; on Arch it is a separate package and its absence produces the classic
  "could not load the Qt platform plugin xcb".
- **`mesa`** — provides the actual GL driver, as opposed to `libglvnd`'s dispatch layer.

The yaml also *recommends* `binutils`; it is not required to run the client.

---

## Automatic updates, and the prompts that still appear

The client **cannot** resolve an update package in this build, for two independent reasons:

- `publicationType` is `local`, which falls through to `default: return false` in
  `publicationTypeAllowed()` (`releases_info.cpp:26-27`), gating `selectDesktopClientRelease`.
- `branding::customClientVariant()` is `open-source`, so `findPackage` demands a package carrying
  `Component::customClient` with a matching `open-source` variant
  (`update_verification.cpp:258-259` → `publication_info.cpp:47-59`). Nx's public release packages
  do not carry it.

So an update cannot silently replace this build. Two prompts do still appear, and both are
expected and harmless:

- **"Beta version" dialog on every launch.** `publicationType=local` is not in `{patch, release}`,
  so `startup_actions_handler.cpp:398-408` shows it each time. Dismiss it.
- **"<version> is available" notification.** `selectVmsRelease` has no publicationType filter and
  polls `https://updates.vmsproxy.com/metavms/releases.json` on a 60-minute timer
  (`workbench_update_watcher.cpp:49`). Ignore it — the download cannot succeed anyway.

The "Client auto-updates" feature informer will *not* fire: `ClientUpdateSettings::enabled` is
computed in a constructor (`client_update_settings.cpp:10-14`), not from the header initialiser,
and with `customClient=true` for the metavms customization the compiled default is `false`.

Move VMS versions by rebuilding from the matching release tag, not by accepting an update.

---

## Residual risk: what could not be verified from this repository

Everything above is checked against source. Two things honestly cannot be:

**1. Server-side acceptance of a `metavms` peer.** `demoMode=1` provably suppresses the
*client-side* customization check. Whether the server also rejects a differently branded peer is
not knowable here — `vms/server/` in this repository contains only `api`, `nx_server_plugin_sdk`,
`plugins` and `stub_analytics_api_integration`; the mediaserver core is not open-sourced.

Relevant detail: `demoMode` does **not** blank the client's advertised identity. Only
`developerMode` does — `vms/client/nx_vms_client_desktop/src/nx/vms/client/desktop/system_context.cpp:76-77`:

```cpp
runtimeData.brand = ini().developerMode ? QString() : nx::branding::brand();
runtimeData.customization = ini().developerMode ? QString() : nx::branding::customization();
```

So with `demoMode=1` alone the client still reports `brand=metavms`, `customization=metavms` in its
`RuntimeData`. Two things suggest that is fine: `RuntimeData::operator==` is hand-written
specifically to skip brand and customization (`runtime_data.h:69-73`), and `RuntimeData_Fields`
omits `customization` from serialisation. But it is inference, not proof.

**If the server rejects the connection despite `demoMode=1`,** add `developerMode=1` to the same
ini file. It blanks the advertised brand and customization, and additionally sets
`ignoreProtocolVersion`. The cost is that developer UI affordances become visible.

**2. Arch package names.** The Debian → Arch mapping was produced on a Debian container with no
`pacman` available to check it against. The `.so`-level analysis is verified; the Arch package
names on the right-hand side are asserted from knowledge. `verify-package.sh` re-derives the real
requirement empirically with `ldd` against the built tree, which is the check that actually
matters.

---

## Escaping a protocol-version mismatch

Not needed for a 6.1.x server (all report `6113`), but if a future pairing ever mismatches there
are three ways past `binaryProtocolVersionDiffers`, in increasing order of bluntness:

1. `developerMode=1` in `desktop_client.ini` → sets `ignoreProtocolVersion`
   (`application_context.cpp:542-543`).
2. Connecting via `Purpose::connectInCompatibilityMode` / `connectInCrossSystemMode`, which skip
   the check (`server_compatibility_validator.cpp:90,93`).
3. Launching with `--override-protocol-version <N>` (`client_startup_parameters.cpp:98` →
   `application_context.cpp:196-197`). This is ungated in release builds and rewrites the number
   the client reports. Blunt, but it exists.

Confirmed for this build from the generated source,
`nx_open-build/vms/libs/nx_vms_api/protocol_version.cpp:16`:

```cpp
return protocolVersionOverride > 0 ? protocolVersionOverride : 6113;
```

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
| `ERROR: Invalid setting '16' is not a valid 'settings.compiler.version' value` | Rolling-release distro with a GCC newer than Conan knows. See below. |

### `Invalid setting '<N>' is not a valid 'settings.compiler.version' value`

Conan is invoked with `--profile:build=default` and generates that profile by detecting the host
compiler. `conan_config/settings.yml` in this branch lists gcc versions only up to `14.1`, so on
CachyOS or any rolling distro shipping GCC 15/16 the detected value is rejected and generation
fails with the generic `Conan execution failed.` wrapper from `cmake/utils.cmake:425`.

The real Conan error is printed above that wrapper — `run_conan.cmake` uses `COMMAND_ECHO STDERR`
and does not capture output, and it retries once with `--update`, so there are two blocks of
Conan output to scroll back through. To see it on its own:

```bash
.venv/lib/python3.12/site-packages/cmake/data/bin/cmake \
    -DinstallSystemRequirements=OFF -P ~/nx_open-build/run_conan.cmake
```

`build-nx-client.sh` now pins the profile before building. To fix an existing build directory by
hand, write `$CONAN_USER_HOME/.conan/profiles/default` (where `CONAN_USER_HOME` is the build
directory) with `compiler.version=14`, then delete `CMakeCache.txt` and re-run.

This only affects the **build** profile, which selects build tooling. The client is compiled with
the Conan-supplied clang toolchain named by the host profile
(`conan_profiles/linux_x64.profile`), so clamping the value does not change the binaries.
`conan_config/` ships no `profiles/` directory, so `conan config install` will not overwrite it.
