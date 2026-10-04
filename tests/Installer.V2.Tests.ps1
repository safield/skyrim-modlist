#requires -Version 5.1
# Offline regression tests. Never invoke the installer entrypoint or bridge Main.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository=Split-Path -Parent $PSScriptRoot
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Install-SkyrimMods.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false))) {
    Invoke-Expression $definition.Extent.Text
}
$temporaryRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$scratch=Join-Path $temporaryRoot ('SkyrimInstallerV2Tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$script:ApiKey=''; $script:LogPath=$null; $script:Phase='tests'; $script:Package=''
$script:Runtime=[version]'1.7.104.0'
$script:WorkRoot=$scratch; $script:RunLogPath=New-Directory (Join-Path $scratch 'Logs')
$script:GameRoot=New-Directory (Join-Path $scratch 'Game')
$script:DataPath=New-Directory (Join-Path $script:GameRoot 'Data')
$script:IniPath=New-Directory (Join-Path $scratch 'Ini')
$script:StagePath=New-Directory (Join-Path $scratch 'Stage')
$script:ChoicesPath=Join-Path $scratch 'choices.json'
$script:Config=@{Packages=@{}; FomodSelections=@{}}
$script:Choices=@{}; $script:PlannedPlugins=@{}; $script:Payloads=@()
$NonInteractive=$true
$script:TestsPassed=0

function Assert-Equal($Actual,$Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', received '$Actual'." }
}
function Assert-Rejected([scriptblock]$Action,[string]$Reason) {
    $rejected=$false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Reason) { throw "Wrong rejection: $($_.Exception.Message); expected '$Reason'." }
        $rejected=$true
    }
    if (-not $rejected) { throw "Expected rejection matching '$Reason'." }
}
function Test-Case([string]$Name,[scriptblock]$Action) {
    & $Action
    $script:TestsPassed++
    Write-Host "PASS $Name" -ForegroundColor Green
}
function Write-Fixture([string]$Path,[string]$Content='fixture') {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function New-MinimalPe([string]$Path) {
    # Only a PE header for architecture-validation tests; never loaded/executed.
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[0x3c]=0x80
    $bytes[0x80]=0x50; $bytes[0x81]=0x45; $bytes[0x84]=0x64; $bytes[0x85]=0x86
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path,$bytes)
}

