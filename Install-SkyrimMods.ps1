#requires -Version 5.1
<#
.SYNOPSIS
Downloads, stages, installs, and generates the V2 setup in Install order.txt.
.DESCRIPTION
Default mode is Plan (read-only). Prepare downloads and builds staged payloads.
Install deploys directly, runs LOOT and the four generators, and replaces
SkyrimSELauncher.exe with an invisible Steam -> SKSE bridge. SkyrimSE.exe stays
at its original name. No mod manager is needed to play. Generators and FOMOD
choices are interactive unless choices have been recorded. See the accompanying
README before using Install. V2 uses Community Shaders and Non-Effects11 Lux CS
on the existing Steam runtime. Never dot-source this script.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Prepare', 'Install')][string]$Mode = 'Plan',
    [string]$GamePath = '',
    [string]$ConfigPath = '',
    [string]$WorkPath = (Join-Path $env:LOCALAPPDATA 'SkyrimModInstaller'),
    [string]$ArchiveDirectory = '',
    [switch]$NonInteractive,
    [switch]$Resume,
    [switch]$RefreshDownloads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Resolve script-relative defaults after parameter binding on Windows PowerShell 5.1.
if ([string]::IsNullOrWhiteSpace($GamePath)) { $GamePath = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'SkyrimMods.config.json' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Phase = 'initialization'
$script:Package = ''
$script:LogPath = $null
$script:ExitCode = 1
$script:ApiKey = [Environment]::GetEnvironmentVariable('NEXUS_API_KEY', 'Process')
$script:Premium = $false
$script:NexusFiles = @{}
$script:NexusMods = @{}
$script:Lock = @{}
$script:Choices = @{}
$script:PlannedPlugins = @{}
$script:InstalledPlugins = @{}
$script:Generated = @{}
$script:Mutex = $null
$script:MutexOwned = $false

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function ConvertTo-Map($Object) {
    if ($null -eq $Object) { return @{} }
    $result = @{}
    foreach ($property in $Object.PSObject.Properties) { $result[$property.Name] = $property.Value }
    return $result
}

function Protect-Message([string]$Message) {
    if ($script:ApiKey) { $Message = $Message.Replace($script:ApiKey, '[API KEY REDACTED]') }
    # Signed CDN URLs and nxm download tokens must not appear in logs.
    return [regex]::Replace($Message, '(?i)(https?://[^\s?]+)\?[^\s]+', '$1?[REDACTED]')
}

function Write-Status([string]$Message, [ValidateSet('INFO','OK','WARN','FAIL')][string]$Level = 'INFO') {
    $safe = Protect-Message $Message
    $line = '{0:HH:mm:ss} [{1,-4}] {2}' -f (Get-Date), $Level, $safe
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $color
    if ($script:LogPath) {
        try { [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine) }
        catch { Write-Host ('Cannot append to log: '+$script:LogPath+'; '+$_.Exception.Message) -ForegroundColor Yellow }
    }
}

function Stop-Install([string]$Reason, [string]$Remedy, [int]$Code = 1) {
    $script:ExitCode = $Code
    $exception = New-Object InvalidOperationException($Reason)
    $exception.Data['Remedy'] = $Remedy
    throw $exception
}

function Set-Phase([string]$Name) {
    $script:Phase = $Name
    $script:Package = ''
    Write-Status $Name
}

function Get-FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }

function Assert-Within([string]$Path, [string]$Root, [switch]$AllowRoot) {
    $full = Get-FullPath $Path
    $base = Get-FullPath $Root
    if (($AllowRoot -and $full -eq $base) -or $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }
    Stop-Install "Path escapes its intended directory: $full" "Correct the path or archive. Expected a child of $base." 3
}

function Get-SafeChild([string]$Root, [string]$Relative, [switch]$AllowRoot) {
    if ([string]::IsNullOrEmpty($Relative)) {
        if ($AllowRoot) { return Get-FullPath $Root }
        Stop-Install 'An empty relative file path was supplied.' 'Supply an explicit file path, or a folder root only where permitted.' 3
    }
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match ':|(^|[\\/])\.\.([\\/]|$)') {
        Stop-Install "Unsafe relative path: $Relative" 'Use relative paths without drive names or parent traversal.' 3
    }
    return Assert-Within (Join-Path $Root $Relative) $Root -AllowRoot:$AllowRoot
}

function New-Directory([string]$Path) {
    Assert-OrdinaryDirectory $Path
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    return $Path
}

function Write-Json([string]$Path, $Object) {
    $temporary = $Path + '.writing'
    $json = ConvertTo-Json -InputObject $Object -Depth 40
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } else { [IO.File]::Move($temporary, $Path) }
}

function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Get-TextHash([string]$Text) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') }
    finally { $hasher.Dispose() }
}

function Get-ActiveInstallList([string]$Text) {
    $normalized=$Text.Replace("`r`n","`n").Replace("`r","`n")
    $headers=@([regex]::Matches($normalized,'(?im)^\s*V2\s+USE THIS ONE\s*$'))
    if ($headers.Count -ne 1) { Stop-Install 'Expected exactly one V2 USE THIS ONE section in Install order.txt.' 'Keep V1 as history and mark the active V2 section explicitly.' 3 }
    $body=$normalized.Substring($headers[0].Index+$headers[0].Length)
    $next=[regex]::Match($body,'(?im)^\s*V\d+\b')
    if ($next.Success) { $body=$body.Substring(0,$next.Index) }
    $entries=@([regex]::Matches($body,'(?m)^\s*(\d+)\.\s+(.+)$'))
    if ($entries.Count -ne 31) { Stop-Install 'V2 must contain the reviewed 31 numbered steps.' 'Review changes to V2 against the catalogue before changing its pinned hash.' 3 }
    for ($index=0; $index -lt $entries.Count; $index++) {
        if ([int]$entries[$index].Groups[1].Value -ne $index+1) { Stop-Install 'V2 steps are missing, repeated or out of order.' 'Number the reviewed V2 list consecutively from 1 through 31.' 3 }
    }
    return [pscustomobject]@{Version='V2';Text=$body.Trim();Entries=$entries}
}

function Read-Choice([string]$Prompt, [string]$Default = '') {
    if ($NonInteractive) { Stop-Install "An interactive choice is required: $Prompt" 'Run interactively once, or record the exact choice in the configuration/choices file.' 4 }
    $answer = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().Trim('"')
}

function New-Package([double]$Order, [string]$Id, [string]$Name, [int]$ModId,
    [string]$Pattern = '', [string]$Kind = 'Data', [string]$Hint = '', [string[]]$Provides = @()) {
    return [pscustomobject]@{
        Order=$Order; Id=$Id; Name=$Name; ModId=$ModId; Pattern=$Pattern; Kind=$Kind
        Hint=$Hint; Provides=$Provides; Repo=''; AssetPattern=''; Native=$false; MinimumVersion=''
    }
}

function Get-Catalogue {
    $packages = New-Object 'Collections.Generic.List[object]'
    # Dependencies are before their consumers. Numbered items keep the requested overwrite order.
    $packages.Add((New-Package -10 'skse' 'SKSE64 (matched to Steam runtime)' 30379 '.*' 'Skse'))
    $packages.Add((New-Package -9 'address-library' 'Address Library All in One' 32444 'All.in.One' 'Data'))
    $packages.Add((New-Package -4.5 'po3-tweaks' "powerofthree's Tweaks (Terrain Helper prerequisite)" 51073 'powerofthree.*Tweaks' 'Data'))
    $packages.Add((New-Package -4 'terrain-helper' 'Terrain Helper (Fantasia prerequisite)' 143149 'Terrain Helper' 'Data'))
    $packages.Add((New-Package -3 'dyndolod-resources' 'DynDOLOD Resources SE 3' 52897 'DynDOLOD Resources SE' 'Data'))
    $packages.Add((New-Package -2 'dyndolod-dll' 'DynDOLOD DLL NG and Scripts' 97720 'DynDOLOD.*(DLL|Scripts)' 'Data'))
    $x=New-Package -1 'skse-menu-framework' 'SKSE Menu Framework (ISL Helper UI)' 120352 '^SKSE Menu Framework$'
    $x.MinimumVersion='3.14.1'; $packages.Add($x)
    $packages.Add((New-Package 1 'smim' 'SMIM' 659 'SMIM.*(SE|Special|2)' 'Data' 'Install everything / highest quality' @('SMIM-SE-Merged-All.esp')))
    $packages.Add((New-Package 2 'mic' 'Mesh Improvement Compilation' 131131 '^Mesh Improvement Compilation$'))
    $packages.Add((New-Package 3 'skyland' 'Skyland AIO 2K' 34179 '^Skyland AIO(?: 2k)?$' 'Data' '2K; vanilla water (Water for ENB supplies water); default architecture'))
    $packages.Add((New-Package 4 'skyrim-202x' 'Skyrim 202X Downscale 4K' 68307 'Skyrim 202X.*4K' 'Data' '4K main textures; do not select lower-resolution variants'))
    $packages.Add((New-Package 5 'fantasia' 'Skyking Fantasia Landscapes 4K' 107256 '^Skyking Fantasia Landscapes 4k$' 'Data' '4K; green tundra (match the subsequent parallax file)'))
    $packages.Add((New-Package 6 'fantasia-parallax' 'Fantasia Complex Parallax (green tundra)' 107256 '^Fantasia Landscapes Complex Parallax Green Tundra$'))
    # The original ERM page is hidden. Its maintained successor supplies the meshes and textures separately.
    $packages.Add((New-Package 7 'erm' 'ERM maintained meshes' 121336 '^ERM - Enhanced Rocks and Mountains$' 'Data' 'Complex material/parallax for Community Shaders; ERM blending; retain the V2 texture choices'))
    $packages.Add((New-Package 7.1 'erm-textures' 'ERM full-resolution textures' 121336 '^ERM - Textures$' 'Data' 'Complex Material / Complex Parallax; 4K where offered'))
    $packages.Add((New-Package 8 'erm-fixes' 'ERM Blending Patch and Other Fixes' 131170 'Patch and Fixes.*FOMOD' 'Data' 'ERM complex parallax; Fantasia/Terrain Helper compatible option; Simplicity of Snow patch'))
    $packages.Add((New-Package 9 'snow' 'Simplicity of Snow' 56235 '^Simplicity of Snow$' 'Data' 'Parallax support; default assets' @('Simplicity of Snow.esp')))
    $packages.Add((New-Package 9.1 'pine-grass' 'Cathedral 3D Pine Grass (QW master)' 42032 'Full 3D Coverage' 'Data' '' @('Cathedral - 3D Pine Grass.esp')))
    $packages.Add((New-Package 9.2 'origins-forest' 'Origins of Forest (QW master)' 45719 '^Origins Of Forest.*' 'Data' 'Default full-resolution package' @('Origins Of Forest - 3D Forest Grass.esp')))
    $packages.Add((New-Package 9.3 'folkvangr' 'Folkvangr (QW master)' 44899 '^Folkvangr.*' 'Data' '' @('Folkvangr - Grass and Landscape Overhaul.esp')))
    $packages.Add((New-Package 10 'qw-grass' "QW's Grass Patch 2" 67785 "QW.*Grass Patch 2" 'Data' 'Default full package' @("QW's Grass Patch 2.esp")))
    $packages.Add((New-Package 11 'skoglendi' 'Skoglendi' 93944 '^Skoglendi' 'Data' 'Highest quality/default; wins grass records after QW unless a dedicated combination patch is added' @('Skoglendi - A Grass Mod.esp')))
    $packages.Add((New-Package 12 'wildlands' 'Nature of the Wild Lands' 63604 '^Nature of the Wild Lands$' 'Data' 'Default full forest package' @('Nature of the Wild Lands.esp')))
    $packages.Add((New-Package 12.1 'wildlands-4k' 'Nature of the Wild Lands 4K bark options' 63604 '^NotWL - textures options$' 'Data' 'Select BOTH 4K bark diffuse and 4K bark normal maps'))
    $plants = @(
        @(41312,'Mountain Flowers'), @(69415,'Snow Berries'), @(68793,'Clover Plant'),
        @(68310,'Lavender'), @(68068,'Tundra Cotton'), @(67619,'Thistle'), @(76460,'Deathbell'),
        @(81284,'Nightshade'), @(82978,'Sword Ferns'), @(85694,'Dragons Tongue'),
        @(86392,'Thicket and Dead Shrub'), @(110726,'Stonecrop'), @(108747,'Tundra Shrubs')
    )
    $index = 0
    foreach ($plant in $plants) {
        $index++
        $packages.Add((New-Package (13 + $index/1000) ('cathedral-' + $plant[0]) ('Cathedral 3D ' + $plant[1]) $plant[0] '' 'Data' 'Highest official resolution (4K when offered); default color/mesh; no optional unrelated-mod patches'))
    }
    $packages.Add((New-Package 13.9 'cathedral-hearthfire' 'Cathedral Mountain Flowers Hearthfire Patch' 41312 'Hearthfire Patch'))
    $packages.Add((New-Package 14 'water' 'Water for ENB (Community Shaders options)' 37061 '^Water for ENB$' 'Data' '4K/highest textures; select Community Shaders-compatible options; default water style' @('Water for ENB.esm')))
    $armors = @(
        @(84151,'Daedric'), @(83654,'Ebony'), @(87283,'Elven'), @(91136,'Ancient Nord'),
        @(83222,'Dragon'), @(101101,'Dragon Priests'), @(87580,'Glass'), @(98115,'Guards and Stormcloaks'),
        @(86097,'Imperial'), @(84978,'Iron'), @(90153,'Leather'), @(84607,'Orcish'),
        @(151116,'Saints and Seducers'), @(89109,'Silver'), @(96204,'Stalhrim'), @(85445,'Steel'),
        @(105771,'Unique'), @(169281,'Faction'), @(111518,'Spell Knight'), @(120097,'Vigil Enforcer'),
        @(94529,'Chitin'), @(93088,'Dwemer')
    )
    $index = 0
    foreach ($armor in $armors) {
        $index++
        $packages.Add((New-Package (15 + $index/1000) ('xavbio-' + $armor[0]) ('Xavbio ' + $armor[1] + ' retextures') $armor[0] '' 'Data' 'Full resolution; vanilla body meshes; only installed CC content and applicable consistency patches'))
    }
    $packages.Add((New-Package 16 'nordic-body' 'Nordic Faces textures and body meshes' 40658 '^Nordic Faces - Textures and Body Meshes$' 'Data' 'Install all textures and body meshes'))
    $packages.Add((New-Package 16.1 'nordic-tint' 'Nordic Faces full-resolution face tints' 40658 '^Nordic Faces - FaceGen - Loose Files$' 'Data' 'Install FaceTint only; Non-SMP FaceGeom follows'))
    $packages.Add((New-Package 16.2 'nordic-facegen' 'Nordic Faces Non-SMP FaceGeom' 40658 '^Nordic Faces - FaceGen - Non-SMP$'))
    $packages.Add((New-Package 17 'skyui' 'SkyUI 6' 12604 '^SkyUI$' 'Data' '' @('SkyUI_SE.esp')))
    $packages.Add((New-Package 18 'dear-diary' 'Dear Diary Dark Mode' 60837 'texts - warm color' 'Data' 'Controller-friendly settings; default warm text; SkyUI-compatible menus'))
    $packages.Add((New-Package 19 'nat' 'NAT.ENB III weather ESP ONLY - 3.1.1C Fixed' 27141 '^NAT\.ENB - ESP WEATHER PLUGIN v3\.1\.1C - Fixed$' 'Data' 'Weather ESP only; NAT.CS III overwrites it at step 22' @('NAT-ENB.esp')))
    $x=New-Package 20 'community-shaders' 'Community Shaders official core' 86492 '^Community Shaders$' 'Data' 'Official core release; Cloud Shadows and ISL are bundled; do not use the Effects11/AIO archive'
    $x.MinimumVersion='1.9.1'; $packages.Add($x)
    $packages.Add((New-Package 20.1 'cs-terrain-helper' 'Community Shaders Terrain Helper feature' 0 '' 'Data' 'Enable the CS adapter for the existing Fantasia/Terrain Helper setup'))
    $packages.Add((New-Package 20.2 'cs-terrain-blending' 'Community Shaders Terrain Blending feature' 0 '' 'Data' 'Terrain-to-mesh blending for the V2 complex-material assets'))
    $x=New-Package 21 'skylighting' 'Skylighting - Community Shaders' 139352 '^Skylighting(?: - Community Shaders)?$'
    $x.MinimumVersion='1.5.2'; $packages.Add($x)
    $packages.Add((New-Package 22 'nat-cs' 'NAT.CS III' 139567 '^NAT\.CS(?: III)?$' 'Data' 'Install after and overwrite the NAT weather ESP; omit optional water-effect shadows requiring an extra fix'))
    $x=New-Package 23 'light-placer' 'Light Placer' 127557 '^Light Placer$'
    $x.MinimumVersion='5.0.0'; $packages.Add($x)
    $x=New-Package 24 'isl-helper' 'ISL Helper SKSE' 179132 '^ISL Helper(?: SKSE)?$'
    $x.MinimumVersion='1.0.6'; $packages.Add($x)
    $packages.Add((New-Package 24.9 'lux-resources' 'Lux Via resources only' 63588 'Resources' 'Data' 'Resources only; no Lux Via worldspace overhaul'))
    $packages.Add((New-Package 25 'lux-orbis' 'Lux Orbis' 56095 '^Lux Orbis$' 'Data' 'Community Shaders-compatible choices; retain Lux-prefixed meshes' @('Lux Orbis - Master plugin.esm','Lux Orbis.esp')))
    $packages.Add((New-Package 25.1 'lux-orbis-patches' 'Lux Orbis official patch hub' 114169 '^Lux Orbis - Patch Hub$' 'Data' 'Only patches whose masters are in this setup'))
    $packages.Add((New-Package 26 'lux' 'Lux' 43158 '^Lux \(main\)$' 'Data' 'Highest-quality meshes; Community Shaders/Light Limit Fix choices; Lux CS follows' @('Lux - Master plugin.esm','Lux.esp')))
    $packages.Add((New-Package 26.1 'lux-update' 'Lux main plugin update' 43158 'main plugin update'))
    $packages.Add((New-Package 26.2 'lux-patches' 'Lux official patch hub' 113002 'patch hub' 'Data' 'Only patches whose masters are in this setup'))
    $x=New-Package 27 'lux-cs' 'Lux CS - Non-Effects11' 153919 '^Lux[. ]CS(?: Patch)?$' 'Data' 'Non-Effects11 variant; Light Placer/ISL; Lux Orbis tweaks; install after all Lux/Orbis patches'
    $x.MinimumVersion='2.6.0'; $packages.Add($x)
    $packages.Add((New-Package 28 'pgpatcher' 'PGPatcher / ParallaxGen' 120946 '^PGPatcher' 'Tool'))
    $x = New-Package 29 'xlodgen' 'xLODGen' 0 '' 'Tool'
    $x.Repo = 'sheson/xLODGen'; $x.AssetPattern = '^xLODGen.*\.7z$'; $packages.Add($x)
    $packages.Add((New-Package 30 'dyndolod-tools' 'DynDOLOD 3 tools (TexGen step 30, DynDOLOD step 31)' 68518 '^DynDOLOD' 'Tool'))
    $x = New-Package 32 'loot' 'LOOT portable' 0 '' 'Tool'
    $x.Repo = 'loot/loot'; $x.AssetPattern = '^loot_.*-win64\.7z$'; $packages.Add($x)
    foreach ($package in $packages) {
        if ($package.Id -in @('po3-tweaks','terrain-helper','dyndolod-dll','community-shaders','light-placer','isl-helper','skse-menu-framework')) { $package.Native = $true }
        if ($package.Id -in @('cs-terrain-helper','cs-terrain-blending')) {
            $package.Repo='community-shaders/skyrim-community-shaders'
            $package.AssetPattern=if ($package.Id -eq 'cs-terrain-helper') { '^Terrain\.Helper-.*\.zip$' } else { '^Terrain\.Blending-.*\.zip$' }
        }
    }
    return @($packages | Sort-Object Order)
}

