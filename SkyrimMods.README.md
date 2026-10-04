# Skyrim mod installer

Written for `Install order.txt` and the inspected Steam runtime **1.7.104.0**.
Prepare/Install have **not been run**. No mods, game binaries or Steam settings
have been changed by authoring it. Static checks do not establish that the game or
Steam Remote Play will actually work; that needs a later authorized live test.

## Terrain setup and remaining ENB compatibility check

The terrain setup uses current Fantasia with Terrain Helper and powerofthree's
Tweaks (`TerrainStrategy: "TerrainHelper"`). Terrain Parallax Blending Fix has
been removed from the install list and catalogue, along with its legacy terrain
staging and INI redirects.
[Author's compatibility notes](https://www.nexusmods.com/skyrimspecialedition/mods/143149).

The supplied configuration still blocks Prepare/Install before downloads or
changes because ENB runtime compatibility has not been established. SKSE
support for the installed runtime does not establish ENBSeries support.
Terrain Helper's 1.7-support changelog warns that ENB does not work on 1.7.
For a supported binary, `EnbCompatibility` must record the runtime, an
authoritative HTTPS evidence URL and the **d3d11.dll** SHA256 (not the archive's
hash). No such support is asserted by the default config. A runtime downgrade
or a different graphics stack needs separate review and is not performed
silently. [SKSE releases](https://skse.silverlock.org/),
[ENB author](https://www.enbdev.com/),
[Terrain Helper changelog](https://www.nexusmods.com/skyrimspecialedition/mods/143149?tab=logs).

Do not fill in compatibility evidence merely to defeat a safety check. Also
review ENB Terrain Blending Fix's native DLL against the selected runtime: the
default configuration does not assert unverified support for that package.

## Steam / Remote Play design

All game assets install directly into the real `Data` directory. Actual
`plugins.txt`, `loadorder.txt` and Skyrim INIs belong to the Windows account
running Steam; there is no mod-manager profile or virtual filesystem to mount.

After generation and validation succeed, the installer compiles
`SteamSkyrimBridge.cs` into the standard `SkyrimSELauncher.exe` entrypoint:

```text
Normal Steam Play / Remote Play
  -> hidden SkyrimSELauncher.exe bridge
  -> skse64_loader.exe -waitforclose
  -> original SkyrimSE.exe
```

The game executable keeps its original name/content. SKSE is still required
internally, but you do not manually open SKSE, PowerShell or another launcher
to play. The bridge waits for the game session, inherits Steam's environment,
uses app ID 489830, requests no elevation, and verifies critical launch hashes.
Errors show a specific message and write a per-user launch log. It never falls
back to an unmodded game. [Official SKSE loader option source](https://github.com/ianpatt/skse64/blob/master/skse64_loader/Options.cpp).

Leave Skyrim's Steam Launch Options empty/default. Remove any Windows
"Run as administrator" flags on Skyrim, its launcher and SKSE. Steam file
verification or a game update can restore the stock launcher/change runtime;
re-review compatibility and rerun the installer afterward. This script does not
alter Steam update settings or claim it can prevent Steam replacing files.
One stock launcher copy is retained only for access to graphics settings.

## Commands, only when you authorize running

Use Windows PowerShell 5.1 or later under the **same Windows account as Steam**.
Installation into Program Files may require elevating that same account.
Start/exit the stock game once beforehand to initialize its real INIs.

```powershell
# Read-only catalogue/plan. Also the default if no Mode is specified.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Plan

# Downloads, CRC-tests, extracts and stages options; does not change Skyrim.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Prepare -WorkPath 'D:\SkyrimModInstaller'

# Direct install and guided generation, then apply the Steam bridge LAST.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Install -WorkPath 'D:\SkyrimModInstaller'

# Same WorkPath/config/account; reuse only verified, matching generator outputs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Install -WorkPath 'D:\SkyrimModInstaller' -Resume
```

Keep WorkPath on a local SSD, outside Skyrim, in a dedicated ordinary directory.
Default is `%LOCALAPPDATA%\SkyrimModInstaller`. Allow substantial disk headroom:
archives, extracted files, staging, Data and outputs can coexist. Configured
160 GiB work/80 GiB game thresholds are conservative minimum checks, **not** a
promise about total space needed. Deployment checks actual staged byte totals.
If work and game share a drive, their requirements consume that same capacity.
Use the same WorkPath on all runs. Prepare and subsequent Install may restage
assets; previous staging runs are retained, not silently recursively deleted.

## Downloads and choices

This is a robust **guided** installer, not a promise of unattended installation:

- Nexus Premium plus a personal API key enables arbitrary automatic Nexus
  downloads. The key is prompted invisibly or read from the process environment
  `NEXUS_API_KEY`; it is not put in config or intentionally logged. Free accounts
  download through Nexus in a browser and provide the downloaded archive paths.
  Access restrictions/captchas are never bypassed. [Nexus API](https://api-docs.nexusmods.com/).
- Portable 7-Zip, xLODGen and LOOT come from their official GitHub releases.
  ENB binaries come from the author's site; if HTTPS resolution fails, supply
  the official browser-downloaded ZIP. No ENB mirror is invented.
- Downloads resume, reject HTTP error bodies and lock archive SHA256/file IDs.
  Every script-managed file download uses `curl --limit-rate 11250000`:
  11.25 MB/s (90 Mbps), approximately 30% of a 300 Mbps connection. Downloads
  are sequential, and the cap also applies to retries/resumed transfers and
  portable-tool downloads. Browser downloads supplied manually are outside
  the script's control.
  `-RefreshDownloads` deliberately re-resolves versions; it also invalidates
  generation when inputs change. Cached files are integrity checked.
- FOMOD groups display concise descriptions and quality/setup hints. Choose
  their exact applicable options. Invalid cardinality, unavailable choices,
  missing sources and unsupported dependency instructions fail closed. Exact
  names are recorded in `fomod.choices.json` for later runs. A new/reviewed
  payload layout can be supplied explicitly; all option folders are never
  blindly mixed into Data.
- Native SKSE/KiLoader DLLs require explicit author runtime evidence and minimum
  versions, where recorded. An unknown existing native DLL is not silently
  treated as compatible. Archive authentication/CRC/hash checks are integrity
  checks, not a malware guarantee or a proof of runtime compatibility.

`SkyrimMods.config.json` can pin each package. Package IDs appear in Plan.
Example entries (replace example values with real verified values):

```json
{
  "Packages": {
    "skyland": { "FileId": 123456, "Sha256": "AUTHOR_OR_VERIFIED_ARCHIVE_SHA256" },
    "skse": { "LocalArchive": "D:\\Downloads\\skse64-matching-runtime.7z" },
    "wildlands-4k": { "LocalArchive": "D:\\Downloads\\NotWL-options.7z" },
    "some-valid-package-id": { "DataRoot": "ReviewedVariant\\Data" }
  },
  "FomodSelections": {
    "package-id/Exact step name/Exact group name": ["Exact option name"]
  },
  "NativeCompatibility": {
    "some-plugin.dll": {
      "Runtimes": ["1.7.104"],
      "MinimumVersion": "1.2.3",
      "EvidenceUrl": "https://author.example/specific-supported-release"
    }
  }
}
```

This fragment is illustrative, not a second executable configuration. Unknown
package IDs fail validation. Supplied native archives need a verified
`NativeVersion` when their Nexus version is unavailable. `DataRoot` bypasses
FOMOD selection and therefore must point at an already reviewed complete
payload, not an entire installer full of alternatives. `ToolExecutable` and
`cabbage.RootDirectory` and `sh2-shader-core.RootDirectory` can disambiguate
relative archive locations. For Shader Core, this is the directory containing
`enbseries`; for Cabbage, it contains the selected Lux `enbseries.ini`.

Alternatively `-ArchiveDirectory 'D:\Downloads\ReviewedMods'` finds archives
named exactly after package IDs, e.g. `smim.7z`, `skyland.zip`. Every Nexus package
must be mapped/supplied to work without an API key. Never store keys in JSON.
`-NonInteractive` fails clearly on unresolved choices/generation; it does not
guess. First-time generators require interaction; verified resume checkpoints
can be reused without re-opening their interfaces.

## Order and documented interpretation of the list

The numbered base overwrite order is preserved, with prerequisites before
their consumers and author updates/compatibility packages immediately after
their corresponding base mod. Plugin order is separate: masters are inspected,
missing/circular masters and engine limits are checked, and LOOT sorts the
selected plugins. Sorting failure is not treated as success merely because
the program exited with code 0.

- Original ERM page is unavailable; catalogue uses the maintained ERM successor
  with separate mesh/texture downloads and ENB complex material, not PBR.
  [ERM successor](https://www.nexusmods.com/skyrimspecialedition/mods/121336).
- QW includes Cathedral Pine Grass, Origins of Forest and Folkvangr prerequisites.
  Skoglendi follows QW as listed, winning conflicting grass records/assets.
  This does **not** create a new hybrid grass patch. If LOOT reverses that intended
  order, the script asks for an explicit LOOT rule rather than pretending the
  overwrite/install order controls plugin conflicts.
- Cathedral suite expands to 13 named plant releases plus the Mountain Flowers
  Hearthfire patch. Xavbio expands to 22 armor/weapon-family releases; it is not
  an imaginary AIO and does not add unrelated clothing/robe releases. Select
  applicable installed-CC options, not patches for paid creations you lack.
- Nordic Faces uses full textures/body, full loose FaceTint, then the author's
  Non-SMP FaceGeom. This retains full-resolution faces without introducing hair
  physics and its extra runtime-sensitive DLL requirements. [Nordic Faces files](https://www.nexusmods.com/skyrimspecialedition/mods/40658?tab=files).
- NAT installs its weather module, not its own competing ENB preset. Cabbage
  uses its Lux variant and author Water for ENB patch. Lux Via **resources only**
  are a lighting prerequisite, not permission to add the Via world overhaul.
- Cabbage stays at **step 23**, after NAT III, Lux Orbis, Lux and the selected
  terrain setup, before PGPatcher and all LOD generation. Its root files deploy
  in this order: **ENBSeries binaries → Silent Horizons 2 - Shader Core →
  Cabbage Lux preset**. Shader Core is required for Cabbage 1.2+ and its
  `enbseries` folder belongs beside `SkyrimSE.exe`. Cabbage then overwrites the
  core's matching files while retaining the required shaders.
  [Cabbage author's requirements and installation](https://www.nexusmods.com/skyrimspecialedition/mods/103042),
  [Shader Core main archive](https://www.nexusmods.com/skyrimspecialedition/mods/101696?tab=files).

After the base setup is finalized: **PGPatcher → xLODGen terrain → TexGen →
DynDOLOD**, with output deployed between steps. Generators use fresh external
output folders; no stale output directory can establish success. PGPatcher's
diff JSON/patched meshes, terrain meshes/textures, TexGen DDS and DynDOLOD
plugins/object meshes are checked. You must also confirm successful generation
after reviewing each tool's errors. Fatal tool errors are not repaired by
inventing dummy masters or auto-cleaning your plugins. GPU/VRAM-sensitive tool
settings are shown as guided choices, not silently selected for unknown hardware.
[PGPatcher usage](https://github.com/hakasapl/PGPatcher/wiki/Basic-Usage),
[xLODGen](https://dyndolod.info/Help/xLODGen),
[TexGen](https://dyndolod.info/Help/TexGen),
[DynDOLOD](https://dyndolod.info/Help/DynDOLOD).

PG_X override plugins must be after normal plugins and before DynDOLOD. The
ESM-flagged PGPatcher.esp contains new texture sets; it is not mistakenly forced
after all ESPs. [PGPatcher output definitions](https://github.com/hakasapl/PGPatcher/wiki/Output).

## Progress, failures and resume

The console shows phase/package and concise status, with long-running external
process heartbeats every 30 seconds. Detailed CRC/extraction/copy/compiler logs,
`installer.log`, and structured `failure.json` are in WorkPath's timestamped Logs
folder. Failure includes phase, package, reason, remedy, failing line and whether
game data may be partial. The installer returns nonzero and never announces a
complete installation after a failed step.

| Exit | Meaning |
| --- | --- |
| 0 | Requested mode completed; live Remote Play is not yet proven |
| 1 | Unexpected failure; inspect line/stack/log |
| 2 | Download, authentication, file selection or checksum |
| 3 | Runtime/configuration conflict, prerequisites, space, archive extraction/CRC, unsafe paths/concurrency |
| 4 | Archive payload, FOMOD choice, native compatibility |
| 5 | Deployment permissions/copy failure |
| 6 | Plugin masters/order/limits/LOOT |
| 7 | Generator/tool/output failure |
| 8 | Steam bridge/critical launch-chain validation |

Resume does not blindly skip "completed" steps: base assets replay in order;
only individually journaled previous generated files are removed first. Outputs
are reused only when their input signature and every saved output hash match.
The base signature includes actual Data content, INIs, load order and launch
binaries. Generator outputs are chained, so changed PGPatcher output invalidates
later stages. Cached archives, choices, checkpoints and logs remain available.
There is no full rollback system; direct overwrites are intentional.

PowerShell syntax, configuration JSON and bridge-manifest XML were checked
without running the installer. The C# bridge source has not been executed or
installed; compilation is a checked installation step before any Data deployment.

While installing, do not start Skyrim or ask Steam to verify/update it. After a
failed Install, do not launch the partially installed game. A previously applied
bridge is marked pending before deployment and refuses play until completion.

## Later live acceptance test

Only after you authorize installation/testing: use Steam's ordinary Skyrim
Play button, verify SKSE/SkyUI and the ENB preset in-game, exit normally, then
start the same Steam entry remotely and check video, controller input, continued
session tracking, and clean exit/relaunch. First ENB shader compilation can take
time. No such game/Remote Play test is performed by this script automatically.
Launch errors go to `%LOCALAPPDATA%\SkyrimModInstaller\LaunchLogs\steam-launch.log`.
