param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory = '.\test-evidence'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Update-channel gates require Windows PowerShell 5.1.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw ('FAILED update channel: '+$Name)}
    Write-Host ('PASS update channel: '+$Name)
}
$root=Join-Path $env:TEMP ('TqrUpdateChannel-'+[Guid]::NewGuid().ToString('N'))
$fixtureKey='HKCU:\Software\TailscaleQuickRepair-ChannelTest-'+[Guid]::NewGuid().ToString('N')
$passed=$false
try{
    New-Item -ItemType Directory -Path $root|Out-Null
    $ordinary=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File|Where-Object Name -notlike '*SetupPackage*')
    Check ($ordinary.Count -eq 1) 'One exact ordinary package is available'
    Expand-Archive -LiteralPath $ordinary[0].FullName -DestinationPath $root
    $uiPath=Join-Path $root 'app\Tailscale-Repair-UI.ps1'
    $ui=[IO.File]::ReadAllText($uiPath)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Delivered channel-aware UI parses on Windows PowerShell 5.1'
    Check ($ui.Contains('x:Name="EarlyAccessUpdatesCheckBox"') -and $ui.Contains('Release candidates before the public channel. Opt-in only.')) 'Delivered Maintenance UI exposes compact opt-in Early-access updates'
    Check ($ui.Contains('updates/latest.json?ref=main') -and $ui.Contains('updates/preview.json?ref=preview') -and $ui.Contains("'--channel'") -and $ui.Contains("'--target-code'") -and $ui.Contains('$script:updateManifestChannel')) 'Delivered UI binds the native updater to fixed channel and target identity'

    foreach($name in @('Get-UpdateChannel','Set-UpdateChannel','Get-UpdateManifestApiUrl')){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Check ($nodes.Count -eq 1) ('Delivered UI has one '+$name)
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }

    $UpdateChannelRegistryPath=$fixtureKey
    $UpdateChannelRegistryName='UpdateChannel'
    $StableUpdateManifestApiUrl='https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/latest.json?ref=main'
    $PreviewUpdateManifestApiUrl='https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/preview.json?ref=preview'

    Check ((Get-UpdateChannel) -ceq 'stable') 'Missing preference fails safely to Stable'
    Check (Set-UpdateChannel 'preview') 'Fixture opts into Early-access without elevation'
    Check ((Get-UpdateChannel) -ceq 'preview') 'Early-access preference round-trips exactly'
    Check ((Get-UpdateManifestApiUrl 'stable') -ceq $StableUpdateManifestApiUrl -and (Get-UpdateManifestApiUrl 'preview') -ceq $PreviewUpdateManifestApiUrl) 'UI maps Stable and Early-access to two fixed GitHub endpoints'
    $rejected=$false
    try{[void](Get-UpdateManifestApiUrl 'https://example.invalid/manifest.json')}catch{$rejected=$true}
    Check $rejected 'UI rejects arbitrary update-channel URLs'
    Check (Set-UpdateChannel 'stable') 'Fixture can return to Stable'
    Check ((Get-UpdateChannel) -ceq 'stable') 'Stable is represented by no Early-access opt-in value'

    $marker=Get-Content (Join-Path $root 'app\protected-update.json') -Raw|ConvertFrom-Json
    Check ([int]$marker.schema -eq 2 -and [string]$marker.channel -ceq 'preview' -and [int64]$marker.versionCode -gt 0) 'Ordinary bridge cryptographically carries the Preview channel into protected handoff'

    $updaterPath=Join-Path $root 'app\TailscaleQuickRepairUpdater.exe'
    $updaterAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($updaterPath))
    $updaterType=$updaterAssembly.GetType('Program',$true)
    $flags=[Reflection.BindingFlags]'Static,Public,NonPublic'
    $updaterGetUrl=$updaterType.GetMethod('GetManifestApiUrl',$flags)
    Check ($null -ne $updaterGetUrl) 'Compiled updater exposes fixed channel mapping to acceptance'
    $updaterStable=[string]$updaterGetUrl.Invoke($null,[object[]]@('stable'))
    $updaterPreview=[string]$updaterGetUrl.Invoke($null,[object[]]@('preview'))
    Check ($updaterStable -ceq $StableUpdateManifestApiUrl -and $updaterPreview -ceq $PreviewUpdateManifestApiUrl) 'Compiled updater and UI use identical fixed endpoints'
    $nativeRejected=$false
    try{[void]$updaterGetUrl.Invoke($null,[object[]]@('file:///arbitrary.json'))}
    catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$nativeRejected=($inner -is [IO.InvalidDataException])}
    Check $nativeRejected 'Compiled updater rejects arbitrary channel input'

    $validateMarker=$updaterType.GetMethod('ValidateProtectedHandoffMarker',$flags)
    Check ($null -ne $validateMarker) 'Compiled updater exposes its protected handoff marker validator to acceptance'
    $schema2Preview='{"schema":2,"versionCode":42,"channel":"preview"}'
    [void]$validateMarker.Invoke($null,[object[]]@($schema2Preview,'preview',[int64]42))
    Check $true 'Compiled updater accepts the exact Preview schema-2 marker'
    $crossChannelRejected=$false
    try{[void]$validateMarker.Invoke($null,[object[]]@($schema2Preview,'stable',[int64]42))}
    catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$crossChannelRejected=($inner -is [IO.InvalidDataException])}
    Check $crossChannelRejected 'Compiled updater rejects a Preview bridge selected through Stable'
    $wrongVersionRejected=$false
    try{[void]$validateMarker.Invoke($null,[object[]]@($schema2Preview,'preview',[int64]43))}
    catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$wrongVersionRejected=($inner -is [IO.InvalidDataException])}
    Check $wrongVersionRejected 'Compiled updater rejects a bridge marker for another target code'
    $schema1='{"schema":1,"versionCode":42}'
    [void]$validateMarker.Invoke($null,[object[]]@($schema1,'stable',[int64]42))
    $legacyPreviewRejected=$false
    try{[void]$validateMarker.Invoke($null,[object[]]@($schema1,'preview',[int64]42))}
    catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$legacyPreviewRejected=($inner -is [IO.InvalidDataException])}
    Check $legacyPreviewRejected 'Legacy schema-1 protected markers are accepted only on Stable'

    $setupPath=Join-Path $root 'app\TailscaleQuickRepairSetup.exe'
    $setupAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($setupPath))
    $setupType=$setupAssembly.GetType('PublicSetupHost',$true)
    $setupGetUrl=$setupType.GetMethod('GetManifestApiUrl',$flags)
    Check ($null -ne $setupGetUrl) 'Compiled Setup exposes fixed channel mapping to acceptance'
    $setupStable=[string]$setupGetUrl.Invoke($null,[object[]]@('stable'))
    $setupPreview=[string]$setupGetUrl.Invoke($null,[object[]]@('preview'))
    Check ($setupStable -ceq $StableUpdateManifestApiUrl -and $setupPreview -ceq $PreviewUpdateManifestApiUrl) 'Protected Setup and native updater use identical fixed endpoints'
    $setupRejected=$false
    try{[void]$setupGetUrl.Invoke($null,[object[]]@('https://example.invalid/manifest.json'))}
    catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$setupRejected=($inner -is [IO.InvalidDataException])}
    Check $setupRejected 'Protected Setup rejects arbitrary channel input'

    $entryType=$setupAssembly.GetType('PublicSetupEntry',$true)
    $preserve=$entryType.GetMethod('PreserveUpgradeArguments',$flags)
    Check ($null -ne $preserve) 'Compiled Setup entry exposes relocation argument preservation to acceptance'
    $upgradeArgs=[string[]]@('--upgrade','--channel','preview','--target-code','30000999','--requester-sid','S-1-5-21-100')
    $preserved=[string[]]$preserve.Invoke($null,[object[]]@(,$upgradeArgs))
    Check (($preserved -join [char]0) -ceq ($upgradeArgs -join [char]0)) 'Setup self-relocation preserves upgrade, channel, target code and requester SID exactly'

    $passed=$true
}finally{
    try{Remove-Item -LiteralPath $fixtureKey -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;cases=@($cases.ToArray());scope='Fixed Stable/Early-access routing, exact target binding and schema-2 protected handoff; fixture-only HKCU preference'}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $EvidenceDirectory 'update-channel-results.json') -Encoding UTF8
}
if(-not $passed){throw 'Update-channel acceptance failed.'}