function Invoke-WebJson([string]$Uri, [hashtable]$Headers = @{}) {
    for ($attempt=1; $attempt -le 4; $attempt++) {
        Write-Status ('Requesting metadata from {0} (attempt {1}/4; timeout 45s)' -f ([uri]$Uri).Host,$attempt)
        try { return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -TimeoutSec 45 }
        catch {
            $status = 0
            $response=Get-Value $_.Exception 'Response' $null
            if ($null -ne $response) { $status = [int]$response.StatusCode }
            if ($status -in @(400,401,403,404) -or $attempt -eq 4) {
                Stop-Install "Metadata request failed (HTTP $status): $($_.Exception.Message)" 'Check authentication, file availability, network access and the package source. 401 means invalid API key; 403 can mean a download requires Nexus Premium.' 2
            }
            Write-Status "Metadata retry $attempt/4 (HTTP $status)" 'WARN'
            Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2,$attempt)))
        }
    }
}

function Get-Nexus([string]$Relative) {
    if (-not $script:ApiKey) { Stop-Install 'Nexus metadata requires an API key.' 'Set NEXUS_API_KEY or NexusApiKey in the local, ignored SkyrimMods.config.json, or provide LocalArchive mappings for every Nexus package.' 2 }
    return Invoke-WebJson ('https://api.nexusmods.com/v1/' + $Relative) @{
        apikey=$script:ApiKey; 'User-Agent'='SkyrimModInstaller/1.0'; Accept='application/json'
    }
}

function Initialize-Nexus {
    if (-not $script:ApiKey) { $script:ApiKey=[string](Get-Value $script:Config 'NexusApiKey' '') }
    if (-not $script:ApiKey -and -not $NonInteractive) {
        $secure = Read-Host 'Nexus personal API key (hidden; Enter for supplied archives only)' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    if ($script:ApiKey) {
        $script:ApiKey=$script:ApiKey.Trim()
        if ($script:ApiKey -match '[\x00-\x1f\x7f]' -or $script:ApiKey -match '^\*+$') {
            Stop-Install 'The supplied Nexus key contains control characters or copied masking characters.' 'Copy the actual personal API key into the local config or terminal. Do not copy the displayed asterisks.' 2
        }
        $user = Get-Nexus 'users/validate.json'
        $script:Premium = [bool](Get-Value $user 'is_premium' $false)
        Write-Status ('Nexus authentication accepted; automatic downloads: ' + $script:Premium) 'OK'
        if (-not $script:Premium) { Write-Status 'Nexus free account: each Nexus archive needs a browser download; the installer will prompt for its downloaded file path.' 'WARN' }
    }
}

function Get-PackageOverride($Package) { return Get-Value (Get-Value $script:Config 'Packages') $Package.Id @{} }

function Select-NexusFile($Package) {
    $override = Get-PackageOverride $Package
    $pinned = [int](Get-Value $override 'FileId' 0)
    if ($script:Lock.ContainsKey($Package.Id) -and -not $RefreshDownloads) {
        $lockedId=[int](Get-Value $script:Lock[$Package.Id] 'FileId' 0)
        if ($pinned -and $lockedId -and $pinned -ne $lockedId) { Stop-Install "Configured FileId conflicts with the locked file for $($Package.Id)." 'Use -RefreshDownloads only if you deliberately intend to update the locked package versions.' 2 }
        if ($lockedId) { $pinned=$lockedId }
    }
    if (-not $script:NexusFiles.ContainsKey($Package.ModId)) {
        $reply = Get-Nexus ('games/skyrimspecialedition/mods/{0}/files.json' -f $Package.ModId)
        $script:NexusFiles[$Package.ModId] = @(Get-Value $reply 'files' @())
    }
    $files = $script:NexusFiles[$Package.ModId]
    if ($pinned) {
        $matches = @($files | Where-Object { [int]$_.file_id -eq $pinned })
    } else {
        $pattern = [string](Get-Value $override 'NamePattern' $Package.Pattern)
        $matches = @($files | Where-Object {
            [int]$_.category_id -in @(1,2,3,4,6) -and
            ($pattern -eq '' -or $_.name -match $pattern) -and
            $_.name -notmatch '(?i)\b(half[- ]?(res|resolution)|low[- ]?(res|resolution)|1k|2k|performance|bodyslide|translation|VR)\b'
        })
        # Intentional exceptions: Skyland is 2K; Native libraries mention supported VR alongside SE.
        if ($Package.Id -eq 'skyland' -or $Package.Native -or $Package.Id -eq 'address-library') {
            $matches = @($files | Where-Object { [int]$_.category_id -in @(1,2,3,4,6) -and $_.name -match $pattern })
        }
        if ($Package.Id -eq 'skse') {
            $runtimePattern = [regex]::Escape($script:Runtime.ToString(3))
            $matches = @($files | Where-Object {
                [int]$_.category_id -in @(1,2,3) -and
                (($_.name + ' ' + (Get-Value $_ 'description' '')) -match $runtimePattern) -and
                $_.name -notmatch '(?i)GOG|VR'
            })
        }
        # Keep only the latest version for duplicate names, never install all alternatives.
        $matches = @($matches | Group-Object name | ForEach-Object {
            $_.Group | Sort-Object uploaded_timestamp -Descending | Select-Object -First 1
        })
        if ($Package.Id -like 'xavbio-*') {
            $matches = @($matches | Where-Object { $_.name -notmatch '(?i)patch|addon|fix|optional|resource' -and [int]$_.category_id -eq 1 })
        }
        if ($Package.Id -like 'cathedral-*' -and $Package.Id -ne 'cathedral-hearthfire') {
            $fourK = @($matches | Where-Object { $_.name -match '(?i)4k' })
            if ($fourK.Count) { $matches = $fourK }
            else { $matches = @($matches | Where-Object { [int]$_.category_id -eq 1 -and $_.name -notmatch '(?i)resource' }) }
        }
    }
    if ($matches.Count -eq 0) {
        Write-Status ("No automatic file match; source: https://www.nexusmods.com/skyrimspecialedition/mods/{0}?tab=files" -f $Package.ModId) 'WARN'
        $files | Where-Object { [int]$_.category_id -in @(1,2,3,4,6) } | ForEach-Object { Write-Host ('  FileId {0}: {1} ({2})' -f $_.file_id,$_.name,$_.version) }
        $chosen = Read-Choice ('Exact FileId for ' + $Package.Name)
        $matches = @($files | Where-Object { [string]$_.file_id -eq $chosen })
    } elseif ($matches.Count -gt 1) {
        Write-Status ('Choose one archive for ' + $Package.Name + '; ' + $Package.Hint)
        for ($i=0; $i -lt $matches.Count; $i++) { Write-Host ('  {0}. {1} [{2}]' -f ($i+1),$matches[$i].name,$matches[$i].version) }
        $chosen = Read-Choice 'Archive number'
        $number = 0
        if (-not [int]::TryParse($chosen,[ref]$number) -or $number -lt 1 -or $number -gt $matches.Count) {
            Stop-Install "Invalid archive selection: $chosen" 'Choose one of the displayed numbered archives or pin FileId in configuration.' 2
        }
        $matches = @($matches[$number-1])
    }
    if ($matches.Count -ne 1) { Stop-Install 'A unique Nexus archive was not selected.' 'Set the correct FileId in configuration.' 2 }
    return $matches[0]
}

function Save-Download([string]$Uri, [string]$Destination, [string]$Sha256 = '') {
    if (Test-Path -LiteralPath $Destination) {
        if ($Sha256 -and (Get-Hash $Destination) -ne $Sha256) { Stop-Install "Cached archive checksum mismatch: $Destination" 'Remove only that cached archive and download it again.' 2 }
        Write-Status ('Using downloaded file: '+$Destination) 'OK'
        return $Destination
    }
    if ([uri]$Uri -and ([uri]$Uri).Scheme -ne 'https') {
        Stop-Install 'A download does not use HTTPS.' 'Supply the official archive using LocalArchive, or use the author HTTPS download URL.' 2
    }
    # curl.exe is shipped with current Windows. HTTP error bodies are rejected by --fail.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { Stop-Install 'Windows curl.exe is unavailable.' 'Install a current Windows curl build or supply already downloaded archives.' 2 }
    $partial = $Destination + '.partial'
    Write-Status ('Downloading '+[IO.Path]::GetFileName($Destination)+'; cap 11.25 MB/s (90 Mbps)')
    Write-Status ('Destination: '+$Destination)
    for ($attempt=1; $attempt -le 4; $attempt++) {
        $resumeBytes=if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0L }
        Write-Status ('Download attempt {0}/4; {1:N1} MiB already on disk; stalls time out after 120s below 1 KiB/s' -f $attempt,($resumeBytes/1MB))
        $errorLog=Join-Path $script:RunLogPath ('download-'+[guid]::NewGuid().ToString('N')+'.log')
        $arguments='--fail --location --proto =https --proto-redir =https --silent --show-error --connect-timeout 30 --speed-time 120 --speed-limit 1024 --limit-rate 11250000 --output "'+$partial+'" --continue-at - "'+$Uri+'"'
        # Do not log command arguments: the URL may have a signed Nexus token.
        $code=Invoke-Process $curl.Source $arguments ('Downloading '+[IO.Path]::GetFileName($Destination)) $script:WorkRoot -WatchFile $partial -ErrorLog $errorLog
        $errors=if (Test-Path -LiteralPath $errorLog) { Protect-Message ([IO.File]::ReadAllText($errorLog)) } else { '' }
        if (Test-Path -LiteralPath $errorLog) { [IO.File]::WriteAllText($errorLog,[string]$errors) }
        if ($code -eq 0) { break }
        if ($code -eq 33 -or $code -eq 36) {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
        if ($attempt -eq 4) { Stop-Install ("Download failed; curl exit {0}: {1}" -f $code,($errors -join ' ')) 'Check the network and download access. An expired Nexus link can be refreshed by rerunning. Partial downloads remain resumable.' 2 }
        $delay=[Math]::Pow(2,$attempt)
        $summary=if ([string]::IsNullOrWhiteSpace([string]$errors)) { 'No error text was returned.' } else { ([string]$errors -replace '\s+',' ').Trim() }
        if ($summary.Length -gt 400) { $summary=$summary.Substring(0,400)+'...' }
        Write-Status "Download attempt $attempt/4 failed; curl exit ${code}: $summary Retry in ${delay}s. Details: $errorLog" 'WARN'
        Start-Sleep -Seconds $delay
    }
    if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -lt 16) {
        Stop-Install 'Downloaded file is empty or too small to be an archive.' 'Check the actual download URL and account permissions.' 2
    }
    if ($Sha256 -and (Get-Hash $partial) -ne $Sha256) { Stop-Install 'Downloaded archive failed SHA256 verification.' 'Delete only the .partial file and retry; verify the expected author checksum.' 2 }
    Move-Item -LiteralPath $partial -Destination $Destination
    Write-Status ('Downloaded {0}: {1:N1} MiB' -f [IO.Path]::GetFileName($Destination),((Get-Item -LiteralPath $Destination).Length/1MB)) 'OK'
    return $Destination
}

