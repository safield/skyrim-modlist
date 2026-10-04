# Skyrim V2 mod installer

The installer follows **V2 USE THIS ONE** in `Install order.txt`, on the existing
Steam Skyrim runtime **1.7.104.0**. It uses **Community Shaders, NAT.CS III and
Non-Effects11 Lux CS**. The historical V1 section is ignored. Configuration pins
the normalized V2 section so edits to historical V1 do not invalidate the plan;
changes to V2 require reviewing the catalogue and updating that pin.

The downgrade was cancelled on October 4, 2026. No downgrade, mod installation,
INI changes or Steam changes were performed while updating this installer.
Backups remain available; see [the cancelled downgrade record](SkyrimDowngrade.README.md).
Prepare and Install are guided operations to run when installation is wanted.
A live game/Remote Play test is still required after installation.

## V2 graphics and lighting order

| Step | Package / behavior |
| --- | --- |
| 1–18 | V2 meshes, textures, vegetation, water, faces and UI, in the listed overwrite order |
| 19 | NAT.ENB **weather ESP only**, exactly `NAT.ENB - ESP WEATHER PLUGIN v3.1.1C - Fixed` |
| 20 | Official Community Shaders core, minimum 1.9.1 |
| 21 | Skylighting, minimum 1.5.2; Cloud Shadows is already bundled with CS |
| 22 | NAT.CS III overwrites the earlier NAT weather files |
| 23 | Light Placer, minimum 5.0.0 |
| 24 | ISL Helper SKSE, minimum 1.0.6 |
| 25–26 | Lux Orbis, Lux, their resources/updates and applicable official patches |
| 27 | Lux CS, minimum 2.6.0; **Non-Effects11**, with Light Placer/ISL and applicable Orbis options |
| 28–31 | PGPatcher → xLODGen terrain → TexGen → DynDOLOD 3 |