try {
    $list=Get-Content -LiteralPath (Join-Path $repository 'Install order.txt') -Raw -Encoding UTF8
    $defaults=Get-Content -LiteralPath (Join-Path $repository 'SkyrimMods.config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Case 'V2 extraction and pin ignore historical V1 and line endings' {
        $active=Get-ActiveInstallList $list
        Assert-Equal $active.Entries.Count 31
        Assert-Equal (Get-TextHash $active.Text) $defaults.InstallListSha256
        $historicalEdit=$list.Replace('V1','V1 historical edit').Replace([Environment]::NewLine,[string][char]10)
        Assert-Equal (Get-TextHash (Get-ActiveInstallList $historicalEdit).Text) $defaults.InstallListSha256
        $changed=$list.Replace('Current official version is 1.9.1','Current official version is 1.9.2')
        if ((Get-TextHash (Get-ActiveInstallList $changed).Text) -eq $defaults.InstallListSha256) { throw 'Active V2 edit did not change its hash.' }
    }
    Test-Case 'Missing, duplicate and misnumbered V2 are rejected' {
        Assert-Rejected { Get-ActiveInstallList ($list.Replace('V2 USE THIS ONE','V2 old')) } 'exactly one'
        Assert-Rejected { Get-ActiveInstallList ($list+[Environment]::NewLine+'V2 USE THIS ONE') } 'exactly one'
        Assert-Rejected { Get-ActiveInstallList ($list.Replace('31. DynDOLOD','30. DynDOLOD')) } 'missing, repeated or out of order'
    }
    $catalogue=@(Get-Catalogue)
    Test-Case 'V2 rendering and generator catalogue order excludes old ENB packages' {
        $ids=@($catalogue.Id)
        foreach ($id in @('enb-binaries','cabbage','sh2-shader-core','kil-loader','enb-extender','evlas','enb-blending-fix','water-cabbage','cloud-shadows')) {
            if ($id -in $ids) { throw "Unexpected V1/bundled package: $id" }
        }
        $expected=@{nat=19; 'community-shaders'=20; skylighting=21; 'nat-cs'=22; 'light-placer'=23; 'isl-helper'=24; 'lux-orbis'=25; lux=26; 'lux-cs'=27; pgpatcher=28; xlodgen=29; 'dyndolod-tools'=30}
        foreach ($id in $expected.Keys) {
            $found=@($catalogue | Where-Object Id -eq $id)
            Assert-Equal $found.Count 1
            Assert-Equal $found[0].Order ([double]$expected[$id])
        }
        Assert-Equal (@($catalogue | Where-Object Id -eq 'nat')[0].Pattern -match [regex]::Escape('3\.1\.1C')) $true
        Assert-Equal (@($ids | Select-Object -Unique).Count) $ids.Count
    }
    Test-Case 'Atomic JSON rewrites work on Windows PowerShell 5.1' {
        $file=Join-Path $scratch 'atomic.json'
        Write-Json $file @{Version=1}
        Write-Json $file @{Version=2}
        Assert-Equal (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Version 2
        Assert-Equal (Test-Path -LiteralPath ($file+'.writing')) $false
    }
    Test-Case 'Redirected processes return numeric success and failure exit codes on PowerShell 5.1' {
        foreach ($expected in @(0,37)) {
            $child="[Console]::Out.WriteLine('stdout fixture'); [Console]::Error.WriteLine('stderr fixture'); exit $expected"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
            $stdout=Join-Path $scratch ('child-'+$expected+'.out')
            $stderr=Join-Path $scratch ('child-'+$expected+'.err')
            $result=Invoke-Process (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -EncodedCommand '+$encoded) 'Redirected process fixture' $scratch -OutputLog $stdout -ErrorLog $stderr
            if ($result -isnot [int]) { throw 'Process result must be an integer, including zero.' }
            Assert-Equal $result $expected
            Assert-Equal ([IO.File]::ReadAllText($stdout).Trim()) 'stdout fixture'
            Assert-Equal ([IO.File]::ReadAllText($stderr).Trim()) 'stderr fixture'
        }
    }
    Test-Case 'Download monitor reports bytes, speed and elapsed time while its process is running' {
        $watch=Join-Path $scratch 'progress.partial'
        $script:LogPath=Join-Path $scratch 'progress.log'
        $child="[IO.File]::WriteAllBytes('"+$watch.Replace("'","''")+"',(New-Object byte[] 1048576)); Start-Sleep -Seconds 6; exit 0"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        try {
            $result=Invoke-Process (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -EncodedCommand '+$encoded) 'Download monitor fixture' $scratch -WatchFile $watch -ErrorLog (Join-Path $scratch 'progress.err')
            Assert-Equal $result 0
            if ([IO.File]::ReadAllText($script:LogPath) -notmatch '1.0 MiB on disk; .*MiB/s; elapsed') { throw 'Expected visible download progress was missing.' }
        } finally { $script:LogPath=$null }
    }
    Test-Case 'Local Nexus key is read and pasted control/mask characters fail before HTTP' {
        $script:ApiKey=''
        $script:Config=@{NexusApiKey='***'}
        Assert-Rejected { Initialize-Nexus } 'masking characters'
        $script:ApiKey=''
        $script:Config=@{NexusApiKey=('abc'+[char]10+'def')}
        Assert-Rejected { Initialize-Nexus } 'control characters'
        $script:ApiKey=''
        $script:Config=@{Packages=@{};FomodSelections=@{}}
    }
    $lux=@($catalogue | Where-Object Id -eq 'lux-cs')[0]
    $fomodRoot=New-Directory (Join-Path $scratch 'LuxFomod')
    $fomodFile=Join-Path $fomodRoot 'fomod\ModuleConfig.xml'
    Write-Fixture (Join-Path $fomodRoot 'non.txt') 'non-effects variant'
    Write-Fixture (Join-Path $fomodRoot 'effects.txt') 'effects variant'
    $xml=@'
<config><moduleName>Lux CS fixture</moduleName><installSteps order="Explicit">
<installStep name="Lux CS"><optionalFileGroups order="Explicit">
<group name="Rendering variant" type="SelectExactlyOne"><plugins order="Explicit">
<plugin name="Effects11"><files><file source="effects.txt" destination="selected.ini"/></files></plugin>
<plugin name="Non-Effects11"><files><file source="non.txt" destination="selected.ini"/></files></plugin>
</plugins></group></optionalFileGroups></installStep></installSteps></config>
'@
    Write-Fixture $fomodFile $xml
    Test-Case 'Lux CS FOMOD selects only Non-Effects11 without prompting' {
        $output=New-Directory (Join-Path $scratch 'LuxGood')
        Stage-Fomod $lux $fomodRoot $fomodFile $output
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $output 'selected.ini'))) 'non-effects variant'
        Assert-Equal $script:Choices['lux-cs/Lux CS/Rendering variant'][0] 'Non-Effects11'
    }
    Test-Case 'Saved Effects11 and old unidentifiable Lux variants are rejected' {
        $script:Choices=@{}
        $script:Config.FomodSelections=@{'lux-cs/Lux CS/Rendering variant'=@('Effects11')}
        Assert-Rejected { Stage-Fomod $lux $fomodRoot $fomodFile (New-Directory (Join-Path $scratch 'LuxBad')) } 'conflicts with NAT.CS'
        $script:Config.FomodSelections=@{}
        Write-Fixture $fomodFile ($xml.Replace('Non-Effects11','Legacy standard').Replace('<plugin name="Effects11"><files><file source="effects.txt" destination="selected.ini"/></files></plugin>',''))
        Assert-Rejected { Stage-Fomod $lux $fomodRoot $fomodFile (New-Directory (Join-Path $scratch 'LuxOld')) } 'did not select'
        Write-Fixture $fomodFile $xml
    }
    Test-Case 'Plain Lux CS payload requires explicit Non-Effects11 review and a current version' {
        $plain=New-Directory (Join-Path $scratch 'PlainLux')
        Write-Fixture (Join-Path $plain 'Shaders\test.hlsl')
        $record=[pscustomobject]@{Version='2.6.0'}
        Assert-Rejected { Stage-Package $lux $record $plain } 'explicit reviewed variant'
        Assert-Rejected { Stage-Package $lux ([pscustomobject]@{Version='2.5.0'}) $plain } 'older than'
        Assert-Rejected { Stage-Package $lux ([pscustomobject]@{Version='manual'}) $plain } 'Unknown version'
    }
    Test-Case 'Shader-only archive root is recognized and required core features are enforced' {
        $features=New-Directory (Join-Path $scratch 'Core')
        foreach ($name in @('CloudShadows','ExtendedMaterials','InverseSquareLighting')) { Write-Fixture (Join-Path $features ('Shaders\Features\'+$name+'.ini')) }
        Write-Fixture (Join-Path $features 'SKSE\Plugins\CommunityShaders.dll')
        $core=@($catalogue | Where-Object Id -eq 'community-shaders')[0]
        Assert-Equal (Find-PayloadRoot $core $features) $features
        Assert-ShaderPayload $core $features
        $cloud=Join-Path $features 'Shaders\Features\CloudShadows.ini'
        Remove-Item -LiteralPath $cloud
        Assert-Rejected { Assert-ShaderPayload $core $features } 'CloudShadows'
        Write-Fixture $cloud
        Write-Fixture (Join-Path $features 'Shaders\Features\Effects11.ini')
        Assert-Rejected { Assert-ShaderPayload $core $features } 'excluded by V2'
        $onlyShader=New-Directory (Join-Path $scratch 'SkylightingArchive')
        Write-Fixture (Join-Path $onlyShader 'Shaders\Features\Skylighting.ini')
        $sky=@($catalogue | Where-Object Id -eq 'skylighting')[0]
        Assert-Equal (Find-PayloadRoot $sky $onlyShader) $onlyShader
        Assert-ShaderPayload $sky $onlyShader
    }
    Test-Case 'Terrain feature version must match CS core even for a supplied archive' {
        $core=@($catalogue | Where-Object Id -eq 'community-shaders')[0]
        $script:Payloads=@([pscustomobject]@{Package=$core;Record=[pscustomobject]@{Version='1.9.1'}})
        $feature=@($catalogue | Where-Object Id -eq 'cs-terrain-helper')[0]
        Assert-Rejected { Stage-Package $feature ([pscustomobject]@{Version='1.8.0'}) $scratch } 'versions differ'
        $matching=New-Directory (Join-Path $scratch 'MatchingTerrain')
        Write-Fixture (Join-Path $matching 'Shaders\Features\TerrainHelper.ini')
        $payload=Stage-Package $feature ([pscustomobject]@{Version='1.9.1.0'}) $matching
        Assert-Equal (Test-Path -LiteralPath (Join-Path $payload.Data 'Shaders\Features\TerrainHelper.ini')) $true
        $script:Payloads=@()
    }
    Test-Case 'Existing Effects11 stops before deployment; INI configuration creates no ENB file' {
        $effects=Join-Path $script:DataPath 'Shaders\Features\Effects11.ini'
        Write-Fixture $effects
        Assert-Rejected { Assert-CompatibilityDecisions } 'conflicts with V2'
        Remove-Item -LiteralPath $effects
        foreach ($name in @('Skyrim.ini','SkyrimPrefs.ini')) { Write-Fixture (Join-Path $script:IniPath $name) '[Display]' }
        Configure-Inis
        Assert-Equal (Test-Path -LiteralPath (Join-Path $script:GameRoot 'enbseries.ini')) $false
    }
    $launchFiles=@('SkyrimSE.exe','skse64_loader.exe','skse64_1_7_104.dll','Data\SKSE\Plugins\CommunityShaders.dll')
    foreach ($name in @('CloudShadows','ExtendedMaterials','InverseSquareLighting','Skylighting','TerrainHelper','TerrainBlending')) { $launchFiles+='Data\Shaders\Features\'+$name+'.ini' }
    foreach ($relative in $launchFiles) { Write-Fixture (Join-Path $script:GameRoot $relative) }
    Test-Case 'Generator signatures work without ENB and invalidate changed shader settings' {
        $script:ActiveOrder=@('Skyrim.esm'); $script:InputSignature='base'
        Set-GenerationSignature
        $before=$script:InputSignature
        Write-Fixture (Join-Path $script:DataPath 'Shaders\Features\Skylighting.ini') 'changed shader settings'
        $script:InputSignature='base'
        Set-GenerationSignature
        if ($script:InputSignature -eq $before) { throw 'Shader settings change failed to invalidate generation.' }
        Assert-Equal (@(Get-LaunchFiles | Where-Object { $_ -match '(?i)d3d11|enbseries' }).Count) 0
    }
    Test-Case 'Unknown and outdated native DLLs still fail compatibility validation' {
        $native=Join-Path $scratch 'Native'
        $address=Join-Path $scratch 'Address'
        New-MinimalPe (Join-Path $native 'SKSE\Plugins\CommunityShaders.dll')
        Write-Fixture (Join-Path $address 'SKSE\Plugins\versionlib-1-7-104-0.bin')
        $core=@($catalogue | Where-Object Id -eq 'community-shaders')[0]
        $script:Payloads=@(
            [pscustomobject]@{Package=$core;Record=[pscustomobject]@{Version='1.9.1'};Data=$native},
            [pscustomobject]@{Package=@($catalogue | Where-Object Id -eq 'address-library')[0];Record=[pscustomobject]@{Version='x'};Data=$address}
        )
        $script:Config.NativeCompatibility=@{}
        Assert-Rejected { Assert-NativeCompatibility } 'Unreviewed native'
        $script:Config.NativeCompatibility=$defaults.NativeCompatibility
        $script:Payloads[0].Record.Version='1.8.0'
        Assert-Rejected { Assert-NativeCompatibility } 'too old'
        $script:Payloads[0].Record.Version='1.9.1'
        Assert-NativeCompatibility
        $script:Payloads=@()
    }
    $bridge=Join-Path $scratch 'SteamSkyrimBridge.exe'
    Test-Case 'Steam bridge compiles with its manifest; its Main is never executed' {
        [xml](Get-Content -LiteralPath (Join-Path $repository 'SteamSkyrimBridge.manifest') -Raw) | Out-Null
        $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $compiler /nologo /target:winexe /platform:x64 /optimize+ ('/out:'+$bridge) ('/win32manifest:'+(Join-Path $repository 'SteamSkyrimBridge.manifest')) /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll (Join-Path $repository 'SteamSkyrimBridge.cs')
        if ($LASTEXITCODE -ne 0) { throw 'Bridge compilation failed.' }
        Assert-Pe64 $bridge
    }
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($bridge))
    $validator=$assembly.GetType('SteamSkyrimBridge').GetMethod('ValidateReceipt',[Reflection.BindingFlags]'Static,NonPublic')
    $hashes=@{}
    foreach ($relative in @(Get-LaunchFiles)) { $hashes[$relative]=Get-Hash (Join-Path $script:GameRoot $relative) }
    $receipt=@{SchemaVersion=2;InstallListVersion='V2';RenderingFramework='CommunityShaders';SteamAppId='489830';Runtime='1.7.104';Hashes=$hashes}
    function Invoke-Receipt($Value) {
        $arguments=New-Object object[] 2
        $arguments[0]=[string]$script:GameRoot
        $arguments[1]=[string](ConvertTo-Json -InputObject $Value -Depth 10)
        return $validator.Invoke($null,$arguments)
    }
    Test-Case 'V2 launch receipt accepts nested CS files without ENB binaries' {
        Assert-Equal (Invoke-Receipt $receipt) '1.7.104'
    }
    Test-Case 'Bridge rejects changed native files, traversal, pending and legacy receipts' {
        $coreDll=Join-Path $script:DataPath 'SKSE\Plugins\CommunityShaders.dll'
        Write-Fixture $coreDll 'changed'
        Assert-Rejected { Invoke-Receipt $receipt } 'changed or is missing'
        Write-Fixture $coreDll
        $receipt.Hashes['..\escape.dll']='x'
        Assert-Rejected { Invoke-Receipt $receipt } 'Invalid receipt file path'
        $receipt.Hashes.Remove('..\escape.dll')
        $receipt.Pending=$true
        Assert-Rejected { Invoke-Receipt $receipt } 'interrupted'
        $receipt.Remove('Pending')
        $receipt.SchemaVersion=1
        Assert-Rejected { Invoke-Receipt $receipt } 'V2 mod installation receipt'
        $receipt.SchemaVersion=2
    }
    Test-Case 'Bridge refuses an Effects11 feature added after installation' {
        $effects=Join-Path $script:DataPath 'Shaders\Features\Effects11.ini'
        Write-Fixture $effects
        Assert-Rejected { Invoke-Receipt $receipt } 'conflicts with V2'
        Remove-Item -LiteralPath $effects
    }
    Write-Host "$script:TestsPassed offline regression checks passed; no game or Steam process was launched." -ForegroundColor Green
} finally {
    # Resolve and verify the exact temporary child before this one recursive cleanup.
    $resolved=[IO.Path]::GetFullPath($scratch)
    if (-not $resolved.StartsWith($temporaryRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^SkyrimInstallerV2Tests-[a-f0-9]{32}$') {
        throw 'Refusing cleanup outside the dedicated test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