function Get-GitHubAsset([string]$Repository, [string]$Pattern, [string]$Tag = '') {
    $endpoint=if ($Tag) { 'tags/'+[uri]::EscapeDataString($Tag) } else { 'latest' }
    $release = Invoke-WebJson ('https://api.github.com/repos/{0}/releases/{1}' -f $Repository,$endpoint) @{'User-Agent'='SkyrimModInstaller/2.0'}
    $assets = @(Get-Value $release 'assets' @() | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { Stop-Install "No unique official GitHub asset matching $Pattern in $Repository." 'Supply LocalArchive or update AssetPattern for the current official release.' 2 }
    $assets[0] | Add-Member -NotePropertyName ReleaseVersion -NotePropertyValue ([string]$release.tag_name).TrimStart('v') -Force
    return $assets[0]
}

function Get-Archive($Package) {
    $override = Get-PackageOverride $Package
    $local = [string](Get-Value $override 'LocalArchive' '')
    if (-not $local -and -not $ArchiveDirectory -and -not $RefreshDownloads -and $script:Lock.ContainsKey($Package.Id)) {
        $previous=$script:Lock[$Package.Id]
        $configuredId=[int](Get-Value $override 'FileId' 0)
        $lockedId=[int](Get-Value $previous 'FileId' 0)
        if ($configuredId -and $lockedId -and $configuredId -ne $lockedId) { Stop-Install "Configured FileId differs from locked archive for $($Package.Id)." 'Use -RefreshDownloads only after intentionally choosing updated versions.' 2 }
        $cached=[string](Get-Value $previous 'Archive' '')
        if ($cached -and (Test-Path -LiteralPath $cached -PathType Leaf)) {
            $hash=Get-Hash $cached
            if ($hash -ne [string](Get-Value $previous 'Sha256' '')) { Stop-Install "Locked archive checksum mismatch: $cached" 'Remove only the corrupt archive and redownload the locked file; do not bypass the checksum.' 2 }
            $expected=[string](Get-Value $override 'Sha256' '')
            if ($expected -and $hash -ne $expected) { Stop-Install 'Configured archive checksum differs from the locked file.' 'Check the intended file/version and author hash before refreshing.' 2 }
            return $previous
        }
    }
    if (-not $local -and $ArchiveDirectory) {
        $candidates = @(Get-ChildItem -LiteralPath $ArchiveDirectory -File | Where-Object { $_.BaseName -eq $Package.Id })
        if ($candidates.Count -eq 1) { $local = $candidates[0].FullName }
    }
    $record = [ordered]@{ ModId=$Package.ModId; FileId=0; Name=$Package.Name; Version='manual'; Sha256=''; Archive=''; Source=''; Manual=$false }
    if ($local) {
        $local = Get-FullPath $local
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { Stop-Install "Supplied archive not found: $local" 'Correct LocalArchive or the archive directory.' 2 }
        $record.Archive=$local; $record.Source='local'; $record.Manual=$true
    } elseif ($Package.ModId) {
        $file = Select-NexusFile $Package
        $record.FileId=[int]$file.file_id; $record.Name=$file.name; $record.Version=$file.version
        $record.Source='https://www.nexusmods.com/skyrimspecialedition/mods/' + $Package.ModId
        $extension = [IO.Path]::GetExtension([string]$file.file_name)
        $destination = Join-Path $script:DownloadPath ($Package.Id + '-' + $file.file_id + $extension)
        if (-not (Test-Path -LiteralPath $destination)) {
            if ($script:Premium) {
                $links = @(Get-Nexus ('games/skyrimspecialedition/mods/{0}/files/{1}/download_link.json' -f $Package.ModId,$file.file_id))
                if (-not $links.Count) { Stop-Install 'Nexus returned no download mirrors.' 'Check if the file is still available and your Premium account is active.' 2 }
                $record.Archive=Save-Download $links[0].URI $destination ([string](Get-Value $override 'Sha256' ''))
            } else {
                Write-Status ('Manual Nexus download required: ' + $record.Source + '?tab=files&file_id=' + $file.file_id) 'WARN'
                $supplied = Read-Choice ('Path to downloaded archive: ' + $file.name)
                if (-not (Test-Path -LiteralPath $supplied -PathType Leaf)) { Stop-Install "Archive not found: $supplied" 'Download this exact file through Nexus, then enter its complete local path.' 2 }
                Copy-Item -LiteralPath $supplied -Destination $destination
                $record.Archive=$destination
            }
        } else { $record.Archive=$destination }
    } elseif ($Package.Repo) {
        $tag=''
        if ($Package.Id -like 'cs-terrain-*') {
            $core=@($script:Payloads | Where-Object { $_.Package.Id -eq 'community-shaders' })
            if ($core.Count -ne 1) { Stop-Install 'Community Shaders must be staged before its terrain features.' 'Preserve the V2 dependency order.' 4 }
            $tag='v'+(Get-PackageVersion $core[0].Package $core[0].Record).ToString(3)
        }
        $asset = Get-GitHubAsset $Package.Repo $Package.AssetPattern $tag
        $record.Version=$asset.ReleaseVersion
        $record.Archive=Save-Download $asset.browser_download_url (Join-Path $script:DownloadPath $asset.name) ([string](Get-Value $override 'Sha256' ''))
        $record.Source='https://github.com/' + $Package.Repo + '/releases/tag/v' + $record.Version
    } else {
        Stop-Install "No official archive source for $($Package.Id)." 'Supply a reviewed LocalArchive or correct the package catalogue.' 2
    }
    $record.Sha256=Get-Hash $record.Archive
    $expected = [string](Get-Value $override 'Sha256' '')
    if ($expected -and $record.Sha256 -ne $expected) { Stop-Install "Checksum mismatch for $($Package.Name)." 'Verify the supplied archive and expected SHA256 in configuration.' 2 }
    if ($script:Lock.ContainsKey($Package.Id) -and -not $RefreshDownloads) {
        $previousHash = [string](Get-Value $script:Lock[$Package.Id] 'Sha256' '')
        if ($previousHash -and $previousHash -ne $record.Sha256) { Stop-Install "Archive changed since it was locked: $($Package.Id)" 'Use the previously locked archive, or deliberately start a fresh preparation with -RefreshDownloads.' 2 }
    }
    $script:Lock[$Package.Id]=$record
    Write-Json $script:LockPath $script:Lock
    return [pscustomobject]$record
}

function Initialize-Extractor {
    $custom = [string](Get-Value $script:Config 'SevenZipPath' '')
    $candidates=@($custom, (Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path $script:ToolPath '7zip\x64\7za.exe'))
    foreach ($candidate in $candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { $script:SevenZip=$candidate; return } }
    Write-Status 'Downloading the official portable 7-Zip extractor'
    $bootstrap=New-Directory (Join-Path $script:ToolPath '7zip')
    $small=Get-GitHubAsset 'ip7z/7zip' '^7zr\.exe$'
    $extra=Get-GitHubAsset 'ip7z/7zip' '^7z\d+-extra\.7z$'
    $smallPath=Save-Download $small.browser_download_url (Join-Path $bootstrap '7zr.exe')
    $extraPath=Save-Download $extra.browser_download_url (Join-Path $script:DownloadPath $extra.name)
    & $smallPath x $extraPath ('-o' + $bootstrap) -y -bso0 -bsp0 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Install '7-Zip bootstrap extraction failed.' 'Install 7-Zip and set SevenZipPath in configuration.' 3 }
    $script:SevenZip=Join-Path $bootstrap 'x64\7za.exe'
    if (-not (Test-Path -LiteralPath $script:SevenZip)) { Stop-Install 'Portable 7-Zip binary was not found after extraction.' 'Install 7-Zip and configure SevenZipPath.' 3 }
}

function Expand-ArchiveChecked($Record, [string]$Id) {
    $root=New-Directory (Join-Path $script:ExtractPath ($Id + '-' + $Record.Sha256.Substring(0,16)))
    $marker=Join-Path $root '.extraction-complete.json'
    if (Test-Path -LiteralPath $marker) {
        $complete=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($complete.Sha256 -eq $Record.Sha256) { Assert-NoChildLinks $root; return $root }
    }
    $listing=@(& $script:SevenZip l -slt -ba $Record.Archive 2>&1)
    if ($LASTEXITCODE -ne 0) { Stop-Install "Archive cannot be read: $($Record.Archive)" 'The file may be an HTML login/error page or a corrupt archive. Redownload the exact file.' 3 }
    foreach ($line in $listing) {
        if ([string]$line -match '^Path = (.+)$') { Get-SafeChild $root $Matches[1] | Out-Null }
        if ([string]$line -match '^(Symbolic Link|Hard Link) = ' -or [string]$line -match '^Attributes = .*\bL\b') {
            Stop-Install 'Archive contains links.' 'Use an author archive without symlinks/hardlinks; links can escape the extraction directory.' 3
        }
    }
    $testLog=Join-Path $script:RunLogPath ($Id + '-archive-test.log')
    $code=Invoke-Process $script:SevenZip ('t "'+$Record.Archive+'" -bsp0') ('CRC test '+$Id) $script:WorkRoot -OutputLog $testLog -ErrorLog ($testLog+'.errors')
    if ($code -ne 0) { Stop-Install "Archive CRC test failed: $($Record.Archive); exit $code" "Download it again. Details: $testLog" 3 }
    $extractLog=Join-Path $script:RunLogPath ($Id + '-extract.log')
    $code=Invoke-Process $script:SevenZip ('x "'+$Record.Archive+'" -o"'+$root+'" -y -bsp0') ('Extract '+$Id) $script:WorkRoot -OutputLog $extractLog -ErrorLog ($extractLog+'.errors')
    if ($code -ne 0) { Stop-Install "Archive extraction failed: $($Record.Archive); exit $code" "Check space, antivirus and path length. Details: $extractLog" 3 }
    $links=@(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { Stop-Install 'Extracted archive contains reparse points.' 'Replace the archive with an ordinary file archive.' 3 }
    Write-Json $marker @{Sha256=$Record.Sha256}
    return $root
}

function Invoke-Process([string]$Executable, [string]$Arguments, [string]$Label,
    [string]$Directory, [switch]$Visible, [string]$WatchFile = '', [string]$OutputLog = '', [string]$ErrorLog = '') {
    $parameters=@{FilePath=$Executable; ArgumentList=$Arguments; WorkingDirectory=$Directory; PassThru=$true}
    if ($OutputLog) { $parameters.RedirectStandardOutput=$OutputLog }
    if ($ErrorLog) { $parameters.RedirectStandardError=$ErrorLog }
    if ($Visible) { $parameters.WindowStyle='Normal' } else { $parameters.WindowStyle='Hidden' }
    $process=Start-Process @parameters
    try {
        # PowerShell 5.1 can otherwise return a null ExitCode for redirected children.
        # Keep the native handle alive before waiting for the process to exit.
        $null=$process.Handle
        $started=[DateTime]::UtcNow; $last=$started
        $lastBytes=if ($WatchFile -and (Test-Path -LiteralPath $WatchFile)) { (Get-Item -LiteralPath $WatchFile).Length } else { 0L }
        $lastGrowth=$started
        $interval=if ($WatchFile) { 5 } else { 30 }
        while (-not $process.WaitForExit(1000)) {
            $now=[DateTime]::UtcNow
            if (($now-$last).TotalSeconds -ge $interval) {
                if ($WatchFile) {
                    $bytes=if (Test-Path -LiteralPath $WatchFile) { (Get-Item -LiteralPath $WatchFile).Length } else { 0L }
                    $rate=[Math]::Max(0,($bytes-$lastBytes))/1MB/($now-$last).TotalSeconds
                    if ($bytes -gt $lastBytes) { $lastGrowth=$now }
                    Write-Status ('{0}: {1:N1} MiB on disk; {2:N2} MiB/s; elapsed {3:N0}s; no new data for {4:N0}s' -f $Label,($bytes/1MB),$rate,($now-$started).TotalSeconds,($now-$lastGrowth).TotalSeconds)
                    $lastBytes=$bytes
                } else {
                    Write-Status ('{0} still working; elapsed {1:N0}s' -f $Label,($now-$started).TotalSeconds)
                }
                $last=$now
            }
        }
        $process.WaitForExit()
        $code=$process.ExitCode
        if ($null -eq $code) { Stop-Install "Cannot determine the exit code for $Label." 'The child process ended without a usable result. Inspect the process logs before retrying; completion has not been assumed.' 7 }
        return [int]$code
    } finally { $process.Dispose() }
}

function Copy-Tree([string]$Source, [string]$Destination, [string]$Label) {
    New-Directory $Destination | Out-Null
    $log=Join-Path $script:RunLogPath ((Get-TextHash ($Label+$Source+$Destination)).Substring(0,16)+'-copy.log')
    $arguments='"{0}" "{1}" /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NP /NFL /NDL /NJH /NJS /LOG:"{2}"' -f $Source,$Destination,$log
    $code=Invoke-Process (Join-Path $env:WINDIR 'System32\robocopy.exe') $arguments $Label $script:WorkRoot
    if ($code -ge 8) { Stop-Install "$Label failed; robocopy exit $code." "Check permissions, space and locked files. Details: $log" 5 }
}

function Get-RelativePath([string]$Root, [string]$Path) {
    $full=Assert-Within $Path $Root
    return $full.Substring((Get-FullPath $Root).Length+1)
}

function Copy-MappedFile([string]$Source, [string]$Destination) {
    New-Directory ([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Item -LiteralPath $Destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Install "Refusing to overwrite a linked destination file: $Destination" 'Replace it with an ordinary file before installing.' 5 }
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Read-SafeXml([string]$Path) {
    $settings=New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($Path,$settings)
    try {
        $document=New-Object Xml.XmlDocument
        $document.XmlResolver=$null
        $document.Load($reader)
        return ,$document
    } finally { $reader.Dispose() }
}

function Test-Dependency($Node, [hashtable]$Flags) {
    if ($null -eq $Node) { return $true }
    switch ($Node.LocalName) {
        { $_ -in @('dependencies','moduleDependencies','visible') } {
            $results=@($Node.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] } | ForEach-Object { Test-Dependency $_ $Flags })
            if ($Node.GetAttribute('operator') -eq 'Or') { return ($results -contains $true) }
            return -not ($results -contains $false)
        }
        'flagDependency' { return (Get-Value $Flags $Node.GetAttribute('flag') '') -eq $Node.GetAttribute('value') }
        'fileDependency' {
            $name=$Node.GetAttribute('file')
            $state='Missing'
            if ($script:PlannedPlugins.ContainsKey($name)) { $state='Active' }
            elseif (Test-Path -LiteralPath (Get-SafeChild $script:DataPath $name)) { $state='Inactive' }
            switch ($Node.GetAttribute('state')) {
                'Active' { return $state -eq 'Active' }
                'Inactive' { return $state -eq 'Inactive' }
                'Missing' { return $state -eq 'Missing' }
                default { Stop-Install 'Unsupported FOMOD file state.' 'Review the current author installer schema.' 4 }
            }
        }
        'gameDependency' { return $script:Runtime -ge [version]$Node.GetAttribute('version') }
        'fommDependency' { return $true } # Application version gate, not a Skyrim dependency.
        default { Stop-Install "Unsupported FOMOD dependency: $($Node.LocalName)" 'The installer fails closed. Use a reviewed DataRoot override containing only the intended payload, or extend this evaluator.' 4 }
    }
}

function Get-FomodType($Plugin, [hashtable]$Flags) {
    $descriptor=$Plugin.SelectSingleNode('typeDescriptor')
    if ($null -eq $descriptor) { return 'Optional' }
    $simple=$descriptor.SelectSingleNode('type')
    if ($simple) { return $simple.GetAttribute('name') }
    $dynamic=$descriptor.SelectSingleNode('dependencyType')
    if ($null -eq $dynamic) { Stop-Install 'Unknown FOMOD type descriptor.' 'Review the author installer schema.' 4 }
    foreach ($pattern in @($dynamic.SelectNodes('patterns/pattern'))) {
        if (Test-Dependency ($pattern.SelectSingleNode('dependencies')) $Flags) { return $pattern.SelectSingleNode('type').GetAttribute('name') }
    }
    return $dynamic.SelectSingleNode('defaultType').GetAttribute('name')
}

function Get-OrderedXml($Container, [string]$XPath) {
    if ($null -eq $Container) { return @() }
    $nodes=@($Container.SelectNodes($XPath))
    switch ($Container.GetAttribute('order')) {
        'Ascending' { return @($nodes | Sort-Object { $_.GetAttribute('name') }) }
        'Descending' { return @($nodes | Sort-Object { $_.GetAttribute('name') } -Descending) }
        default { return $nodes }
    }
}

function Add-FomodFiles($Files, $Mappings) {
    if ($null -eq $Files) { return }
    foreach ($entry in @($Files.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] })) {
        if ($entry.LocalName -notin @('file','folder')) { Stop-Install "Unknown FOMOD file instruction: $($entry.LocalName)" 'Review the current installer schema instead of copying all option folders.' 4 }
        $priority=0
        if ($entry.HasAttribute('priority') -and -not [int]::TryParse($entry.GetAttribute('priority'),[ref]$priority)) {
            Stop-Install 'Invalid FOMOD file priority.' 'Use a valid original author archive.' 4
        }
        $Mappings.Add([pscustomobject]@{Node=$entry; Priority=$priority; Sequence=$Mappings.Count})
    }
}

