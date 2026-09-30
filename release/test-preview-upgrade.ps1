param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory = '.\upgrade-evidence'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2

if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   $env:GITHUB_REF_NAME -cne 'work/3.0' -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ID -or
   $env:RUNNER_OS -cne 'Windows' -or $PSVersionTable.PSVersion.Major -ne 5){
    throw 'Preview-upgrade acceptance requires the disposable GitHub Windows runner.'
}

$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   (git -C $repo remote get-url origin).Trim() -notmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$' -or
   (Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish){
    throw 'Exact unpublished isolated source required.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem,PresentationFramework
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrPreviewUpgrade-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$productKey='HKCU:\Software\TailscaleQuickRepair'
$taskNames=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false;$cleanup=$true;$failure=$null;$stage='preflight';$scheduler=$null;$folder=$null
$rc1Size=[int64]184330
$rc1Hash='e6097330a68153c3db65a3f33dad23508e2c6cb18da85ddc88c773594ecfa05c'
$candidate=Get-Content (Join-Path $repo 'version.json') -Raw|ConvertFrom-Json
$candidateVersion=[string]$candidate.version
$candidateCode=[int64]$candidate.versionCode
$match=[regex]::Match($candidateVersion,'\A3\.0\.0-rc\.([1-9][0-9]*)\z')
if(-not $match.Success -or $candidateCode -le 30001001 -or
   $candidateCode -ne (30001000+[int64]$match.Groups[1].Value) -or
   [string]$candidate.channel -cne 'preview'){
    throw 'Current source is not a monotonic Preview RC candidate after published RC1.'
}

function Check([bool]$Value,[string]$Name){
    $script:stage=$Name
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Preview-upgrade assertion failed.'}
    Write-Host ('PASS preview upgrade: '+$Name)
}
function Invoke-Private($Type,[string]$Name,[object[]]$Arguments=@()){
    $method=$Type.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw ('Required native boundary missing: '+$Name)}
    $native=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$native[$i]=$null}else{$native[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    try{return ,($method.Invoke($null,$native))}
    catch{$ex=$_.Exception;while($ex.InnerException){$ex=$ex.InnerException};throw $ex}
}
function Expand-Verified([string]$Zip,[string]$Destination){
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination
    $manifest=Get-Content (Join-Path $Destination 'package-manifest.json') -Raw|ConvertFrom-Json
    Check ($manifest.schema -eq 1 -and @($manifest.files).Count -gt 0) 'Package manifest is present and typed'
    foreach($f in @($manifest.files)){
        $relative=([string]$f.path).Replace('\','/')
        if($relative -match '(^/|:|(^|/)\.{1,2}(/|$))'){throw 'Unsafe package path.'}
        $path=Join-Path $Destination $relative
        Check ((Test-Path -LiteralPath $path -PathType Leaf) -and
               (Get-Item -LiteralPath $path).Length -eq [int64]$f.size -and
               (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq ([string]$f.sha256).ToLowerInvariant()) ('Verified package file '+$relative)
    }
    return $manifest
}
function Stop-DeleteTasks {
    if(-not $folder){return}
    foreach($name in $taskNames){
        $task=$null
        try{$task=$folder.GetTask($name)}catch{}
        if(-not $task){continue}
        try{
            $task.Enabled=$false
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while([int]$task.State -in @(2,4) -and $watch.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
            if([int]$task.State -in @(2,4)){throw 'Owned fixture task remained active.'}
            $folder.DeleteTask($name,0)
        }finally{try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)}catch{}}
    }
}
function InstalledHash([string]$Name){return (Get-FileHash (Join-Path $program $Name) -Algorithm SHA256).Hash.ToLowerInvariant()}

try{
    Check (-not(Test-Path $app) -and -not(Test-Path $program) -and -not(Get-Service Tailscale -ErrorAction SilentlyContinue)) 'Preview-upgrade fixture starts without product or vendor state'

    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $url='https://github.com/coachedai/tailscale-repair-clean/releases/download/v3.0.0-rc.1/TailscaleQuickRepair-SetupPackage-3.0.0-rc.1.zip'
    $rc1Zip=Join-Path $lab 'published-rc1.zip'
    $wc=New-Object Net.WebClient
    try{$wc.Headers.Add('User-Agent','TqrPreviewUpgradeAcceptance');$wc.DownloadFile($url,$rc1Zip)}finally{$wc.Dispose()}
    Check ((Get-Item $rc1Zip).Length -eq $rc1Size -and (Get-FileHash $rc1Zip -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $rc1Hash) 'Published RC1 Setup package matches the frozen size and SHA-256'

    $rc1Root=Join-Path $lab 'rc1'
    $rc1=Expand-Verified $rc1Zip $rc1Root
    Check ([string]$rc1.version -ceq '3.0.0-rc.1' -and [int64]$rc1.versionCode -eq 30001001) 'Published baseline is exactly RC1'

    $ordinaryZip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File|Where-Object Name -notlike '*SetupPackage*')
    $setupZip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-SetupPackage-*.zip' -File)
    Check ($ordinaryZip.Count -eq 1 -and $setupZip.Count -eq 1) 'Exactly one upstream-tested ordinary and protected candidate package are reused'
    $ordinaryRoot=Join-Path $lab 'candidate-ordinary';$ordinary=Expand-Verified $ordinaryZip[0].FullName $ordinaryRoot
    $setupRoot=Join-Path $lab 'candidate-setup';$setupManifest=Expand-Verified $setupZip[0].FullName $setupRoot
    $version=Get-Content (Join-Path $repo 'version.json') -Raw|ConvertFrom-Json
    Check ([string]$version.version -ceq $candidateVersion -and [int64]$version.versionCode -eq $candidateCode) 'Source identifies the unique current RC candidate'
    Check ([string]$ordinary.version -ceq [string]$version.version -and [int64]$ordinary.versionCode -eq [int64]$version.versionCode -and
           [string]$setupManifest.version -ceq [string]$version.version -and [int64]$setupManifest.versionCode -eq [int64]$version.versionCode) 'Both candidate packages match the exact current RC source'

    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
    foreach($name in $taskNames){$exists=$false;try{[void]$folder.GetTask($name);$exists=$true}catch{};Check (-not $exists) 'No pre-existing product task is reused'}

    $rc1Setup=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $rc1Root 'app\TailscaleQuickRepairSetup.exe'))).GetType('PublicSetupHost')
    Check ($null -ne $rc1Setup) 'Published RC1 Setup host loads from the pinned package'
    $lease=[bool](Invoke-Private $rc1Setup 'TryAcquireOperationLock' @('setup'))
    Check $lease 'Published RC1 Setup acquires its native operation lease'
    try{
        $m=Invoke-Private $rc1Setup 'ReadPackageManifest' @($rc1Root)
        $files=Invoke-Private $rc1Setup 'VerifyPackage' @($rc1Root,$m)
        $work=Join-Path $lab 'rc1-apply';[void][IO.Directory]::CreateDirectory($work)
        [void](Invoke-Private $rc1Setup 'ApplyFiles' @($files,$work))
        [void](Invoke-Private $rc1Setup 'WriteLocalConfig' @('preview-upgrade-fixture.invalid'))
        [void](Invoke-Private $rc1Setup 'ConfigureStartup' @($true))
        [void](Invoke-Private $rc1Setup 'RegisterRepairTask')
        [void](Invoke-Private $rc1Setup 'RegisterAutoRepairTask')
        [void](Invoke-Private $rc1Setup 'CreateStartMenuShortcut')
    }finally{[void](Invoke-Private $rc1Setup 'ReleaseOperationLock')}

    $installed=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ([string]$installed.version -ceq '3.0.0-rc.1' -and [int64]$installed.versionCode -eq 30001001) 'RC1 is genuinely installed before the candidate update'
    New-Item -ItemType Directory -Path $productKey -Force|Out-Null
    New-ItemProperty -LiteralPath $productKey -Name UpdateChannel -Value 'preview' -PropertyType String -Force|Out-Null

    $rc1Ui=[IO.File]::ReadAllText((Join-Path $app 'Tailscale-Repair-UI.ps1'),[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($rc1Ui,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0 -and $rc1Ui.Contains('x:Name="EarlyAccessUpdatesCheckBox"')) 'Published RC1 UI contains the Early-access selector'
    $getChannel=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-UpdateChannel'},$true))
    $startUpdate=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Start-UpdateInstall'},$true))
    Check ($getChannel.Count -eq 1 -and $startUpdate.Count -eq 1) 'Published RC1 exposes one channel selector and one Update now action'
    . ([scriptblock]::Create($getChannel[0].Extent.Text))
    $UpdateChannelRegistryPath=$productKey;$UpdateChannelRegistryName='UpdateChannel'
    Check ((Get-UpdateChannel) -ceq 'preview') 'Published RC1 reads the opted-in Preview channel'
    $route=[string]$startUpdate[0].Extent.Text
    Check ($route.Contains("'--channel'") -and $route.Contains("'--target-code'") -and $route.Contains('$script:updateManifestChannel')) 'Published RC1 Update now route carries exact channel and target identity'

    $guardianManifest=Join-Path $app 'integrity-manifest.json'
    $guardianHash=(Get-FileHash $guardianManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{schema=1;versionCode=[int64]30001001;integrityManifestSha256=$guardianHash;verifiedReleaseFiles=1;startupEnabled=$true;repairEngineReady=$true;autoRepairAvailable=$true;verifiedUtc=[DateTime]::UtcNow.ToString('o')}|
        ConvertTo-Json -Depth 4|Set-Content (Join-Path $app 'guardian-known-good.json') -Encoding UTF8

    $protectedBefore=[ordered]@{}
    foreach($name in @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1','TailscaleQuickRepair.Operations.dll')){$protectedBefore[$name]=InstalledHash $name}
    $configBefore=(Get-FileHash (Join-Path $app 'config.json') -Algorithm SHA256).Hash

    $tempUpdater=Join-Path $lab 'RC1-Updater.exe'
    Copy-Item (Join-Path $app 'TailscaleQuickRepairUpdater.exe') $tempUpdater
    $updater=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($tempUpdater)).GetType('Program')
    Check ($null -ne $updater) 'Published RC1 updater loads from a detached copy'
    $candidateManifest=Invoke-Private $updater 'ReadPackageManifest' @($ordinaryRoot)
    $candidateFiles=Invoke-Private $updater 'VerifyPackageFiles' @($ordinaryRoot,$candidateManifest)
    [void](Invoke-Private $updater 'ValidatePackageChannelBinding' @($candidateFiles,'preview',[int64]$candidateManifest.VersionCode))
    Check $true 'Published RC1 updater accepts the current RC package only for its Preview channel and target code'
    $updateLease=[bool](Invoke-Private $updater 'TryAcquireOperationLock' @('update'))
    Check $updateLease 'Published RC1 updater acquires the native update lease'
    try{[void](Invoke-Private $updater 'ApplyTransaction' @($candidateFiles,[string]$candidateManifest.Version,[int64]$candidateManifest.VersionCode))}
    finally{[void](Invoke-Private $updater 'ReleaseOperationLock')}

    $bridged=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ([string]$bridged.version -ceq $candidateVersion -and [int64]$bridged.versionCode -eq $candidateCode) 'Published RC1 updater stages the exact current RC user-level bridge'
    $marker=Get-Content (Join-Path $app 'protected-update.json') -Raw|ConvertFrom-Json
    Check ([int]$marker.schema -eq 2 -and [int64]$marker.versionCode -eq $candidateCode -and [string]$marker.channel -ceq 'preview') 'current RC bridge carries the exact Preview protected-update marker'
    foreach($name in $protectedBefore.Keys){Check ((InstalledHash $name) -ceq [string]$protectedBefore[$name]) ('RC1 updater leaves protected '+$name+' unchanged before Setup')}
    Check ((Get-FileHash (Join-Path $app 'config.json') -Algorithm SHA256).Hash -ceq $configBefore -and
           (Get-ItemProperty -LiteralPath $productKey -Name UpdateChannel).UpdateChannel -ceq 'preview') 'Bridge preserves local config and Early-access preference'

    $detachedSetup=Join-Path $lab 'Current-RC-Setup.exe'
    Copy-Item (Join-Path $app 'TailscaleQuickRepairSetup.exe') $detachedSetup
    $setup=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($detachedSetup)).GetType('PublicSetupHost')
    Check ($null -ne $setup) 'Staged current RC Setup host loads from a detached copy'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [void](Invoke-Private $setup 'RequireRequesterIdentity' @($sid))
    [void](Invoke-Private $setup 'RecoverInterruptedFileTransaction')
    $m2=Invoke-Private $setup 'ReadPackageManifest' @($setupRoot)
    $files2=Invoke-Private $setup 'VerifyPackage' @($setupRoot,$m2)
    [void](Invoke-Private $setup 'ValidateProtectedUpdateMarker' @([int64]$m2.VersionCode,'preview'))
    $peer=[string](Invoke-Private $setup 'ReadConfiguredPeer')
    $startup=[bool](Invoke-Private $setup 'IsStartupEnabled')
    Check ($peer -ceq 'preview-upgrade-fixture.invalid' -and $startup) 'Refreshed current RC Setup reads the existing synthetic target and startup preference'
    $setupLease=[bool](Invoke-Private $setup 'TryAcquireUpgradeOperationLock')
    Check $setupLease 'Refreshed current RC Setup acquires the protected upgrade lease'
    try{
        [void](Invoke-Private $setup 'StopQuickRepair')
        $work2=Join-Path $lab 'current-rc-protected-apply';[void][IO.Directory]::CreateDirectory($work2)
        [void](Invoke-Private $setup 'ApplyFiles' @($files2,$work2))
        [void](Invoke-Private $setup 'CompleteInstalledIntegration' @($peer,$startup,$true,[int64]$m2.VersionCode))
    }finally{[void](Invoke-Private $setup 'ReleaseOperationLock')}

    Check (-not(Test-Path (Join-Path $app 'protected-update.json'))) 'current RC protected completion removes the handoff marker'
    $final=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ([string]$final.version -ceq $candidateVersion -and [int64]$final.versionCode -eq $candidateCode) 'Protected completion leaves the exact current RC version installed'
    Check ((Get-FileHash (Join-Path $app 'config.json') -Algorithm SHA256).Hash -ceq $configBefore -and
           (Get-ItemProperty -LiteralPath $productKey -Name UpdateChannel).UpdateChannel -ceq 'preview') 'Protected completion preserves config and Early-access preference'
    foreach($entry in @($setupManifest.files|Where-Object {[string]$_.path -like 'program/*'})){
        $name=([string]$entry.path).Substring(8)
        Check ((Get-FileHash (Join-Path $program $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq ([string]$entry.sha256).ToLowerInvariant()) ('Protected current RC file matches package: '+$name)
    }

    $pending=(Get-ItemProperty -LiteralPath $productKey -Name PendingRestartVersionCode -ErrorAction Stop).PendingRestartVersionCode
    Check ($pending -is [long] -and [int64]$pending -eq $candidateCode) 'current RC protected completion writes the exact QWORD restart acknowledgement'

    $finalUi=[IO.File]::ReadAllText((Join-Path $app 'Tailscale-Repair-UI.ps1'),[Text.Encoding]::UTF8)
    Check (-not $finalUi.Contains([string][char]0x00C2)) 'Installed current RC UI contains no UTF-8 mojibake lead character'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($finalUi,[ref]$tokens,[ref]$errors)
    $ack=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Acknowledge-ProtectedRestart'},$true))
    Check ($errors.Count -eq 0 -and $ack.Count -eq 1) 'Installed current RC UI has one parsed restart acknowledgement function'
    . ([scriptblock]::Create($ack[0].Extent.Text))
    function Get-Brush([string]$Name){return [Windows.Media.Brushes]::Gray}
    $script:ackHistory=New-Object 'Collections.Generic.List[string]'
    $script:ackNotifications=New-Object 'Collections.Generic.List[string]'
    function Write-LocalHistoryEvent {param([string]$Code,[int]$Before=-1,[int]$After=-1)$script:ackHistory.Add($Code)}
    function Request-SmartNotification {param([string]$Code,[string]$Stamp)$script:ackNotifications.Add($Code);return 'requested'}
    $RestartRegistryPath=$productKey;$RestartRegistryName='PendingRestartVersionCode'
    $ProductVersion=$candidateVersion;$ProductVersionCode=[int64]$candidateCode
    $UpdateStatusText=New-Object Windows.Controls.TextBlock
    $UpdateDetailText=New-Object Windows.Controls.TextBlock
    Check (Acknowledge-ProtectedRestart) 'Synthetic restarted current RC app acknowledges the exact protected restart'
    Check ($UpdateStatusText.Text -ceq ('Updated successfully - '+$candidateVersion)) 'Restart acknowledgement renders the exact ASCII-safe current RC success text'
    $after=Get-ItemProperty -LiteralPath $productKey -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
    Check (-not $after -or $null -eq $after.PendingRestartVersionCode) 'Restart acknowledgement clears the pending value'
    Check ($script:ackHistory.Count -eq 1 -and $script:ackNotifications.Count -eq 1) 'Restart acknowledgement emits one typed History event and one notification request'

    $snapshot=Get-Content (Join-Path $app 'guardian-known-good.json') -Raw|ConvertFrom-Json
    Check ([int64]$snapshot.versionCode -eq 30001001) 'Updater and Setup do not silently rewrite the prior Guardian known-good record'
    $passed=$true
}
catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}
finally{
    try{Stop-DeleteTasks}catch{$cleanup=$false}
    foreach($item in @($folder,$scheduler)){if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}}
    try{Remove-ItemProperty -LiteralPath $runKey -Name 'Tailscale Quick Repair' -ErrorAction SilentlyContinue}catch{$cleanup=$false}
    try{Remove-Item -LiteralPath $productKey -Recurse -Force -ErrorAction SilentlyContinue}catch{$cleanup=$false}
    foreach($shortcut in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Tailscale Quick Repair.lnk'),
        (Join-Path $app 'Launch-Tailscale-Quick-Repair-Startup.vbs')
    )){try{Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue}catch{$cleanup=$false}}
    foreach($path in @($app,$program,$lab)){try{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}catch{$cleanup=$false}}
    $cases.Add([pscustomobject]@{name='Preview-upgrade acceptance removes only fixture-owned product state';passed=$cleanup})
    [pscustomobject]@{
        passed=($passed -and $cleanup)
        source=$env:GITHUB_SHA
        baseline='3.0.0-rc.1'
        candidate=$candidateVersion
        cases=@($cases.ToArray())
        failure=$failure
        scope='Synthetic published RC1 to current Early-access candidate through native updater and protected Setup; no real-machine evidence'
    }|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'preview-upgrade-results.json') -Encoding UTF8
}
if(-not $passed -or -not $cleanup){throw 'Preview-upgrade acceptance failed; inspect synthetic evidence.'}