Community Shaders 1.9 supports the 1.7 game runtimes. The official core includes
Cloud Shadows, Extended Materials and Inverse Square Lighting. Skylighting is
a separate feature package. The installer validates those payloads and rejects
an Effects11 feature file, including one bundled in an AIO archive.
[CS changelog](https://www.nexusmods.com/skyrimspecialedition/mods/86492?tab=logs),
[official 1.9.1 release](https://github.com/community-shaders/skyrim-community-shaders/releases/tag/v1.9.1),
[Skylighting](https://www.nexusmods.com/skyrimspecialedition/mods/139352).

NAT.CS requires the older NAT weather ESP as its base; its ENB name does not
authorize installing ENB binaries or a preset. Keep optional NAT.CS water
shadows unselected: they require an additional brightness/reflection fix
outside this V2 catalogue.
[NAT.CS requirements](https://www.nexusmods.com/skyrimspecialedition/mods/139567).

The Lux CS FOMOD automatically chooses the unique Non-Effects11 option when
its group allows exactly one choice and no choice is saved. A saved Effects11
choice fails with a correction message. An installer lacking an identifiable
Non-Effects11 choice also fails. A reviewed plain archive or `DataRoot` override
requires `Packages.lux-cs.Variant: "Non-Effects11"`. Select the Light Placer/ISL
and Orbis options when offered; other FOMOD choices remain guided.
[Lux CS requirements and 2.6 variants](https://www.nexusmods.com/skyrimspecialedition/mods/153919),
[Light Placer runtime support](https://www.nexusmods.com/skyrimspecialedition/mods/127557?tab=logs).

Prerequisites install before their consumers: matching SKSE, Address Library,
powerofthree's Tweaks, Terrain Helper, DynDOLOD resources/DLL and SKSE Menu
Framework for ISL Helper's UI. CS Terrain Helper and Terrain Blending feature
archives follow the core and come from its **same official release**. They
enable the existing Fantasia/Terrain Helper and complex-material setup.
[Terrain Helper](https://www.nexusmods.com/skyrimspecialedition/mods/143149),
[ISL Helper](https://www.nexusmods.com/skyrimspecialedition/mods/179132),
[SKSE Menu Framework](https://www.nexusmods.com/skyrimspecialedition/mods/120352).

The old ENBSeries, Cabbage, Silent Horizons Shader Core, ENB Extender, KiLoader,
EVLaS, ENB blending fix and Cabbage water patch packages are removed.
Existing ENB root components or Effects11 stop Prepare/Install before any
downloads or deployment; they are not deleted automatically. Water for ENB
remains at step 14 because it is explicitly in V2; choose its CS-compatible
options.

## Commands and configuration

Use Windows PowerShell 5.1 or later under the **same Windows account as Steam**.
Initialize the stock game's real INIs once before installing. Program Files
deployment may require elevating that same account.

```powershell
# Read-only; also the default mode.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Plan

# Downloads, CRC-tests, extracts and stages; does not change Skyrim.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Prepare -WorkPath 'D:\SkyrimModInstaller'

# Direct install, guided generators, then the Steam bridge.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Install -WorkPath 'D:\SkyrimModInstaller'

# Same work directory/config/account; reuse verified matching outputs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SkyrimMods.ps1 -Mode Install -WorkPath 'D:\SkyrimModInstaller' -Resume
```

The local `SkyrimMods.config.json` has been migrated to SchemaVersion 2 and V2's
hash. It stays untracked so personal archive paths and choices remain local.
The tracked `SkyrimMods.config.example.json` contains reviewed defaults; it is
used without creating files when the default local config is absent. An
explicit missing `-ConfigPath` is an error. To customize a fresh checkout:

```powershell
Copy-Item .\SkyrimMods.config.example.json .\SkyrimMods.config.json
```

Keep `RenderingFramework: "CommunityShaders"`, `LuxCsVariant: "Non-Effects11"`
and `Effects11: false`. Old SchemaVersion 1 configs must be migrated. The
runtime remains pinned; a Steam runtime update requires rechecking SKSE,
Address Library and every native DLL.

Each package can use `FileId`, `Sha256`, `LocalArchive`, `NamePattern`,
`DataRoot` or `ToolExecutable`. Plan displays all valid IDs. For supplied
archives with minimum-version checks, record the verified author version as
`PackageVersion` or `NativeVersion`. Local CS terrain features must declare
the same `PackageVersion` as the core. Example package fragment:

```json
{
  "Packages": {
    "community-shaders": {
      "LocalArchive": "D:\\Downloads\\CommunityShaders.zip",
      "PackageVersion": "1.9.1"
    },
    "lux-cs": {
      "LocalArchive": "D:\\Downloads\\Lux-CS.7z",
      "PackageVersion": "2.6.0"
    }
  },
  "FomodSelections": {
    "package-id/Exact step name/Exact group name": ["Exact option name"]
  }
}
```

This fragment is illustrative; merge it into the full config. `DataRoot`
bypasses FOMOD selection and must contain the complete reviewed chosen payload,
rather than a folder of alternatives. Native DLLs additionally require
`NativeCompatibility` with supported `Runtimes`, an authoritative HTTPS
`EvidenceUrl` and any minimum version/alpha. Unknown existing native DLLs
fail validation. ISL Helper's author says 1.0.6 supports the latest game
versions; its 1.7.104 entry is inferred from that release statement.
[ISL Helper changelog](https://www.nexusmods.com/skyrimspecialedition/mods/179132?tab=logs).

Keep WorkPath on a local SSD outside Skyrim, in a dedicated ordinary directory.
Default is `%LOCALAPPDATA%\SkyrimModInstaller`. The 160 GiB work/80 GiB game
checks are minimum headroom checks; archives, extraction, staging, Data and
generated outputs can coexist. Use the same WorkPath throughout. Staging from
earlier runs is retained.

## Downloads, asset choices and generators

Nexus Premium and a personal API key allow automatic Nexus downloads. The key
is prompted invisibly or read from process environment `NEXUS_API_KEY`; never
store it in JSON. Free accounts provide browser-downloaded archives.
`-ArchiveDirectory 'D:\Downloads\ReviewedMods'` accepts files named after
package IDs, such as `smim.7z`. Official GitHub releases provide CS terrain
features, portable 7-Zip, xLODGen and LOOT.
[Nexus API](https://api-docs.nexusmods.com/).

Script-managed downloads remain sequential, resumable and capped at
`curl --limit-rate 11250000` (90 Mbps). Browser downloads are outside this
cap. Archive SHA256/file IDs are locked; `-RefreshDownloads` deliberately
resolves updated versions and invalidates generation when inputs change.
FOMOD exact choices are saved in `fomod.choices.json`. Invalid/unavailable
choices, unsupported installer instructions and unsafe archive paths fail.
`-NonInteractive` requires all choices and reusable generation checkpoints.

The base overwrite order follows V2; plugin order uses inspected masters and
LOOT. QW's Pine Grass/Origins of Forest/Folkvangr prerequisites are included,
and Skoglendi follows QW as requested. This does not create a hybrid grass patch.
Cathedral expands to 13 plant releases plus the Hearthfire flower patch; Xavbio
expands to 22 armor/weapon families. Nordic Faces uses full textures/body and
full FaceTint, followed by Non-SMP FaceGeom. ERM uses its maintained successor's
mesh and texture downloads. Lux Via supplies **resources only**.

Generators run in the V2 sequence and deploy each validated output before the
next. PGPatcher uses CS-compatible complex material/parallax for the selected
assets; leave True PBR conversion off. Use terrain-only xLODGen, then TexGen,
then DynDOLOD. Fresh output folders, patched meshes/diff JSON, terrain assets,
TexGen DDS and DynDOLOD plugins/object meshes are checked. Review tool errors
and confirm successful completion. No dummy masters or automatic cleaning
are used to conceal failures.
[PGPatcher usage](https://github.com/hakasapl/PGPatcher/wiki/Basic-Usage),
[xLODGen](https://dyndolod.info/Help/xLODGen),
[TexGen](https://dyndolod.info/Help/TexGen),
[DynDOLOD](https://dyndolod.info/Help/DynDOLOD).

## Steam, failures and resume

Assets deploy directly into the real Data folder and Windows user's real
plugins/loadorder/INI files. After successful generation the installer
compiles the supplied C# source and manifest, backs up the stock launcher,
and applies this launch chain:

```text
Normal Steam Play / Remote Play
  → hidden SkyrimSELauncher.exe bridge
  → skse64_loader.exe -waitforclose
  → original SkyrimSE.exe
```

The bridge uses app ID 489830, waits through the game session, and requires a
V2/CommunityShaders receipt. It verifies the original game, matching SKSE,
native DLLs and required CS feature hashes, accepts safe relative Data paths,
and rejects ENB/Effects11 components. Keep Steam Launch Options empty/default.
Steam verification/updates can replace the launcher or runtime; review and
rerun afterward. The script does not change Steam update settings.
[Official SKSE wait-for-close option](https://github.com/ianpatt/skse64/blob/master/skse64_loader/Options.cpp).

Logs and structured failure reports are in WorkPath's timestamped Logs folder.
Failures return nonzero and identify phase, package and remedy. Resume replays
base assets, removes only individually owned prior generator files, and reuses
outputs only when input signatures and output hashes match. Signatures include
actual Data/shader settings, INIs, load order and launch binaries. Interrupted
installation marks a previous bridge pending so it refuses launch. Direct
overwrites are intentional; there is no full rollback system.

Offline regression checks are available with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Installer.V2.Tests.ps1
```

These tests use temporary folders and compile/validate the bridge without
running its entrypoint, Steam or Skyrim. Read-only Plan verifies the local
runtime/list/config. Full catalogue downloads, Prepare/Install, shader compilation
and Steam/Remote Play have not been exercised here. After installation, check
SKSE, SkyUI, CS/NAT.CS/Lux visuals, local Steam play, then Remote Play video,
controller input, session tracking and exit/relaunch. CS's first shader
compilation may take time. Launch logs go to
`%LOCALAPPDATA%\SkyrimModInstaller\LaunchLogs\steam-launch.log`.