function Test-NonEffectsOption([string]$Name) {
    return $Name -match '(?i)\b(non|no|without)[\s_.-]*effects?(?:[\s_.-]*11)?\b'
}

function Assert-LuxCsOptions([string[]]$Selected) {
    foreach ($name in $Selected) {
        if ($name -match '(?i)effects?[\s_.-]*11' -and -not (Test-NonEffectsOption $name)) {
            Stop-Install "Lux CS Effects11 option conflicts with NAT.CS III: $name" 'Select the Non-Effects11 variant; correct the exact saved FomodSelections/choices entry before resuming.' 4
        }
    }
}

function Stage-Fomod($Package, [string]$Root, [string]$ConfigFile, [string]$Output) {
    $xml=Read-SafeXml $ConfigFile
    $module=$xml.DocumentElement
    $flags=@{}
    $nonEffectsSelected=$false
    if (-not (Test-Dependency ($module.SelectSingleNode('moduleDependencies')) $flags)) {
        Stop-Install "$($Package.Name): installer requirements are not met." 'Check required installed masters and runtime versions. No payload from this package was deployed.' 4
    }
    $mappings=New-Object 'Collections.Generic.List[object]'
    Add-FomodFiles ($module.SelectSingleNode('requiredInstallFiles')) $mappings
    $steps=$module.SelectSingleNode('installSteps')
    foreach ($step in @(Get-OrderedXml $steps 'installStep')) {
        if (-not (Test-Dependency ($step.SelectSingleNode('visible')) $flags)) { continue }
        $groups=$step.SelectSingleNode('optionalFileGroups')
        foreach ($group in @(Get-OrderedXml $groups 'group')) {
            $plugins=@(Get-OrderedXml ($group.SelectSingleNode('plugins')) 'plugin')
            $types=@($plugins | ForEach-Object { Get-FomodType $_ $flags })
            $key=$Package.Id+'/'+$step.GetAttribute('name')+'/'+$group.GetAttribute('name')
            $configured=Get-Value $script:Config 'FomodSelections' @{}
            $hasSaved=if ($configured -is [Collections.IDictionary]) { $configured.Contains($key) } else { $null -ne $configured.PSObject.Properties[$key] }
            $saved=Get-Value $configured $key $null
            if (-not $hasSaved -and $script:Choices.ContainsKey($key)) { $saved=$script:Choices[$key]; $hasSaved=$true }
            $required=@(for ($i=0; $i -lt $plugins.Count; $i++) { if ($types[$i] -eq 'Required') { $plugins[$i].GetAttribute('name') } })
            $usable=@(for ($i=0; $i -lt $plugins.Count; $i++) { if ($types[$i] -ne 'NotUsable') { $plugins[$i].GetAttribute('name') } })
            $rule=$group.GetAttribute('type')
            if ($rule -notin @('SelectAll','SelectExactlyOne','SelectAtMostOne','SelectAtLeastOne','SelectAny')) {
                Stop-Install "Unsupported FOMOD selection rule: $rule" 'Review the author installer schema.' 4
            }
            if ($rule -eq 'SelectAll') { $selected=$usable }
            elseif ($hasSaved) { $selected=if ($null -eq $saved) { @() } else { @($saved) }; $selected=@($selected) }
            elseif ($Package.Id -eq 'lux-cs' -and $rule -eq 'SelectExactlyOne' -and @($usable | Where-Object { Test-NonEffectsOption $_ }).Count -eq 1) {
                $selected=@($usable | Where-Object { Test-NonEffectsOption $_ })
            }
            elseif ($usable.Count -eq 0) { $selected=@() }
            elseif ($rule -eq 'SelectExactlyOne' -and $usable.Count -eq 1) { $selected=$usable }
            else {
                Write-Status "$key [$rule]; $($Package.Hint)"
                for ($i=0; $i -lt $plugins.Count; $i++) {
                    $description=$plugins[$i].SelectSingleNode('description')
                    $summary=''
                    if ($description) { $summary=($description.InnerText -replace '\s+',' ').Trim(); if ($summary.Length -gt 190) { $summary=$summary.Substring(0,190)+'...' } }
                    Write-Host ('  {0}. {1} [{2}] {3}' -f ($i+1),$plugins[$i].GetAttribute('name'),$types[$i],$summary)
                }
                $selectionText=Read-Choice 'Numbers separated by commas; 0 for none (Required options are added automatically)'
                $selected=@($required)
                foreach ($part in @($selectionText -split '[,\s]+' | Where-Object { $_ -ne '' -and $_ -ne '0' })) {
                    $number=0
                    if (-not [int]::TryParse($part,[ref]$number) -or $number -lt 1 -or $number -gt $plugins.Count) { Stop-Install "Invalid FOMOD choice: $part" 'Select the displayed numbers. Choices are saved by exact option name.' 4 }
                    $selected+=,$plugins[$number-1].GetAttribute('name')
                }
            }
            $selected=@($selected+$required | Select-Object -Unique)
            if ($Package.Id -eq 'lux-cs') {
                Assert-LuxCsOptions $selected
                if (@($selected | Where-Object { Test-NonEffectsOption $_ }).Count) { $nonEffectsSelected=$true }
            }
            if ($Package.Id -eq 'nat-cs' -and @($selected | Where-Object { $_ -match '(?i)water.*shadow|shadow.*water' -and $_ -notmatch '(?i)\b(no|without|disable|none)\b' }).Count) {
                Stop-Install 'NAT.CS optional water shadows need an additional brightness/reflection fix outside V2.' 'Leave that optional water-shadows choice unselected. Keep the required Skylighting and bundled Cloud Shadows.' 4
            }
            foreach ($name in $selected) {
                if ($name -notin $usable) { Stop-Install "${key}: option is unavailable: $name" 'The archive or dependencies changed. Correct/remove that saved FomodSelections entry.' 4 }
            }
            if (($rule -eq 'SelectExactlyOne' -and $selected.Count -ne 1) -or
                ($rule -eq 'SelectAtMostOne' -and $selected.Count -gt 1) -or
                ($rule -eq 'SelectAtLeastOne' -and $selected.Count -lt 1)) {
                Stop-Install "Selection violates $rule for $key." 'Choose the required number of options; rerun to reuse prior valid choices.' 4
            }
            $script:Choices[$key]=$selected
            Write-Json $script:ChoicesPath $script:Choices
            for ($i=0; $i -lt $plugins.Count; $i++) {
                $plugin=$plugins[$i]
                $chosen=$plugin.GetAttribute('name') -in $selected
                if ($chosen) {
                    Add-FomodFiles ($plugin.SelectSingleNode('files')) $mappings
                    foreach ($flag in @($plugin.SelectNodes('conditionFlags/flag'))) { $flags[$flag.GetAttribute('name')]=$flag.InnerText }
                } else {
                    foreach ($entry in @($plugin.SelectNodes('files/*'))) {
                        if ($entry.GetAttribute('alwaysInstall') -eq 'true' -or ($entry.GetAttribute('installIfUsable') -eq 'true' -and $types[$i] -ne 'NotUsable')) {
                            $priority=0
                            if ($entry.HasAttribute('priority') -and -not [int]::TryParse($entry.GetAttribute('priority'),[ref]$priority)) { Stop-Install 'Invalid FOMOD priority.' 'Use the unmodified author installer.' 4 }
                            $mappings.Add([pscustomobject]@{Node=$entry; Priority=$priority; Sequence=$mappings.Count})
                        }
                    }
                }
            }
        }
    }
    foreach ($pattern in @($module.SelectNodes('conditionalFileInstalls/patterns/pattern'))) {
        if (Test-Dependency ($pattern.SelectSingleNode('dependencies')) $flags) { Add-FomodFiles ($pattern.SelectSingleNode('files')) $mappings }
    }
    if ($Package.Id -eq 'lux-cs' -and -not $nonEffectsSelected) {
        Stop-Install 'The Lux CS installer did not select a reviewed Non-Effects11 variant.' 'Use Lux CS 2.6 or newer with its Non-Effects11 choice. A reviewed DataRoot payload requires Variant: Non-Effects11.' 4
    }
    foreach ($mapping in @($mappings | Sort-Object Priority,Sequence)) {
        $entry=$mapping.Node
        $source=Get-SafeChild $Root $entry.GetAttribute('source') -AllowRoot
        $relative=$entry.GetAttribute('destination') -replace '^(?i)Data[\\/]',''
        if ($relative -eq 'Data') { $relative='' }
        $destination=if ($relative) { Get-SafeChild $Output $relative } else { $Output }
        if (-not (Test-Path -LiteralPath $source)) { Stop-Install "FOMOD source does not exist: $source" 'Redownload the original archive or review its installer paths.' 4 }
        if ($entry.LocalName -eq 'folder') { Copy-Tree $source $destination ('Stage '+$Package.Id) }
        else {
            if ([string]::IsNullOrEmpty($relative) -or $relative.EndsWith('\') -or $relative.EndsWith('/')) { $destination=Join-Path $destination ([IO.Path]::GetFileName($source)) }
            Copy-MappedFile $source $destination
        }
    }
}

function Find-PayloadRoot($Package, [string]$Extracted) {
    $specified=[string](Get-Value (Get-PackageOverride $Package) 'DataRoot' '')
    if ($specified) { return Get-SafeChild $Extracted $specified -AllowRoot }
    $current=$Extracted
    for ($depth=0; $depth -lt 5; $depth++) {
        if (Test-Path -LiteralPath (Join-Path $current 'Data') -PathType Container) { return Join-Path $current 'Data' }
        $items=@(Get-ChildItem -LiteralPath $current -Force | Where-Object { $_.Name -ne '.extraction-complete.json' })
        if (@($items | Where-Object { $_.Name -match '^(?i)(meshes|textures|scripts|SKSE|KiLoader|interface|sound|music|seq|strings|grass|shaders|shadersfx|LightPlacer|ParticleLights|Renderdoc|video|lodsettings)$' -or $_.Name -match '\.(?i)(esm|esp|esl|bsa|bs2)$' }).Count) { return $current }
        $directories=@($items | Where-Object { $_.PSIsContainer -and $_.Name -notmatch '^(?i)(fomod|docs?|screenshots?|images?)$' })
        if ($directories.Count -eq 1) { $current=$directories[0].FullName; continue }
        break
    }
    Stop-Install "Ambiguous plain archive layout for $($Package.Id)." 'Set Packages.<id>.DataRoot to the exact relative payload directory. The script will not dump every option folder into Data.' 4
}

function Find-UniqueFile([string]$Root, [string]$Name) {
    $found=@(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name)
    if ($found.Count -ne 1) { Stop-Install "Expected exactly one $Name; found $($found.Count)." "Inspect the archive/tool package at $Root and configure the intended variant." 4 }
    return $found[0].FullName
}

function Assert-Pe64([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $reader=New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 128 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Not a Windows PE executable.' }
        $stream.Position=0x3c; $offset=$reader.ReadInt32()
        if ($offset -lt 64 -or $offset+6 -gt $stream.Length) { throw 'Invalid PE header position.' }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Not an x64 PE executable.' }
    } catch { Stop-Install "Invalid/wrong-architecture executable: $Path" 'Use the official Windows x64 Skyrim SE package, not LE/VR/Linux or an HTML download.' 4 }
    finally { $reader.Dispose() }
}

function Get-PackageVersion($Package, $Record) {
    $override=Get-PackageOverride $Package
    $text=[string](Get-Value $override 'PackageVersion' (Get-Value $override 'NativeVersion' $Record.Version))
    $match=[regex]::Match($text,'\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { Stop-Install "Unknown version for $($Package.Id): $text" 'For supplied archives record the verified author version in Packages.<id>.PackageVersion (or NativeVersion for native packages).' 4 }
    $parsed=[version]$match.Value
    # Nexus/manual versions may omit a trailing zero; compare the same release consistently.
    return New-Object version($parsed.Major,$parsed.Minor,[Math]::Max(0,$parsed.Build),[Math]::Max(0,$parsed.Revision))
}

function Assert-ShaderPayload($Package, [string]$Data) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Data -Recurse -File)) {
        if ($file.Name -match '^(?i)(d3d11\.dll|d3dcompiler_46e\.dll|enbseries\.ini|enblocal\.ini|Effects11\.ini)$' -or
            (Get-RelativePath $Data $file.FullName) -match '^(?i)enbseries[\\/]') {
            Stop-Install "ENB/Effects11 file is excluded by V2: $($file.FullName)" 'Use the official CS core and Non-Effects11 variants; review archive selections. No conflicting files are installed or removed automatically.' 4
        }
    }
    $required=switch ($Package.Id) {
        'community-shaders' { @('SKSE\Plugins\CommunityShaders.dll','Shaders\Features\CloudShadows.ini','Shaders\Features\ExtendedMaterials.ini','Shaders\Features\InverseSquareLighting.ini') }
        'skylighting' { @('Shaders\Features\Skylighting.ini') }
        'cs-terrain-helper' { @('Shaders\Features\TerrainHelper.ini') }
        'cs-terrain-blending' { @('Shaders\Features\TerrainBlending.ini') }
        default { @() }
    }
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Data $relative) -PathType Leaf)) { Stop-Install "Required $($Package.Id) payload is missing: $relative" 'Use the matching official archive; do not substitute an older release or a partial option folder.' 4 }
    }
}

