# Skyrim downgrade record and steps

Prepared on **October 3, 2026**; cancelled on **October 4, 2026**, America/Winnipeg.

**Current state: cancelled.** The user cancelled the downgrade and decided to
use a setup without ENB. Skyrim remains **1.7.104.0**. All nine affected game
files still match their original 1.7.104 hashes and Steam's update settings are
unchanged. The installer configuration matched its original backup when the
downgrade was cancelled; it was subsequently updated for the Community Shaders
[V2 installer](SkyrimMods.README.md), retaining runtime 1.7.104.0.
**No game or Steam changes need reversing.**

The earlier apply attempt stopped before any changes because Dota 2 was
running. The local state is now `Cancelled`; both prepare and apply helpers
reject that state. Prepared files and backups remain available as historical
artifacts. The steps below record the abandoned plan and do not authorize
resuming it.

## Target and sources

The abandoned downgrade sought the latest Skyrim version with verified ENB
support. Its selected Steam runtime was **1.6.1170.0**. Terrain Helper's
author lists 1.6.1170 among supported versions and explicitly warns in the
1.1.0 changelog that ENB does not work with 1.7 yet. This is compatibility
evidence for selecting the target; this session has not performed a live ENB
test.

- [Terrain Helper files and supported runtimes](https://www.nexusmods.com/skyrimspecialedition/mods/143149?tab=files).
- [Terrain Helper changelog and ENB warning](https://www.nexusmods.com/skyrimspecialedition/mods/143149?tab=logs).
- [ENB author's download page](https://www.enbdev.com/download_mod_tesskyrimse.html).

Replacement files were built from binary patches published in the
[Skyrim Runtime Swapper repository](https://github.com/Modding-Forge/Skyrim-Runtime-Swapper),
pinned to commit `edb7bc06a1ef299fb32cdd1eba79782ff080fca3`. The selected catalog
is the uncleaned **1.7.104-to-1.6.1170** catalog, whose `variant` is `boaw`.
It restores the older executable, launcher, shaders, interface archive and
official masters. Its
[profile documentation](https://moddingforge.com/docs/skyrim-runtime-swapper/profiles)
explains the files associated with this profile. Relevant files are restored;
this is not a download or replacement of every game file.

The session uses that project's published patch data with the standalone
HDiffPatch command-line tool. The Runtime Swapper application, injected DLL
and automatic runtime switching are not part of the prepared deployment.

- [Pinned patch manifest, including every source, patch and target SHA256](https://raw.githubusercontent.com/Modding-Forge/Skyrim-Runtime-Swapper/edb7bc06a1ef299fb32cdd1eba79782ff080fca3/assets/runtime/1.7.104-to-1.6.1170/manifest.json).
- [HDiffPatch 5.1.3 official release](https://github.com/sisong/HDiffPatch/releases/tag/v5.1.3).
- Downloaded tool archive: `hdiffpatch_v5.1.3_bin_windows64.zip`.
- Verified archive SHA256:
  `77f141386e5d8f785c1c846e10fbbc19b6c05aa00e3f59cc44670fb3f0e2ae94`.

The source Steam depot manifests match the locally installed Steam manifest:

| Depot | Installed 1.7.104 manifest | Catalog's 1.6.1170 manifest |
| --- | --- | --- |
| 489831 | 4940892828028256588 | 8442952117333549665 |
| 489832 | 5728778377666085157 | 8042843504692938467 |
| 489833 | 4886117324142477814 | 1914580699073641964 |

No Steam login or Nexus API key was needed to prepare these published patches.

## Inspected setup

- Game: `C:\Program Files (x86)\Steam\steamapps\common\Skyrim Special Edition`.
- Steam: `C:\Program Files (x86)\Steam\steam.exe`.
- Steam app: `489830`; installed build ID: `24914197`; language: English.
- Inspected executable version: `SkyrimSE.exe` **1.7.104.0**.
- All nine affected files matched the catalog's original Steam SHA256 hashes.
- Skyrim, its launcher and SKSE were closed during preparation.
- Existing game-root SKSE files included `skse64_loader.exe` and
  `skse64_1_6_1170.dll`, with the extracted `skse64_2_02_06` directory.
  Its bundled changelog states that SKSE 2.2.6 supports 1.6.1170. These were
  already present before this downgrade task; game launch was not tested.
- No native DLLs were found in `Data\SKSE\Plugins` during inspection.
- Installed official plugins included the base/DLC masters, Fishing, Saints
  and Seducers, Rare Curios, Survival Mode and `_ResourcePack.esl`.
- The mod installer configuration still expects `1.7.104.0` and records
  native-mod compatibility evidence for that runtime.
- `ContentCatalog.txt` was absent from the local Skyrim profile at inspection.
- Steam's `AutoUpdateBehavior` remains `0`; its Skyrim manifest remains
  writable. Those settings have not yet been changed.

## Local artifacts and backups

The downgrade working folder on this computer is:

```text
C:\Users\Scott\AppData\Local\SkyrimDowngrade\20261003-1.6.1170
```

Its `%LOCALAPPDATA%` equivalent is
`%LOCALAPPDATA%\SkyrimDowngrade\20261003-1.6.1170`.

| Artifact | Purpose and present state |
| --- | --- |
| `manifest.json` | Pinned catalog of nine original, patch and target hashes |
| `downloads\` | Verified HDiffPatch release archive |
| `tools\windows64\hpatchz.exe` | Extracted official patch tool |
| `patches\forward\` | Nine downloaded forward patches, hash and size checked |
| `staged\` | Nine verified 1.6.1170 replacement files |
| `backup\game\` | Nine original 1.7.104 files, hash checked |
| `backup\profile\` | Copies of Skyrim saves, INIs and SKSE profile files |
| `backup\local-profile\` | Copies of files from the local Skyrim profile |
| `backup\SkyrimMods.config.json` | Original installer configuration |
| `patcher.log` | Output from creating the staged replacement files |
| `state.json` | Current status: `Cancelled`; reason and cancellation time recorded |
| `Prepare-Downgrade.ps1` | Local preparation helper; rejects the cancelled state |
| `Apply-Downgrade.ps1` | Local deployment helper; rejects the cancelled state |
| `Restore-1.7.104.ps1` | Local helper for restoring a completed downgrade |

These helpers, binaries, backups and game files are **local artifacts outside
the Git repository**. This documentation commit does not contain them.
Keep the working folder to retain restoration and verification material.

All **88 save files** were individually compared against their backup copies
using SHA256, and all matched. The original saves remain in their normal
location. Steam's manifest backup and `restore-metadata.json` were never
created because deployment did not start.

## Preparation completed

1. Read the actual executable version and Steam depot metadata.
2. Verified the author's runtime/ENB compatibility guidance and chose
   1.6.1170.0.
3. Selected the pinned nine-file catalog and checked every source file's
   SHA256 against the installed game. All nine matched.
4. Downloaded HDiffPatch 5.1.3 from its official GitHub release and verified
   the archive SHA256 against the release asset digest.
5. Downloaded the nine forward patches from the pinned catalog commit,
   checking each patch's published SHA256 and byte length. Downloads were
   sequential and capped at **11.25 MB/s**, matching the existing installer's
   download cap.
6. Copied each original game file into `backup\game`, verified that copy,
   and applied its patch to a separate output in `staged`.
7. Checked every output's SHA256 and byte length against the catalog.
   The staged executable's file version is **1.6.1170.0**.
8. Backed up the Skyrim profile, local profile files and installer
   configuration; separately verified the 88 save backups.
9. Parsed the prepare, apply and restoration helpers with PowerShell's
   syntax parser. All parsed successfully.
10. Attempted the apply step. Its running-game check detected `dota2.exe`
    and stopped before closing Steam or changing Skyrim, the installer
    configuration or Steam settings.
11. Rechecked the installed nine files afterward; all still matched their
    original **1.7.104** hashes.
12. On October 4, cancelled the downgrade at the user's request, reverified
    all nine original game files, confirmed the configuration and Steam
    settings were unchanged, and marked the local state `Cancelled`.

Prepared replacement files:

| File | Verified target bytes |
| --- | ---: |
| `SkyrimSE.exe` | 37,157,144 |
| `SkyrimSELauncher.exe` | 4,713,472 |
| `Data\Skyrim - Shaders.bsa` | 67,308,970 |
| `Data\Skyrim - Interface.bsa` | 105,799,354 |
| `Data\Skyrim.esm` | 249,753,412 |
| `Data\Update.esm` | 18,874,041 |
| `Data\Dawnguard.esm` | 25,885,111 |
| `Data\HearthFires.esm` | 3,977,420 |
| `Data\Dragonborn.esm` | 64,663,863 |

## Historical application steps: cancelled

**Do not run this step. The user cancelled it and the helper now rejects it.**
The following command and behavior document the previously prepared method.
That method required closing other Steam games, using the same Windows
account and, if required, elevation to write the Program Files installation.

```powershell
$downgradeRoot = Join-Path $env:LOCALAPPDATA 'SkyrimDowngrade\20261003-1.6.1170'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $downgradeRoot 'Apply-Downgrade.ps1')
```

The helper will:

1. Require `state.json` to be `Prepared`, check that Steam games are closed,
   and verify the original game files, backups and staged outputs again.
2. Ask Steam to shut down gracefully. If it does not close within 45 seconds,
   stop without deploying the downgrade.
3. Back up `appmanifest_489830.acf` and record its attributes and restoration
   metadata.
4. Replace the nine game files from the verified staged outputs. Each
   replacement is copied to a temporary file, hash checked, then swapped
   into place with Windows' file replacement API and hash checked again.
5. If a `ContentCatalog.txt` has appeared, preserve it under the suffix
   `.before-1.6.1170-20261003` so the older game can regenerate its catalog.
6. Update only the local installer's `ExpectedRuntime` to `1.6.1170.0`.
   Existing native-mod compatibility evidence remains in place for separate
   review.
7. Set Steam's Skyrim update mode to `AutoUpdateBehavior = 1` (update on
   launch), then make that app manifest read-only to help preserve the
   downgraded setup.
8. Verify all nine installed target hashes and executable version, write
   `Status = Complete` to `state.json`, then restart Steam if it was running.

If applying a replacement fails, the helper attempts to restore the affected
original files and any settings already changed from their backups. Retain
the working folder and inspect the error if restoration itself fails.

Steam's manifest protection is not a guarantee against game updates.
**Steam file verification or reinstalling can replace the downgraded files.**
Do not use either operation while intending to keep this setup.

## Historical verification steps

```powershell
$gameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Skyrim Special Edition'
$downgradeRoot = Join-Path $env:LOCALAPPDATA 'SkyrimDowngrade\20261003-1.6.1170'

(Get-Item -LiteralPath (Join-Path $gameRoot 'SkyrimSE.exe')).VersionInfo.FileVersion
Get-Content -LiteralPath (Join-Path $downgradeRoot 'state.json')

$catalog = Get-Content -Raw -LiteralPath (Join-Path $downgradeRoot 'manifest.json') | ConvertFrom-Json
foreach ($entry in $catalog.files) {
    $actual = (Get-FileHash -LiteralPath (Join-Path $gameRoot $entry.path) -Algorithm SHA256).Hash
    if ($actual -ne $entry.targetSha256) { throw "Target hash mismatch: $($entry.path)" }
}
```

Successful deployment should report `1.6.1170.0`, `Status = Complete` and
matching target hashes for all nine files. This check does not launch Skyrim.

## Historical restoration steps

The restoration helper requires a completed downgrade and unchanged target
files. Close Skyrim and other Steam games first:

```powershell
$downgradeRoot = Join-Path $env:LOCALAPPDATA 'SkyrimDowngrade\20261003-1.6.1170'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $downgradeRoot 'Restore-1.7.104.ps1')
```

It verifies the original backups, closes Steam gracefully, restores the nine
original files, restores the saved installer configuration and Steam manifest
with its original attributes, and restores the older catalog backup if one
was made. It then checks for **1.7.104.0**, records `Status = Restored` and
restarts Steam if needed. Current saves are kept; profile backups are
available separately if a save or INI restoration is wanted.

Do not run the restoration helper: the game is already on 1.7.104.0 and
`state.json` is `Cancelled`. No restoration is needed.

## Remaining mod setup and live testing

**Current decision: stay on 1.7.104.0 and exclude ENB.** The installer still
implements the earlier ENB/Cabbage plan and needs revision before use with
that decision. The notes below describe prerequisites of the abandoned ENB
plan; they are retained as history.

The existing [mod installer documentation](SkyrimMods.README.md) describes
the graphics list, download choices, generators and Steam/SKSE bridge.
Its `Prepare` and `Install` modes have **not been run** in this session.
ENB/Cabbage and the planned graphics mods have not been deployed. The game
launcher is still the stock launcher; the Steam/SKSE bridge has not been
installed.

After the downgrade is applied, review every native-mod package and its
configuration evidence against **1.6.1170**. The current `NativeCompatibility`
entries for KiLoader, ENB Extender, EVLaS, Terrain Helper, powerofthree's Tweaks
and DynDOLOD DLL still name **1.7.104**. Updating `ExpectedRuntime` alone does
not establish that these packages are compatible. Select a matching SKSE
build and matching Address Library; use author-supported package versions
and keep the installer's evidence checks intact.

Finally, test game startup, the desired ENB preset and the Steam/Remote Play
launch path after the required mods and bridge are installed. No Skyrim,
ENB or Steam Remote Play launch test was performed during this downgrade
preparation. Compatibility of existing saves with the downgraded game has
not been tested.