function Stage-Package($Package, $Record, [string]$Extracted) {
    if ($Package.MinimumVersion -and (Get-PackageVersion $Package $Record) -lt [version]$Package.MinimumVersion) {
        Stop-Install "$($Package.Id) is older than the V2 minimum $($Package.MinimumVersion)." 'Select the reviewed current release; record a verified PackageVersion for supplied archives.' 4
    }
    if ($Package.Id -like 'cs-terrain-*') {
        $core=@($script:Payloads | Where-Object { $_.Package.Id -eq 'community-shaders' })
        if ($core.Count -ne 1 -or (Get-PackageVersion $Package $Record) -ne (Get-PackageVersion $core[0].Package $core[0].Record)) {
            Stop-Install 'Community Shaders terrain feature and core versions differ.' 'Use Terrain Helper/Blending feature archives from the same official CS release as the core. Declare PackageVersion for local archives.' 4
        }
    }
    $output=New-Directory (Join-Path $script:StagePath $Package.Id)
    $data=New-Directory (Join-Path $output 'Data')
    $root=New-Directory (Join-Path $output 'Root')
    $tool=''
    $override=Get-PackageOverride $Package
    switch ($Package.Kind) {
        'Tool' { $tool=$Extracted }
        'Skse' {
            $loader=Find-UniqueFile $Extracted 'skse64_loader.exe'
            $base=[IO.Path]::GetDirectoryName($loader)
            $matching='skse64_'+$script:Runtime.ToString(3).Replace('.','_')+'.dll'
            if (-not (Test-Path -LiteralPath (Join-Path $base $matching))) { Stop-Install "SKSE does not contain $matching." 'Use the SKSE Steam build for the detected runtime. Never rename SkyrimSE.exe to fool the loader.' 4 }
            foreach ($file in @(Get-ChildItem -LiteralPath $base -File | Where-Object { $_.Name -match '^skse64_.*\.(dll|exe)$' })) {
                Assert-Pe64 $file.FullName; Copy-MappedFile $file.FullName (Join-Path $root $file.Name)
            }
            Copy-Tree (Join-Path $base 'Data') $data 'Stage SKSE scripts'
        }
        'Data' {
            $explicit=[string](Get-Value $override 'DataRoot' '')
            $fomods=@(Get-ChildItem -LiteralPath $Extracted -Recurse -File -Filter 'ModuleConfig.xml' | Where-Object { $_.Directory.Name -eq 'fomod' })
            if ($Package.Id -eq 'lux-cs' -and ($explicit -or $fomods.Count -eq 0) -and [string](Get-Value $override 'Variant' '') -ne 'Non-Effects11') {
                Stop-Install 'Lux CS without FOMOD selection needs an explicit reviewed variant.' 'Set Packages.lux-cs.Variant to Non-Effects11 only for a verified complete Non-Effects11 DataRoot/plain payload.' 4
            }
            if (-not $explicit -and $fomods.Count -eq 1) { Stage-Fomod $Package $fomods[0].Directory.Parent.FullName $fomods[0].FullName $data }
            elseif (-not $explicit -and $fomods.Count -gt 1) { Stop-Install 'Archive has multiple FOMOD installers.' 'Select a reviewed DataRoot override instead of mixing alternatives.' 4 }
            else { Copy-Tree (Find-PayloadRoot $Package $Extracted) $data ('Stage '+$Package.Id) }
            if ($Package.Id -eq 'nordic-tint') {
                # The full loose archive has SMP FaceGeom. Retain only its full-resolution FaceTint.
                $tint=Join-Path $data 'textures\actors\character\FaceGenData\FaceTint'
                if (-not (Test-Path -LiteralPath $tint)) { Stop-Install 'Nordic Faces full FaceTint layout changed.' 'Review the full loose FaceGen archive. Do not substitute lower-resolution tints.' 4 }
                foreach ($directory in @(Get-ChildItem -LiteralPath $data -Directory | Where-Object { $_.Name -ne 'textures' })) {
                    $safe=Assert-Within $directory.FullName $data
                    Remove-Item -LiteralPath $safe -Recurse -Force
                }
            }
        }
        default { Stop-Install "Unsupported package kind: $($Package.Kind)" 'Use only reviewed V2 Data, Skse or Tool packages.' 4 }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $relative=Get-RelativePath $root $file.FullName
        if ($relative -notmatch '^(?i)skse64_[^\\]+\.(dll|exe)$') {
            Stop-Install "Disallowed game-root payload: $relative" 'V2 root writes are restricted to SKSE; original game executables cannot come from mod archives.' 4
        }
    }
    Assert-ShaderPayload $Package $data
    foreach ($file in @(Get-ChildItem -LiteralPath $data -Recurse -File)) {
        if ($file.Extension -in @('.exe','.ps1','.bat','.cmd','.vbs')) { Stop-Install "Executable/script found in Data payload: $($file.FullName)" 'Review the author archive and select the actual game-data payload; do not install bundled tool/install folders.' 4 }
        if ($file.DirectoryName -eq $data -and $file.Extension -in @('.esm','.esp','.esl')) { $script:PlannedPlugins[$file.Name]=$true }
    }
    return [pscustomobject]@{Package=$Package; Record=$Record; Data=$data; Root=$root; Tool=$tool}
}

function Read-PluginHeader([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $reader=New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'TES4') { throw 'Missing TES4 header.' }
        $length=$reader.ReadUInt32(); $flags=$reader.ReadUInt32()
        if ($length -gt 16MB -or $length+24 -gt $stream.Length) { throw 'Invalid TES4 record length.' }
        $stream.Position=24; $end=24+$length
        $masters=New-Object 'Collections.Generic.List[string]'
        $extended=0
        while ($stream.Position+6 -le $end) {
            $type=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)); $size=[int]$reader.ReadUInt16()
            if ($type -eq 'XXXX') { if ($size -ne 4) { throw 'Invalid extended subrecord.' }; $extended=[int]$reader.ReadUInt32(); continue }
            if ($extended) { $size=$extended; $extended=0 }
            if ($size -lt 0 -or $stream.Position+$size -gt $end) { throw 'Invalid subrecord bounds.' }
            if ($type -eq 'MAST') { $masters.Add([Text.Encoding]::UTF8.GetString($reader.ReadBytes($size)).TrimEnd([char]0)) }
            else { $stream.Position+=$size }
        }
        return [pscustomobject]@{Name=[IO.Path]::GetFileName($Path); Masters=@($masters); Light=[bool]($flags -band 0x200); Master=[bool]($flags -band 1); Path=$Path}
    } catch { Stop-Install "Cannot read Skyrim SE plugin $Path : $($_.Exception.Message)" 'Replace the corrupt/wrong-game plugin with the correct author SE release.' 6 }
    finally { $reader.Dispose() }
}

function Get-ProfilePlugins {
    $result=New-Object 'Collections.Generic.List[string]'
    foreach ($name in @('Skyrim.esm','Update.esm','Dawnguard.esm','HearthFires.esm','Dragonborn.esm')) { $result.Add($name) }
    $ccc=Join-Path $script:GameRoot 'Skyrim.ccc'
    if (Test-Path -LiteralPath $ccc) {
        foreach ($line in @(Get-Content -LiteralPath $ccc)) {
            $name=$line.Trim()
            if ($name -match '\.(esm|esl|esp)$' -and (Test-Path -LiteralPath (Join-Path $script:DataPath $name)) -and $name -notin $result) { $result.Add($name) }
        }
    }
    $plugins=Join-Path $script:ProfilePath 'plugins.txt'
    if (Test-Path -LiteralPath $plugins) {
        foreach ($line in @(Get-Content -LiteralPath $plugins)) {
            if ($line -match '^\*([^#]+\.(?:esm|esl|esp))\s*$' -and $Matches[1] -notin $result) { $result.Add($Matches[1].Trim()) }
        }
    }
    return @($result | Where-Object { -not $script:OwnedGenerated.ContainsKey($_) })
}

function Get-PluginMap([switch]$Staged) {
    $map=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:DataPath -File | Where-Object { $_.Extension -in @('.esm','.esp','.esl') })) { $map[$file.Name]=$file.FullName }
    if ($Staged) {
        foreach ($payload in $script:Payloads) {
            foreach ($file in @(Get-ChildItem -LiteralPath $payload.Data -File | Where-Object { $_.Extension -in @('.esm','.esp','.esl') })) { $map[$file.Name]=$file.FullName }
        }
    }
    return $map
}

function Resolve-PluginOrder([string[]]$Requested, [hashtable]$Map) {
    $headers=@{}; $visiting=@{}; $done=@{}; $ordered=New-Object 'Collections.Generic.List[string]'
    # Explicit stack avoids PowerShell child-scope mutations in recursive script blocks.
    foreach ($initial in @($Requested | Select-Object -Unique)) {
        $stack=New-Object 'Collections.Generic.Stack[object]'
        $stack.Push(@{Name=$initial; Finish=$false})
        while ($stack.Count) {
            $item=$stack.Pop(); $name=[string]$item.Name
            if ($done.ContainsKey($name)) { continue }
            if ($item.Finish) { $visiting.Remove($name); $done[$name]=$true; $ordered.Add($name); continue }
            if ($visiting.ContainsKey($name)) { Stop-Install "Circular plugin master dependency at $name." 'Remove the incompatible patch combination; inspect plugin masters in xEdit.' 6 }
            if (-not $Map.ContainsKey($name)) { Stop-Install "Missing required plugin/master: $name" 'Install its author dependency or deselect the patch requiring it. Never fabricate an empty master plugin.' 6 }
            if (-not $headers.ContainsKey($name)) { $headers[$name]=Read-PluginHeader $Map[$name] }
            $visiting[$name]=$true
            $stack.Push(@{Name=$name; Finish=$true})
            $masters=@($headers[$name].Masters)
            for ($i=$masters.Count-1; $i -ge 0; $i--) { if (-not $done.ContainsKey($masters[$i])) { $stack.Push(@{Name=$masters[$i]; Finish=$false}) } }
        }
    }
    $full=@($ordered | Where-Object { -not $headers[$_].Light }).Count
    $light=@($ordered | Where-Object { $headers[$_].Light }).Count
    if ($full -gt 254 -or $light -gt 4096) { Stop-Install "Plugin limits exceeded: $full full, $light light." 'Reduce or properly ESL-flag compatible plugins using author guidance; do not merge/flag arbitrarily.' 6 }
    return @($ordered)
}

function Write-PluginOrder([string[]]$Order) {
    New-Directory $script:ProfilePath | Out-Null
    $implicit=Get-ImplicitPlugins
    $lines=@('# Managed by Install-SkyrimMods.ps1; original unrelated active plugins retained.')
    $lines+=@($Order | Where-Object { $_ -notin $implicit } | ForEach-Object { '*'+$_ })
    $encoding=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines((Join-Path $script:ProfilePath 'plugins.txt'),[string[]]$lines,$encoding)
    [IO.File]::WriteAllLines((Join-Path $script:ProfilePath 'loadorder.txt'),[string[]]$Order,$encoding)
}

function Get-ImplicitPlugins {
    $result=@('Skyrim.esm','Update.esm','Dawnguard.esm','HearthFires.esm','Dragonborn.esm')
    $ccc=Join-Path $script:GameRoot 'Skyrim.ccc'
    if (Test-Path -LiteralPath $ccc) { $result+=@(Get-Content -LiteralPath $ccc | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.(esm|esp|esl)$' }) }
    return @($result | Select-Object -Unique)
}

function Assert-ActualLoadOrder {
    $order=@(Get-ImplicitPlugins | Where-Object { Test-Path -LiteralPath (Join-Path $script:DataPath $_) })
    foreach ($line in @(Get-Content -LiteralPath (Join-Path $script:ProfilePath 'plugins.txt'))) {
        if ($line -match '^\*(.+\.(?:esm|esp|esl))\s*$') { $name=$Matches[1].Trim(); if ($name -notin $order) { $order+=,$name } }
    }
    $map=Get-PluginMap
    $resolved=@(Resolve-PluginOrder $order $map)
    if ($resolved.Count -ne $order.Count) { Stop-Install 'A required master was not enabled by the sorter.' 'Review LOOT errors and enable the missing master; rerun Install -Resume.' 6 }
    $seen=@{}
    foreach ($name in $order) {
        $header=Read-PluginHeader $map[$name]
        foreach ($master in $header.Masters) { if (-not $seen.ContainsKey($master)) { Stop-Install "$name loads before its required master $master." 'Fix LOOT metadata/load-order constraints; do not start Skyrim with this order.' 6 } }
        $seen[$name]=$true
    }
    # Preserve the intentional QW -> Skoglendi winning grass order after sorting.
    $qw=@($order | Where-Object { $_ -match '^QW.*Grass Patch 2' })
    $skog=@($order | Where-Object { $_ -match '^Skoglendi.*\.esp$' -and $_ -notmatch 'Patch' })
    if ($qw.Count -and $skog.Count -and [array]::IndexOf($order,$qw[0]) -gt [array]::IndexOf($order,$skog[0])) {
        Stop-Install 'LOOT reversed the requested QW -> Skoglendi winning-plugin order.' 'In LOOT add a Skoglendi loads-after QW rule, apply sorting, then resume. A separate hybrid patch is needed if you want both grass overhauls combined.' 6
    }
    $script:ActiveOrder=$order
}

function Set-IniValues([string]$Path, [hashtable]$Sections) {
    $lines=New-Object 'Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Path) { foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) } }
    foreach ($section in $Sections.Keys) {
        foreach ($key in $Sections[$section].Keys) {
            $current=''; $indices=New-Object 'Collections.Generic.List[int]'; $sectionStart=-1
            for ($i=0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*\[([^\]]+)\]') { $current=$Matches[1]; if ($current -eq $section) { $sectionStart=$i } }
                elseif ($current -eq $section -and $lines[$i] -match ('^\s*'+[regex]::Escape($key)+'\s*=')) { $indices.Add($i) }
            }
            $value=$key+'='+[string]$Sections[$section][$key]
            if ($indices.Count) {
                $lines[$indices[0]]=$value
                for ($i=$indices.Count-1; $i -ge 1; $i--) { $lines.RemoveAt($indices[$i]) }
            } elseif ($sectionStart -ge 0) { $lines.Insert($sectionStart+1,$value) }
            else { $lines.Add(''); $lines.Add('['+$section+']'); $lines.Add($value) }
        }
    }
    # Skyrim INIs use legacy ANSI; retain it to avoid a UTF-8 BOM/parser mismatch.
    [IO.File]::WriteAllLines($Path,[string[]]@($lines),[Text.Encoding]::Default)
}





function Assert-NativeCompatibility {
    $files=@{}
    foreach ($directory in @((Join-Path $script:DataPath 'SKSE\Plugins'),(Join-Path $script:DataPath 'KiLoader'))) {
      if (Test-Path -LiteralPath $directory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.dll')) {
            $relative=Get-RelativePath $script:DataPath $file.FullName
            $files[$relative]=@{File=$file.FullName; Name=$file.Name; Package='existing'; Version='unknown'}
        }
      }
    }
    foreach ($payload in $script:Payloads) {
        foreach ($directory in @((Join-Path $payload.Data 'SKSE\Plugins'),(Join-Path $payload.Data 'KiLoader'))) {
          if (Test-Path -LiteralPath $directory) {
            foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.dll')) {
                $override=Get-PackageOverride $payload.Package
                $version=[string](Get-Value $override 'NativeVersion' (Get-Value $override 'PackageVersion' $payload.Record.Version))
                $relative=Get-RelativePath $payload.Data $file.FullName
                $files[$relative]=@{File=$file.FullName; Name=$file.Name; Package=$payload.Package.Id; Version=$version}
            }
          }
        }
    }
    $approved=Get-Value $script:Config 'NativeCompatibility' @{}
    foreach ($name in $files.Keys) {
        Assert-Pe64 $files[$name].File
        $proof=Get-Value $approved $files[$name].Name (Get-Value $approved $files[$name].Package $null)
        if ($null -eq $proof -or $script:Runtime.ToString(3) -notin @(Get-Value $proof 'Runtimes' @()) -or [string](Get-Value $proof 'EvidenceUrl' '') -notmatch '^https://') {
            Stop-Install "Unreviewed native DLL for runtime $($script:Runtime.ToString(3)): $name ($($files[$name].Package))" 'Check the author compatibility statement. Add NativeCompatibility.<DLL name or package id> with Runtimes and EvidenceUrl only after verification. An incompatible SKSE DLL can prevent Steam launching the game.' 4
        }
        $minimum=[string](Get-Value $proof 'MinimumVersion' '')
        if ($minimum) {
            $version=$files[$name].Version
            $match=[regex]::Match($version,'\d+(?:\.\d+){1,3}')
            $old=(-not $match.Success -or [version]$match.Value -lt [version]$minimum)
            if ($old) {
                Stop-Install "Native package is too old or its version is unknown: $name ($version); minimum $minimum." 'Use a supported release. For supplied archives set Packages.<id>.NativeVersion to the verified author version, not an invented version.' 4
            }
        }
        $minimumAlpha=[int](Get-Value $proof 'MinimumAlpha' 0)
        if ($minimumAlpha -gt 0 -and ($files[$name].Version -notmatch '(?i)Alpha[- ]?(\d+)' -or [int]$Matches[1] -lt $minimumAlpha)) {
            Stop-Install "Native $name requires Alpha-$minimumAlpha or newer; found $($files[$name].Version)." 'Use a runtime-compatible DynDOLOD DLL NG release; for a supplied archive set its verified NativeVersion.' 4
        }
        Write-Status ("Native check: {0}, runtime {1}, version {2}" -f $name,$script:Runtime.ToString(3),$files[$name].Version) 'OK'
    }
    $address=@($script:Payloads | Where-Object { $_.Package.Id -eq 'address-library' })[0]
    $databases=@(Get-ChildItem -LiteralPath $address.Data -Recurse -File | Where-Object { $_.Name -match ([regex]::Escape($script:Runtime.ToString(3).Replace('.','-'))) -and $_.Extension -in @('.bin','.db') })
    if (-not $databases.Count) { Stop-Install 'Address Library has no database for this Skyrim runtime.' 'Select the current All in One package that explicitly includes the detected Steam runtime.' 4 }
}

function Configure-Inis {
    Set-IniValues (Join-Path $script:IniPath 'Skyrim.ini') @{
        Archive=@{bInvalidateOlderFiles='1';sResourceDataDirsFinal=''}
        Grass=@{iMaxGrassTypesPerTexure='15'}
    }
    Set-IniValues (Join-Path $script:IniPath 'SkyrimPrefs.ini') @{
        Display=@{bSAOEnable='0';bEnableImprovedSnow='0';bVolumetricLightingEnable='1';bUse64bitsHDRRenderTarget='1';bDrawLandShadows='1';bDoDepthOfField='1'}
    }
    Write-Status 'Configured real Skyrim INIs; Community Shaders feature settings come from the staged core/NAT.CS payloads' 'OK'
}

function Get-Tool([string]$Id, [string[]]$Names) {
    $payload=@($script:Payloads | Where-Object { $_.Package.Id -eq $Id })[0]
    $override=Get-PackageOverride $payload.Package
    $relative=[string](Get-Value $override 'ToolExecutable' '')
    if ($relative) { $path=Get-SafeChild $payload.Tool $relative; if (Test-Path -LiteralPath $path) { return $path } }
    foreach ($name in $Names) {
        $matches=@(Get-ChildItem -LiteralPath $payload.Tool -Recurse -File -Filter $name)
        if ($matches.Count -eq 1) { return $matches[0].FullName }
    }
    Stop-Install "Executable not uniquely found for $Id." 'Set Packages.<id>.ToolExecutable to the correct relative Windows x64 executable inside the extracted tool archive.' 7
}

function Sort-Plugins {
    Set-Phase 'Sorting and validating plugins with LOOT'
    $exe=Get-Tool 'loot' @('LOOT.exe')
    $arguments='--game="Skyrim Special Edition" --game-path="'+$script:GameRoot+'" --auto-sort'
    $lootLogs=@{}
    $lootHome=Join-Path $env:LOCALAPPDATA 'LOOT'
    if (Test-Path -LiteralPath $lootHome) {
        foreach ($file in @(Get-ChildItem -LiteralPath $lootHome -Recurse -File -Filter '*DebugLog*')) { $lootLogs[$file.FullName]=[IO.File]::ReadAllText($file.FullName) }
    }
    $started=[DateTime]::UtcNow
    $code=Invoke-Process $exe $arguments 'LOOT sorting' ([IO.Path]::GetDirectoryName($exe))
    if ($code -ne 0) { Stop-Install "LOOT failed; exit $code." 'Open the supplied portable LOOT, inspect its messages/log, fix the reported missing master or metadata error, and rerun Install -Resume.' 6 }
    if (Test-Path -LiteralPath $lootHome) {
        foreach ($file in @(Get-ChildItem -LiteralPath $lootHome -Recurse -File -Filter '*DebugLog*' | Where-Object { $_.LastWriteTimeUtc -ge $started })) {
            $content=[IO.File]::ReadAllText($file.FullName)
            $previous=[string](Get-Value $lootLogs $file.FullName '')
            if ($previous -and $content.StartsWith($previous,[StringComparison]::Ordinal)) { $content=$content.Substring($previous.Length) }
            $copy=Join-Path $script:RunLogPath ('loot-'+[guid]::NewGuid().ToString('N')+'.log')
            [IO.File]::WriteAllText($copy,(Protect-Message $content))
            if ($content -match '(?im)\[(error|critical)\]') { Stop-Install 'LOOT reported an error even though its process exited with 0.' "Inspect $copy and LOOT's interface, correct the reported cause, then resume." 6 }
        }
    }
    Assert-ActualLoadOrder
    # --auto-sort may quit without applying when it reports errors. Exact expected
    # plugins and master ordering are checked independently of its exit code.
    foreach ($name in $script:PlannedPlugins.Keys) {
        if ($name -notin $script:ActiveOrder) { Stop-Install "LOOT did not leave the required plugin enabled: $name" 'Review LOOT errors and plugins.txt; fix the reason before resuming.' 6 }
    }
    Write-Status ('LOOT result validated: '+$script:ActiveOrder.Count+' active plugins') 'OK'
}

function Get-OutputManifest([string]$Directory) {
    Assert-NoChildLinks $Directory
    $manifest=New-Object 'Collections.Generic.List[object]'; $last=[DateTime]::UtcNow
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Install 'Generated output contains a filesystem link.' 'Use a fresh ordinary output directory.' 7 }
        $manifest.Add([pscustomobject]@{Path=Get-RelativePath $Directory $file.FullName; Length=$file.Length; Sha256=Get-Hash $file.FullName})
        if (([DateTime]::UtcNow-$last).TotalSeconds -ge 30) { Write-Status ('Verifying generated files: '+$manifest.Count); $last=[DateTime]::UtcNow }
    }
    return @($manifest)
}

function Test-OutputManifest($Checkpoint) {
    $directory=[string](Get-Value $Checkpoint 'Output' '')
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) { return $false }
    Assert-Within $directory $script:GeneratedPath | Out-Null
    foreach ($entry in @(Get-Value $Checkpoint 'Files' @())) {
        $file=Get-SafeChild $directory $entry.Path
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -ne $entry.Length -or (Get-Hash $file) -ne $entry.Sha256) { return $false }
    }
    return @(Get-Value $Checkpoint 'Files' @()).Count -gt 0
}

function Deploy-Generated([string]$Id, $Checkpoint) {
    # The ownership journal is written BEFORE copying, covering interrupted copies.
    foreach ($entry in $Checkpoint.Files) {
        $relative=[string]$entry.Path
        if ($relative -match '^(?i)(meshes|textures|grass|lodsettings|scripts|SKSE)[\\/]' -or $relative -match '^[^\\/]+\.(?i)(esm|esp|esl|bsa|ini|json)$') {
            $script:OwnedGenerated[$relative]=$Id
            $source=Get-SafeChild $Checkpoint.Output $relative
            $target=Get-SafeChild $script:DataPath $relative
            if ([IO.Path]::GetExtension($relative) -in @('.esm','.esp','.esl') -and $relative -notmatch '[\\/]') { $script:PlannedPlugins[$relative]=$true }
        }
    }
    Write-Json $script:OwnedPath $script:OwnedGenerated
    foreach ($entry in $Checkpoint.Files) {
        if ((Get-Value $script:OwnedGenerated $entry.Path '') -eq $Id) {
            Copy-MappedFile (Get-SafeChild $Checkpoint.Output $entry.Path) (Get-SafeChild $script:DataPath $entry.Path)
        }
    }
    $order=@(Get-ProfilePlugins)+@($script:PlannedPlugins.Keys | Sort-Object)
    Write-PluginOrder (Resolve-PluginOrder $order (Get-PluginMap))
    $script:InputSignature=Get-TextHash ($script:InputSignature+'|'+$Id+'|'+(ConvertTo-CanonicalJson $Checkpoint.Files))
    Write-Status ("Installed $Id generated output") 'OK'
}

function Clear-OwnedGenerated {
    if (-not $script:OwnedGenerated.Count) { return }
    Write-Status ('Removing '+$script:OwnedGenerated.Count+' previously generated files before replaying the base assets')
    foreach ($relative in @($script:OwnedGenerated.Keys)) {
        $target=Get-SafeChild $script:DataPath $relative
        if (Test-Path -LiteralPath $target -PathType Container) { Stop-Install "Generated ownership record unexpectedly names a directory: $relative" 'Inspect ownership.json. Only individually recorded generated files may be removed.' 5 }
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    }
    $script:OwnedGenerated=@{}
    Write-Json $script:OwnedPath $script:OwnedGenerated
    Write-Status 'Removed individually owned generated files; cached source outputs remain available for verified reuse/regeneration' 'OK'
}

function Run-Generator([string]$Id, [string]$ToolId, [string[]]$Names, [string]$Instructions) {
    Set-Phase ('Generating '+$Id)
    if ($Resume -and $script:Generated.ContainsKey($Id)) {
        $saved=$script:Generated[$Id]
        if ((Get-Value $saved 'Signature' '') -eq $script:InputSignature -and (Test-OutputManifest $saved)) {
            Write-Status ('Reusing fully verified '+$Id+' checkpoint') 'OK'
            Deploy-Generated $Id $saved
            return
        }
        Write-Status ('Invalidated '+$Id+' checkpoint: inputs changed or output verification failed') 'WARN'
    }
    if ($NonInteractive) { Stop-Install "$Id requires its official generator interface." 'Run Install interactively. A fully verified checkpoint can be reused with -Resume -NonInteractive, but unconfigured generation is never guessed.' 7 }
    $exe=Get-Tool $ToolId $Names
    $output=New-Directory (Join-Path $script:GeneratedPath ($Id+'-'+[guid]::NewGuid().ToString('N')))
    Write-Status "Output directory (must be selected in $Id): $output"
    Write-Host $Instructions -ForegroundColor White
    Write-Host 'Do not continue past missing-master, invalid-reference or generation errors. Close the generator after successful completion.' -ForegroundColor Yellow
    $generatorArguments=''
    if ($Id -ne 'PGPatcher') {
        # xEdit's documented quoted trailing-backslash syntax (do not replace with
        # generic C argv escaping; these tools use the Windows/Delphi parser).
        $generatorArguments='-sse -o:"'+$output+'\" -d:"'+$script:DataPath+'\" -p:"'+(Join-Path $script:ProfilePath 'plugins.txt')+'" -m:"'+$script:IniPath+'\"'
    }
    $code=Invoke-Process $exe $generatorArguments $Id ([IO.Path]::GetDirectoryName($exe)) -Visible
    if ($code -ne 0) { Stop-Install "$Id failed; exit $code." "Inspect its own log in $([IO.Path]::GetDirectoryName($exe)). Correct the cause and rerun Install -Resume; completed earlier outputs are retained." 7 }
    $files=@(Get-ChildItem -LiteralPath $output -Recurse -File)
    switch ($Id) {
        'PGPatcher' {
            $diff=Join-Path $output 'ParallaxGen_Diff.json'
            if (-not (Test-Path -LiteralPath $diff) -or -not @($files | Where-Object { $_.Extension -eq '.nif' }).Count) {
                Stop-Install 'PGPatcher produced no validated patched-mesh output.' 'Set the fresh output folder shown above, disable ZIP output, select SSE / no mod manager, enable Community Shaders-compatible complex-material/parallax patching, and rerun.' 7
            }
            Get-Content -LiteralPath $diff -Raw | ConvertFrom-Json | Out-Null
        }
        'xLODGen' {
            if (-not @($files | Where-Object { $_.Extension -eq '.btr' }).Count -or -not @($files | Where-Object { $_.Extension -eq '.dds' }).Count) {
                Stop-Install 'xLODGen did not generate terrain meshes AND textures.' 'Use SSE, all required worldspaces, Terrain LOD only, Build meshes and Build diffuse/normal textures, and the displayed fresh output directory.' 7
            }
            if (@($files | Where-Object { $_.Extension -in @('.bto','.btt') }).Count) { Stop-Install 'xLODGen also generated object/tree LOD.' 'Generate TERRAIN ONLY here. DynDOLOD must produce the final object/tree LOD after TexGen.' 7 }
        }
        'TexGen' {
            if (-not @($files | Where-Object { $_.Extension -eq '.dds' }).Count) { Stop-Install 'TexGen produced no texture output.' 'Set the displayed output directory and generate billboards/LOD textures from the finalized assets.' 7 }
        }
        'DynDOLOD' {
            foreach ($name in @('DynDOLOD.esm','DynDOLOD.esp')) { if (-not (Test-Path -LiteralPath (Join-Path $output $name))) { Stop-Install "DynDOLOD output is missing $name." 'Resolve all errors and generate the final SSE object/tree LOD, not a TexGen or terrain-only output.' 7 } }
            if (-not @($files | Where-Object { $_.Extension -eq '.bto' }).Count) { Stop-Install 'DynDOLOD produced no object LOD meshes.' 'Inspect the DynDOLOD log and select the required worldspaces.' 7 }
        }
    }
    $answer=Read-Choice "Confirm $Id finished successfully and its error messages/log were reviewed: type DONE"
    if ($answer -cne 'DONE') { Stop-Install "$Id completion was not confirmed." 'Review the generator log. A process exiting with 0 is not sufficient proof that generation completed.' 7 }
    $checkpoint=[pscustomobject]@{Signature=$script:InputSignature; Output=$output; Files=@(Get-OutputManifest $output); CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    $script:Generated[$Id]=$checkpoint
    Write-Json $script:GeneratedStatePath $script:Generated
    Deploy-Generated $Id $checkpoint
}

function Assert-FinalGenerationOrder {
    Assert-ActualLoadOrder
    $order=$script:ActiveOrder
    $dyn=[array]::IndexOf($order,'DynDOLOD.esp')
    $normal=@($order | Where-Object { $_ -notmatch '^(?i)(PGPatcher|ParallaxGen|PG_).*\.(esp|esm|esl)$|^(DynDOLOD\.(esm|esp)|Occlusion\.esp)$' })
    foreach ($name in @($order | Where-Object { $_ -match '^(?i)PG_\d+\.esp$' })) {
        $index=[array]::IndexOf($order,$name)
        if ($index -gt $dyn -or @($normal | Where-Object { [array]::IndexOf($order,$_) -gt $index }).Count) { Stop-Install "$name is not after normal plugins and before DynDOLOD.esp." 'Apply LOOT rules for PG_X plugins to load last except DynDOLOD/Occlusion. PGPatcher.esp is a master holding new texture sets and does not require that same late position.' 6 }
    }
    foreach ($name in @('DynDOLOD.esm','DynDOLOD.esp')) {
        if ($name -notin $order) { Stop-Install "Final generated plugin is disabled: $name" 'Enable both DynDOLOD outputs and resolve LOOT messages.' 6 }
    }
    if ('Occlusion.esp' -in $order -and $order[-1] -ne 'Occlusion.esp') { Stop-Install 'Occlusion.esp is not last.' 'Apply the DynDOLOD/LOOT recommended final Occlusion ordering.' 6 }
}

function Build-SteamBridge {
    Set-Phase 'Building the invisible normal-Steam launcher bridge'
    $source=Join-Path $PSScriptRoot 'SteamSkyrimBridge.cs'
    if (-not (Test-Path -LiteralPath $source)) { Stop-Install 'SteamSkyrimBridge.cs is missing.' 'Keep the supplied bridge source beside the installer.' 8 }
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { Stop-Install 'Windows .NET Framework C# compiler was not found.' 'Enable .NET Framework 4.x in Windows. The bridge does not require PowerShell or a mod manager during play.' 8 }
    $manifest=Join-Path $PSScriptRoot 'SteamSkyrimBridge.manifest'
    $script:BridgeExecutable=Join-Path $script:RunLogPath 'SkyrimSELauncher.exe'
    $buildLog=Join-Path $script:RunLogPath 'bridge-build.log'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ ('/out:'+$script:BridgeExecutable) ('/win32manifest:'+$manifest) /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll $source 2>&1 | Out-File -LiteralPath $buildLog -Encoding utf8
    if ($LASTEXITCODE -ne 0) { Stop-Install 'Steam launcher bridge compilation failed.' "Details: $buildLog. No game launcher was replaced." 8 }
    Assert-Pe64 $script:BridgeExecutable
}

function Get-LaunchFiles {
    $files=@('SkyrimSE.exe','skse64_loader.exe',('skse64_'+$script:Runtime.ToString(3).Replace('.','_')+'.dll'),'Data\SKSE\Plugins\CommunityShaders.dll')
    foreach ($directory in @((Join-Path $script:DataPath 'SKSE\Plugins'),(Join-Path $script:DataPath 'KiLoader'))) {
        if (Test-Path -LiteralPath $directory) {
            foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.dll')) { $files+=Get-RelativePath $script:GameRoot $file.FullName }
        }
    }
    foreach ($name in @('CloudShadows','ExtendedMaterials','InverseSquareLighting','Skylighting','TerrainHelper','TerrainBlending')) { $files+='Data\Shaders\Features\'+$name+'.ini' }
    return @($files | Sort-Object -Unique)
}

function Install-SteamBridge {
    Set-Phase 'Applying the Steam launch bridge (last installation step)'
    Assert-CompatibilityDecisions
    $files=@(Get-LaunchFiles)
    $hashes=@{}
    foreach ($name in $files) { $hashes[$name]=Get-Hash (Join-Path $script:GameRoot $name) }
    $receipt=@{SchemaVersion=2; InstallListVersion='V2'; RenderingFramework='CommunityShaders'; Runtime=$script:Runtime.ToString(3); SteamAppId='489830'; Hashes=$hashes; InputSignature=$script:InputSignature; CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    Write-Json (Join-Path $script:GameRoot 'SteamSkyrimBridge.json') $receipt
    $launcher=Join-Path $script:GameRoot 'SkyrimSELauncher.exe'
    $stock=Join-Path $script:GameRoot 'SkyrimSELauncher.stock.exe'
    if (-not (Test-Path -LiteralPath $stock) -and -not (Test-Path -LiteralPath (Join-Path $script:GameRoot 'SteamSkyrimBridge.installed.json'))) { Copy-Item -LiteralPath $launcher -Destination $stock }
    $pending=Join-Path $script:GameRoot 'SkyrimSELauncher.pending.exe'
    Copy-Item -LiteralPath $script:BridgeExecutable -Destination $pending -Force
    [IO.File]::Replace($pending,$launcher,[NullString]::Value)
    Write-Json (Join-Path $script:GameRoot 'SteamSkyrimBridge.installed.json') @{Hash=Get-Hash $launcher;CompletedUtc=$receipt.CompletedUtc}
    Write-Status 'Normal Steam Play now targets the hidden SKSE bridge; SkyrimSE.exe was not renamed or modified' 'OK'
}

function ConvertTo-CanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [Collections.IDictionary]) {
        $pairs=@(foreach ($key in @($Value.Keys | Sort-Object)) { (ConvertTo-Json -InputObject ([string]$key) -Compress)+':'+(ConvertTo-CanonicalJson $Value[$key]) })
        return '{'+($pairs -join ',')+'}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items=@(foreach ($item in $Value) { ConvertTo-CanonicalJson $item })
        return '['+($items -join ',')+']'
    }
    $pairs=@(foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { (ConvertTo-Json -InputObject $property.Name -Compress)+':'+(ConvertTo-CanonicalJson $property.Value) })
    return '{'+($pairs -join ',')+'}'
}

function Assert-CompatibilityDecisions {
    foreach ($relative in @('d3d11.dll','d3dcompiler_46e.dll','enbseries.ini','enblocal.ini','enbseries','Data\Shaders\Features\Effects11.ini')) {
        if (Test-Path -LiteralPath (Join-Path $script:GameRoot $relative)) {
            Stop-Install "Existing ENB/Effects11 component conflicts with V2: $relative" 'Review and remove that old component before Prepare/Install. The installer does not remove existing mods automatically.' 3
        }
    }
    Write-Status 'V2: Community Shaders + NAT.CS III + Non-Effects11 Lux CS, with Fantasia/Terrain Helper' 'OK'
}



function Set-GenerationSignature {
    Set-Phase 'Hashing finalized base assets for safe generator resume'
    $hasher=[Security.Cryptography.SHA256]::Create(); $last=[DateTime]::UtcNow; $count=0
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:DataPath -Recurse -File | Sort-Object FullName)) {
            $relative=Get-RelativePath $script:DataPath $file.FullName
            $record=$relative.ToLowerInvariant()+'|'+$file.Length+'|'+(Get-Hash $file.FullName)+"`n"
            $bytes=[Text.Encoding]::UTF8.GetBytes($record)
            $hasher.TransformBlock($bytes,0,$bytes.Length,$bytes,0) | Out-Null
            $count++
            if (([DateTime]::UtcNow-$last).TotalSeconds -ge 30) { Write-Status ('Verified base assets: '+$count+' files'); $last=[DateTime]::UtcNow }
        }
        $hasher.TransformFinalBlock((New-Object byte[] 0),0,0) | Out-Null
        $dataHash=([BitConverter]::ToString($hasher.Hash)).Replace('-','')
    } finally { $hasher.Dispose() }
    $extra=@($script:InputSignature,$dataHash,($script:ActiveOrder -join '|'))
    foreach ($name in @('Skyrim.ini','SkyrimPrefs.ini')) { $extra+=Get-Hash (Join-Path $script:IniPath $name) }
    foreach ($name in @('SkyrimSE.exe','skse64_loader.exe',('skse64_'+$script:Runtime.ToString(3).Replace('.','_')+'.dll'))) { $extra+=Get-Hash (Join-Path $script:GameRoot $name) }
    $script:InputSignature=Get-TextHash ($extra -join '|')
    Write-Status ('Finalized base signature computed from '+$count+' files; generator outputs are chained separately') 'OK'
}

function Assert-OrdinaryDirectory([string]$Path) {
    $current=$Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item=Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Install "Path uses a reparse point: $current" 'Choose ordinary, non-symlink directories. This protects archive extraction and owned-file cleanup.' 3 }
        }
        $parent=[IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current=$parent.FullName
    }
}

function Assert-NoChildLinks([string]$Root) {
    $stack=New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count) {
        $directory=New-Object IO.DirectoryInfo($stack.Pop())
        foreach ($entry in $directory.GetFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Install "Linked file/directory inside the deployment path: $($entry.FullName)" 'Use ordinary files/directories. The installer will not traverse links and write or remove data outside the inspected target.' 3 }
            if ($entry.Attributes -band [IO.FileAttributes]::Directory) { $stack.Push($entry.FullName) }
        }
    }
}

function Assert-FreeSpace([string]$Path, [double]$GiB, [string]$Label) {
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))
    if (-not $drive.IsReady -or $drive.AvailableFreeSpace -lt $GiB*1GB) {
        Stop-Install ("Insufficient free space for {0}: need at least {1:N1} GiB; available {2:N1} GiB." -f $Label,$GiB,($drive.AvailableFreeSpace/1GB)) 'Move WorkPath to a larger drive or free space. Configured thresholds are minimums, not guaranteed total requirements for future releases.' 3
    }
}

function Assert-NotRunning {
    $busy=@(Get-Process -Name 'SkyrimSE','SkyrimSELauncher','skse64_loader','DynDOLODx64','TexGenx64','xLODGenx64','PGPatcher' -ErrorAction SilentlyContinue)
    if ($busy.Count) { Stop-Install ('Game/mod tools are running: '+(($busy | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) 'Close Skyrim and these tools before preparing/deploying. Do not launch Steam Play during installation.' 3 }
}

function Assert-NoElevationLayers {
    foreach ($registry in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers','HKLM:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers')) {
        if (-not (Test-Path $registry)) { continue }
        $layers=Get-ItemProperty $registry
        foreach ($name in @('SkyrimSE.exe','SkyrimSELauncher.exe','skse64_loader.exe')) {
            $path=Join-Path $script:GameRoot $name
            if ([string](Get-Value $layers $path '') -match '(?i)RUNASADMIN') { Stop-Install "Run-as-administrator compatibility flag is enabled for $name." 'Uncheck Run this program as administrator in Windows Compatibility settings. Steam Remote Play must launch the game without a UAC prompt.' 3 }
        }
    }
}

function Initialize-Paths {
    $script:GameRoot=Get-FullPath $GamePath
    $script:WorkRoot=Get-FullPath $WorkPath
    if ($script:WorkRoot -eq $script:GameRoot -or $script:WorkRoot.StartsWith($script:GameRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
        $script:WorkRoot -eq [IO.Path]::GetPathRoot($script:WorkRoot).TrimEnd('\') -or $script:WorkRoot -eq (Get-FullPath $env:USERPROFILE)) {
        Stop-Install 'WorkPath must be a dedicated directory outside Skyrim and cannot be a drive/profile root.' 'Use a dedicated local path such as D:\SkyrimModInstaller.' 3
    }
    $script:DataPath=Join-Path $script:GameRoot 'Data'
    $script:ProfilePath=Join-Path $env:LOCALAPPDATA 'Skyrim Special Edition'
    $script:IniPath=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\Skyrim Special Edition'
    $script:DownloadPath=Join-Path $script:WorkRoot 'Downloads'
    $script:ExtractPath=Join-Path $script:WorkRoot 'Extracted'
    $script:ToolPath=Join-Path $script:WorkRoot 'Tools'
    $script:GeneratedPath=Join-Path $script:WorkRoot 'Generated'
    $script:LockPath=Join-Path $script:WorkRoot 'downloads.lock.json'
    $script:ChoicesPath=Join-Path $script:WorkRoot 'fomod.choices.json'
    $script:GeneratedStatePath=Join-Path $script:WorkRoot 'generation.checkpoints.json'
    $script:OwnedPath=Join-Path $script:WorkRoot 'generated.ownership.json'
    $script:StatePath=Join-Path $script:WorkRoot 'installation.state.json'
    $script:Payloads=New-Object 'Collections.Generic.List[object]'
    $script:OwnedGenerated=@{}
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $defaultConfig=Join-Path $PSScriptRoot 'SkyrimMods.config.json'
        $exampleConfig=Join-Path $PSScriptRoot 'SkyrimMods.config.example.json'
        if ((Get-FullPath $ConfigPath) -ne (Get-FullPath $defaultConfig) -or -not (Test-Path -LiteralPath $exampleConfig)) { Stop-Install "Configuration not found: $ConfigPath" 'Use the supplied V2 example or correct -ConfigPath.' 3 }
        $ConfigPath=$exampleConfig
    }
    $script:Config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int](Get-Value $script:Config 'SchemaVersion' 0) -ne 2) { Stop-Install 'V2 requires configuration SchemaVersion 2.' 'Use SkyrimMods.config.example.json as the V2 base; migrate applicable package/choice pins after reviewing them.' 3 }
    $gameExe=Join-Path $script:GameRoot 'SkyrimSE.exe'
    if (-not (Test-Path -LiteralPath $gameExe) -or -not (Test-Path -LiteralPath $script:DataPath)) { Stop-Install 'SkyrimSE.exe/Data were not found.' 'Point -GamePath to the Steam Skyrim Special Edition installation.' 3 }
    $fileVersion=(Get-Item -LiteralPath $gameExe).VersionInfo
    $script:Runtime=New-Object version($fileVersion.FileMajorPart,$fileVersion.FileMinorPart,$fileVersion.FileBuildPart,$fileVersion.FilePrivatePart)
    $script:OriginalGameHash=Get-Hash $gameExe
    $expected=[version](Get-Value $script:Config 'ExpectedRuntime' '1.7.104.0')
    if ($script:Runtime -ne $expected) { Stop-Install "Runtime changed: found $script:Runtime, reviewed setup expects $expected." 'Recheck SKSE and every native DLL against the new runtime, then explicitly update ExpectedRuntime and compatibility evidence. No automatic downgrade or executable renaming is performed.' 3 }
    $list=Join-Path $PSScriptRoot 'Install order.txt'
    if (-not (Test-Path -LiteralPath $list)) { Stop-Install 'Install order.txt is missing.' 'Keep the original install list beside this installer.' 3 }
    $activeList=Get-ActiveInstallList (Get-Content -LiteralPath $list -Raw -Encoding UTF8)
    $script:ListHash=Get-TextHash $activeList.Text
    $expectedList=[string](Get-Value $script:Config 'InstallListSha256' '')
    if ([string](Get-Value $script:Config 'InstallListVersion' '') -ne 'V2' -or -not $expectedList -or $expectedList -ne $script:ListHash) { Stop-Install 'Active V2 list differs from the reviewed installer configuration.' 'Review the V2 catalogue/order, then set InstallListVersion: V2 and pin the normalized V2 section hash in InstallListSha256. Historical V1 text does not affect this hash.' 3 }
    if ([string](Get-Value $script:Config 'RenderingFramework' '') -ne 'CommunityShaders' -or
        [string](Get-Value $script:Config 'LuxCsVariant' '') -ne 'Non-Effects11' -or
        (Get-Value $script:Config 'Effects11' $true) -isnot [bool] -or (Get-Value $script:Config 'Effects11' $true)) {
        Stop-Install 'V2 requires CommunityShaders, Non-Effects11 Lux CS and Effects11: false.' 'Keep the reviewed V2 rendering configuration; NAT.CS III excludes Effects11.' 3
    }
    $script:Catalogue=@(Get-Catalogue)
    $script:TerrainStrategy=[string](Get-Value $script:Config 'TerrainStrategy' 'TerrainHelper')
    if ($script:TerrainStrategy -ne 'TerrainHelper') { Stop-Install 'This install list requires the Terrain Helper setup.' 'Set TerrainStrategy to TerrainHelper. The legacy terrain route has been removed from this installer.' 3 }
    $overrides=Get-Value $script:Config 'Packages' @{}
    $names=if ($overrides -is [Collections.IDictionary]) { @($overrides.Keys) } else { @($overrides.PSObject.Properties | ForEach-Object { $_.Name }) }
    $allPackageIds=@((Get-Catalogue).Id)
    foreach ($name in $names) { if ($name -notin $allPackageIds) { Stop-Install "Unknown package override: $name" 'Correct the package id; Plan displays every valid id.' 3 } }
}

function Initialize-Work {
    Assert-OrdinaryDirectory $script:WorkRoot
    Assert-OrdinaryDirectory $script:GameRoot
    Assert-FreeSpace $script:WorkRoot ([double](Get-Value $script:Config 'MinimumWorkFreeGiB' 160)) 'archives, extraction, staging and generators'
    foreach ($path in @($script:WorkRoot,$script:DownloadPath,$script:ExtractPath,$script:ToolPath,$script:GeneratedPath)) { New-Directory $path | Out-Null }
    $script:RunId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $script:RunLogPath=New-Directory (Join-Path (New-Directory (Join-Path $script:WorkRoot 'Logs')) $script:RunId)
    $script:LogPath=Join-Path $script:RunLogPath 'installer.log'
    $script:StagePath=New-Directory (Join-Path (New-Directory (Join-Path $script:WorkRoot 'Staged')) $script:RunId)
    foreach ($pair in @(@('Lock',$script:LockPath),@('Choices',$script:ChoicesPath),@('Generated',$script:GeneratedStatePath),@('OwnedGenerated',$script:OwnedPath))) {
        if (Test-Path -LiteralPath $pair[1]) { Set-Variable -Name $pair[0] -Scope Script -Value (ConvertTo-Map (Get-Content -LiteralPath $pair[1] -Raw -Encoding UTF8 | ConvertFrom-Json)) }
    }
    $bindingPath=Join-Path $script:WorkRoot 'workspace.binding.json'
    if (Test-Path -LiteralPath $bindingPath) {
        $binding=Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
        if ($binding.GamePath -ne $script:GameRoot -or $binding.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            Stop-Install 'WorkPath belongs to a different game installation or Windows user.' 'Use a new dedicated WorkPath. Run under the same Windows account that uses Steam; UAC elevation of that account is fine.' 3
        }
    } else { Write-Json $bindingPath @{GamePath=$script:GameRoot;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value} }
    Write-Status "Mode: $Mode; runtime: $script:Runtime; logs: $script:RunLogPath"
    Write-Status "Work folder: $script:WorkRoot; mod archives: $script:DownloadPath"
}

function Invoke-Preparation {
    Set-Phase 'Preparing archives and exact install options (no game files changed)'
    Initialize-Nexus
    Initialize-Extractor
    foreach ($name in @(Get-ProfilePlugins)) { $script:PlannedPlugins[$name]=$true }
    foreach ($package in $script:Catalogue) { foreach ($name in $package.Provides) { $script:PlannedPlugins[$name]=$true } }
    $number=0
    foreach ($package in $script:Catalogue) {
        $number++; $script:Package=$package.Id
        Write-Status ('[{0}/{1}] {2} ({3})' -f $number,$script:Catalogue.Count,$package.Name,$package.Id)
        $record=Get-Archive $package
        $extracted=Expand-ArchiveChecked $record $package.Id
        $payload=Stage-Package $package $record $extracted
        $script:Payloads.Add($payload)
        Write-Status ('Staged '+$package.Id) 'OK'
    }
    # Look-ahead names are only for FOMOD dependency visibility. Validate the actual
    # selected plugins, not guessed filenames from human-readable mod names.
    $script:PlannedPlugins=@{}
    foreach ($name in @(Get-ProfilePlugins)) { $script:PlannedPlugins[$name]=$true }
    foreach ($payload in $script:Payloads) {
        foreach ($file in @(Get-ChildItem -LiteralPath $payload.Data -File | Where-Object { $_.Extension -in @('.esm','.esp','.esl') })) { $script:PlannedPlugins[$file.Name]=$true }
    }
    $script:BaseOrder=@(Resolve-PluginOrder @($script:PlannedPlugins.Keys | Sort-Object) (Get-PluginMap -Staged))
    Assert-NativeCompatibility
    foreach ($id in @('loot','pgpatcher','xlodgen','dyndolod-tools')) {
        $names=switch ($id) { 'loot' { @('LOOT.exe') } 'pgpatcher' { @('PGPatcher.exe','ParallaxGen.exe') } 'xlodgen' { @('xLODGenx64.exe') } 'dyndolod-tools' { @('DynDOLODx64.exe') } }
        Assert-Pe64 (Get-Tool $id $names)
    }
    Assert-Pe64 (Get-Tool 'dyndolod-tools' @('TexGenx64.exe'))
    $lockDigest=(@($script:Lock.Keys | Sort-Object | ForEach-Object { $_+':'+(Get-Value $script:Lock[$_] 'Sha256' '') }) -join '|')
    $script:InputSignature=Get-TextHash ($script:OriginalGameHash+'|'+$script:ListHash+'|'+$lockDigest+'|'+(ConvertTo-CanonicalJson $script:Choices)+'|'+(ConvertTo-CanonicalJson $script:Config))
    Write-Json (Join-Path $script:WorkRoot 'prepared.json') @{InputSignature=$script:InputSignature;StagePath=$script:StagePath;Runtime=$script:Runtime.ToString();Packages=$script:Payloads.Count;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    Write-Status 'All packages staged, dependencies checked, and installation choices saved' 'OK'
}

function Invoke-Installation {
    Assert-NotRunning
    Assert-CompatibilityDecisions
    Assert-NoElevationLayers
    Assert-NoChildLinks $script:GameRoot
    Assert-OrdinaryDirectory $script:IniPath
    Assert-OrdinaryDirectory $script:ProfilePath
    foreach ($name in @('Skyrim.ini','SkyrimPrefs.ini')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:IniPath $name))) { Stop-Install "$name was not initialized for this Windows user." 'Before installing, start unmodified Skyrim once through Steam and exit. Then rerun under that same Windows account. The installer never starts Skyrim automatically.' 3 }
    }
    if ($script:OwnedGenerated.Count -and -not $Resume) { Stop-Install 'A previous installation has generated outputs.' 'Use -Resume to safely remove individually owned generated files, replay base assets and reuse only matching verified checkpoints.' 3 }
    $total=0L
    foreach ($payload in $script:Payloads) { foreach ($file in @(Get-ChildItem -LiteralPath $payload.Data,$payload.Root -Recurse -File)) { $total+=$file.Length } }
    Assert-FreeSpace $script:GameRoot ([Math]::Max([double](Get-Value $script:Config 'MinimumGameFreeGiB' 80),$total/1GB+20)) 'direct Data install and LOD output'
    $test=Join-Path $script:GameRoot ('.installer-write-test-'+[guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($test,'permission check'); Remove-Item -LiteralPath $test -Force }
    catch { Stop-Install 'Cannot write to the Skyrim installation directory.' 'Open PowerShell as administrator under the SAME Steam Windows account, or grant that account write access to this game directory.' 5 }
    $vc='HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    if (-not (Test-Path $vc) -or [int](Get-Value (Get-ItemProperty $vc -ErrorAction SilentlyContinue) 'Installed' 0) -ne 1) {
        Stop-Install 'Microsoft Visual C++ 2015-2022 x64 runtime is missing.' 'Install the official x64 redistributable: https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist . Then resume; this installer does not silently install machine-wide prerequisites.' 3
    }
    Build-SteamBridge
    # Prevent an existing bridge from launching a partially replaced setup.
    $receipt=Join-Path $script:GameRoot 'SteamSkyrimBridge.json'
    if (Test-Path -LiteralPath $receipt) { Write-Json $receipt @{SchemaVersion=2;Pending=$true;Reason='Installation in progress or interrupted; rerun Install -Resume.'} }
    $script:DataTouched=$true
    Write-Json $script:StatePath @{Status='Installing';InputSignature=$script:InputSignature;Log=$script:LogPath}
    Clear-OwnedGenerated
    # Discard previous generated plugin names after clearing their owned files.
    $script:PlannedPlugins=@{}
    foreach ($name in $script:BaseOrder) { if (Test-Path -LiteralPath (Join-Path $script:DataPath $name)) { $script:PlannedPlugins[$name]=$true } }
    Set-Phase 'Deploying base assets in the requested overwrite order'
    foreach ($payload in $script:Payloads) {
        $script:Package=$payload.Package.Id
        if ($payload.Package.Kind -eq 'Tool') { continue }
        Write-Status ('Installing '+$payload.Package.Name)
        Copy-Tree $payload.Data $script:DataPath ('Install '+$payload.Package.Id)
        Copy-Tree $payload.Root $script:GameRoot ('Install root '+$payload.Package.Id)
        foreach ($file in @(Get-ChildItem -LiteralPath $payload.Data -File | Where-Object { $_.Extension -in @('.esm','.esp','.esl') })) { $script:PlannedPlugins[$file.Name]=$true }
    }
    Write-PluginOrder (Resolve-PluginOrder @($script:PlannedPlugins.Keys | Sort-Object) (Get-PluginMap))
    Configure-Inis
    Sort-Plugins
    Set-GenerationSignature
    # Native files already checked in staging; original game executable must remain intact.
    if ((Get-Hash (Join-Path $script:GameRoot 'SkyrimSE.exe')) -ne $script:OriginalGameHash) { Stop-Install 'SkyrimSE.exe changed during installation.' 'Stop Steam updates/file verification and re-review the runtime before resuming.' 8 }
    Run-Generator 'PGPatcher' 'pgpatcher' @('PGPatcher.exe','ParallaxGen.exe') @'
Set game type Skyrim Special Edition (SSE), game path to the Steam Skyrim folder,
conflict/mod manager to None (direct install), output to the fresh folder above,
and disable ZIP output. Enable complex-material/parallax patching compatible with
Community Shaders Extended Materials for these assets; leave True PBR conversion off.
Run Start Patching and review all errors. Close only after successful completion.
'@
    Sort-Plugins
    $script:InputSignature=Get-TextHash ($script:InputSignature+'|'+($script:ActiveOrder -join '|'))
    Run-Generator 'xLODGen' 'xlodgen' @('xLODGenx64.exe') @'
Select the required worldspaces. TERRAIN LOD ONLY: disable Objects and Trees.
Generate terrain meshes and diffuse/normal textures. Use the shown fresh output.
Review https://dyndolod.info/Help/xLODGen for quality/LOD-level settings.
'@
    Run-Generator 'TexGen' 'dyndolod-tools' @('TexGenx64.exe') @'
Generate LOD textures and tree billboards using the finalized installed assets.
Use the shown fresh output. Choose appropriate resolutions for your GPU/VRAM.
Review https://dyndolod.info/Help/TexGen for the official current options.
'@
    Run-Generator 'DynDOLOD' 'dyndolod-tools' @('DynDOLODx64.exe') @'
Use SSE and the required worldspaces; generate final object and tree LOD.
PGPatcher, terrain and TexGen outputs have already been installed. Use the shown
fresh output. Use High preset where practical and the DLL NG/large-reference
settings supported by the installed author version. Resolve all reported errors.
Review https://dyndolod.info/Help/DynDOLOD for the official current options.
'@
    Sort-Plugins
    Assert-FinalGenerationOrder
    Install-SteamBridge
    Write-Json $script:StatePath @{Status='Complete';InputSignature=$script:InputSignature;Log=$script:LogPath;CompletedUtc=[DateTime]::UtcNow.ToString('o');RemotePlayTested=$false}
    Write-Status 'Installation and static launch-chain checks complete. Live Steam/Remote Play testing is still required.' 'OK'
}

# This is the only entry point. Plan performs no downloads, directory creation,
# tool execution, game launches, or writes to Skyrim/profile/configuration.
try {
    Initialize-Paths
    if ($Mode -eq 'Plan') {
        Write-Status "READ-ONLY PLAN: Skyrim $script:Runtime; $($script:Catalogue.Count) packages including required dependencies/tools"
        foreach ($package in $script:Catalogue) { Write-Host ('  {0,7:g}  {1,-25} {2}' -f $package.Order,$package.Id,$package.Name) }
        Write-Status 'Install order: base mods -> LOOT -> PGPatcher -> LOOT -> xLODGen terrain -> TexGen -> DynDOLOD -> LOOT -> Steam bridge'
        Write-Status 'V2 rendering order: NAT weather ESP -> Community Shaders -> Skylighting -> NAT.CS III -> Light Placer -> ISL Helper -> Lux Orbis -> Lux -> Non-Effects11 Lux CS'
        Write-Status 'Nexus Premium/API key enables automatic downloads; free accounts supply browser-downloaded archives. FOMOD choices and first-time generation remain guided.'
        Write-Status ("Terrain strategy: $script:TerrainStrategy. Cloud Shadows is bundled in CS; Skylighting and terrain feature configs install separately. Native DLLs require reviewed runtime evidence.")
        Write-Status 'No files changed and no tools/game launched.' 'OK'
    } else {
        Assert-CompatibilityDecisions
        $script:Mutex=New-Object Threading.Mutex($false,('Local\SkyrimModInstaller-'+(Get-TextHash $script:GameRoot).Substring(0,24)))
        try { $script:MutexOwned=$script:Mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:MutexOwned=$true }
        if (-not $script:MutexOwned) { Stop-Install 'Another installer is using this Skyrim directory.' 'Wait for it to finish; do not run concurrent installs.' 3 }
        Assert-NotRunning
        Initialize-Work
        Invoke-Preparation
        if ($Mode -eq 'Install') { Invoke-Installation }
        else { Write-Status 'Prepare complete. Skyrim and its Steam launcher have NOT been modified.' 'OK' }
    }
    $script:ExitCode=0
} catch {
    $reason=Protect-Message $_.Exception.Message
    $remedy=[string]$_.Exception.Data['Remedy']
    if (-not $remedy) { $remedy='Inspect the detailed failure log and failing line below. Fix permissions, disk space, malformed configuration, or the reported package/tool error before rerunning.' }
    Write-Status ("FAILED in phase '$script:Phase', package '$script:Package': $reason") 'FAIL'
    Write-Status ('Next step: '+$remedy) 'FAIL'
    if ($script:LogPath) {
        $detail=Protect-Message ($_ | Out-String)
        try {
            [IO.File]::AppendAllText($script:LogPath,[Environment]::NewLine+$detail+([string]$_.ScriptStackTrace)+[Environment]::NewLine)
            Write-Json (Join-Path $script:RunLogPath 'failure.json') @{Phase=$script:Phase;Package=$script:Package;Reason=$reason;Remedy=$remedy;ExitCode=$script:ExitCode;Line=$_.InvocationInfo.ScriptLineNumber;GameDataMayBePartial=[bool](Get-Variable 'DataTouched' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)}
        } catch { Write-Host ('Detailed failure report could not be written: '+$_.Exception.Message) -ForegroundColor Yellow }
        Write-Host ('Detailed log: '+$script:LogPath) -ForegroundColor Yellow
    }
    if ([bool](Get-Variable 'DataTouched' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        Write-Host 'Do not launch Skyrim after an interrupted Install. Correct the reported problem and rerun with -Mode Install -Resume.' -ForegroundColor Yellow
    } else {
        Write-Host 'Stopped before game deployment. Correct the error and rerun with the same -WorkPath; cached downloads will be reused.' -ForegroundColor Yellow
    }
} finally {
    if ($script:MutexOwned) { $script:Mutex.ReleaseMutex() }
    if ($null -ne $script:Mutex) { $script:Mutex.Dispose() }
    $script:ApiKey=$null
}
exit $script:ExitCode
