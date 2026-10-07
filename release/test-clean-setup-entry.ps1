param(
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
# Fixed baseline servicing, not version-to-version upgrade acceptance.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$repository='coachedai/tailscale-repair-clean'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
   $env:GITHUB_REF_NAME -notin @('main','work/public') -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or $PSVersionTable.PSEdition -cne 'Desktop' -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Empty hosted Windows entry-test environment required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Hosted administrator context required; desktop consent is not tested.'
}
if($env:TQR_SETUP_RELOCATION_TEST_APPDIR){throw 'Relocation overrides are not permitted.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$origin=git -C $repo remote get-url origin
if($LASTEXITCODE -ne 0 -or $origin -cnotmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$'){throw 'Repository remote mismatch.'}
$head=git -C $repo rev-parse HEAD
if($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA){throw 'Checkout identity mismatch.'}
foreach($leaf in @('publish.json','preview-publish.json')){
    $p=Get-Content -LiteralPath (Join-Path $PSScriptRoot $leaf) -Raw|ConvertFrom-Json
    if($p.publish -isnot [bool] -or $p.publish){throw 'Publication must remain disabled.'}
}
function Require-UnlinkedPath([string]$Path){
    $part=[IO.Path]::GetFullPath($Path)
    while($part){
        if(Test-Path -LiteralPath $part){
            if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected path refused.'}
        }
        $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
    }
}
$runnerRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($p in @($InputDirectory,$EvidenceDirectory)){
    if(-not ([IO.Path]::GetFullPath($p)).StartsWith($runnerRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Runner temporary storage required.'}
    Require-UnlinkedPath $p
}
$report=Join-Path $EvidenceDirectory 'clean-setup-entry-results.json'
if(Test-Path -LiteralPath $report){throw 'Existing evidence must not be overwritten.'}
# Revalidate transferred bytes against committed pins before any native load.
& python -B (Join-Path $PSScriptRoot 'verify-clean-baseline-inputs.py') $InputDirectory
if($LASTEXITCODE -ne 0){throw 'Fixed baseline input verification failed.'}
$pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'clean-baseline.json') -Raw|ConvertFrom-Json
$baselineVersion=[string]$pins.version
$baselineCode=[int64]$pins.versionCode
$candidate=Join-Path $InputDirectory ('TailscaleQuickRepair-Standalone-'+$baselineVersion+'.exe')
$payload=Join-Path $InputDirectory ('TailscaleQuickRepair-SetupPackage-'+$baselineVersion+'.zip')
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$candidateHash=Digest $candidate
$payloadHash=Digest $payload
$app=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TailscaleQuickRepair'
$program=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TailscaleQuickRepair'
$recovery=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TailscaleQuickRepair.SetupRecovery'
$shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Tailscale Quick Repair.lnk'
$startupKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupValue='Tailscale Quick Repair'
$productRegistry='HKCU:\Software\TailscaleQuickRepair'
$taskNames=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
function Require-EmptyProductState {
    foreach($p in @($app,$program,$recovery,$shortcut)){
        Require-UnlinkedPath $p
        if(Test-Path -LiteralPath $p){throw 'Existing product state must not be used.'}
    }
    if(Test-Path -LiteralPath $productRegistry){throw 'Existing registry state refused.'}
    if(Get-Service Tailscale -ErrorAction SilentlyContinue){throw 'Existing Tailscale service refused.'}
    if(@(Get-Process -Name 'tailscale*','TailscaleQuickRepair*' -ErrorAction SilentlyContinue).Count){throw 'Existing product process refused.'}
    if(Get-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction SilentlyContinue){throw 'Existing startup setting refused.'}
    foreach($name in $taskNames){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Existing product task refused.'}}
}
Require-EmptyProductState
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'SetupEntryProbe.cs')
$work=Join-Path $runnerRoot ('TqrCleanSetupEntry-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$cases=New-Object 'Collections.Generic.List[object]'
$ownedProcesses=New-Object 'Collections.Generic.List[object]'
$flags=[Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$entryExecuted=$false;$passed=$false;$owned=$false;$cleanupPassed=$false;$leaseType=$null
$stage='initial';$failure='';$failureReason='';$servicingExecuted=$false
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Entry assertion failed.'}
    Write-Host ('PASS clean Setup entry: '+$Name)
}
function Native([Type]$Type,[string]$Name,[object[]]$Arguments=@()){
    $method=$Type.GetMethod($Name,$flags);if(-not $method){throw 'Native fixture method unavailable.'}
    $values=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$values[$i]=$null}else{$values[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    $result=$method.Invoke($null,$values)
    if($null -eq $result){return $null}
    return ,$result.PSObject.BaseObject
}
function Entry-Failure([string]$Code){$script:failureReason=$Code;throw 'Setup observation stopped.'}
function Remember-Process($Process,[string]$Path){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt 10){
        $Process.Refresh();if($Process.HasExited){Entry-Failure 'process_exited_before_identity'}
        $module=$null;try{$module=$Process.MainModule}catch [ComponentModel.Win32Exception]{}
        if($module -and $module.FileName -ieq $Path){
            $ownedProcesses.Add([pscustomobject]@{process=$Process;path=$Path;started=$Process.StartTime.ToUniversalTime().Ticks})
            return
        }
        Start-Sleep -Milliseconds 50
    }
    Entry-Failure 'process_identity_timeout'
}
function Launch-Setup([string]$Arguments=''){
    Require-UnlinkedPath $candidate
    if((Digest $candidate) -cne $candidateHash){throw 'Installer changed before execution.'}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$candidate;$info.Arguments=$Arguments;$info.WorkingDirectory=$work;$info.UseShellExecute=$false
    $p=[Diagnostics.Process]::Start($info)
    Remember-Process $p $candidate
    $script:entryExecuted=$true
    return $p
}
function Wait-Window($Process,[string]$Title,[string]$ClassPrefix='',[int]$TimeoutSeconds=30){
    if($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60){Entry-Failure 'invalid_timeout'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        $Process.Refresh();if($Process.HasExited){Entry-Failure 'process_exited_before_window'}
        $window=[SetupEntryProbe]::Find($Process.Id,$Title,$ClassPrefix)
        if($window -ne [IntPtr]::Zero){return $window}
        Start-Sleep -Milliseconds 100
    }
    Entry-Failure 'owned_window_timeout'
}
function Assert-Files($Plan,[string]$Name){
    $okay=$true
    foreach($file in $Plan){Require-UnlinkedPath $file.Target;if(-not(Test-Path -LiteralPath $file.Target -PathType Leaf) -or (Digest $file.Target) -cne $file.Sha256){$okay=$false}}
    Check $okay $Name
}
function Disable-OwnedTasks {
    if(-not $owned){throw 'Task ownership unavailable.'}
    foreach($name in $taskNames){[void](Disable-ScheduledTask -TaskName $name -ErrorAction Stop)}
}
try{
    $stage='cancel_fresh_dialog'
    $cancel=Launch-Setup
    $window=Wait-Window $cancel 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$cancel.Id,'Choose the Tailscale target')) 'Fresh native Setup displays target selection'
    Check ([SetupEntryProbe]::Click($window,$cancel.Id,'Cancel')) 'Cancellation targets only the owned Setup window'
    Check ($cancel.WaitForExit(10000) -and $cancel.ExitCode -eq 0) 'Cancelled Setup exits normally'
    Require-EmptyProductState
    Check $true 'Cancellation leaves product files, settings and tasks absent'

    $stage='seed_isolated_baseline'
    $packageRoot=Join-Path $work 'baseline'
    if((Digest $payload) -cne $payloadHash){throw 'Payload changed before extraction.'}
    [IO.Compression.ZipFile]::ExtractToDirectory($payload,$packageRoot)
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $packageRoot 'app/TailscaleQuickRepairSetup.exe')))
    $type=$assembly.GetType('PublicSetupHost',$true)
    $manifest=Native $type 'ReadPackageManifest' @($packageRoot)
    $plan=Native $type 'VerifyPackage' @($packageRoot,$manifest)
    Check ($plan.Count -eq 11) 'Native baseline manifest verifies every installation file'
    Check ((Native $type 'GetAppDir') -ceq $app -and (Native $type 'GetProgramDir') -ceq $program) 'Fixture resolves only the guarded empty roots'
    # Native methods seed synthetic installed state only. Servicing below must
    # enter through the unchanged standalone executable, not reflection.
    Check ([bool](Native $type 'TryAcquireOperationLock' @('setup'))) 'Seed obtains the actual installation lease'
    $leaseType=$type;$owned=$true
    [void](Native $type 'ApplyFiles' @($plan,$work))
    [void](Native $type 'CompleteInstalledIntegration' @('fixture-device.invalid',$true,$false,$baselineCode))
    Disable-OwnedTasks
    Assert-Files $plan 'Isolated baseline installation matches the fixed manifest'
    [void](Native $type 'ReleaseOperationLock');$leaseType=$null
    $config=Join-Path $app 'config.json'
    $settings=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
    $settings|Add-Member -NotePropertyName retainedFixture -NotePropertyValue 'retained'
    [IO.File]::WriteAllText($config,($settings|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $configHash=Digest $config

    $stage='requester_refusal'
    $refusal=Launch-Setup '--requester-sid S-1-0-0'
    $window=Wait-Window $refusal 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$refusal.Id,'same Windows account')) 'Actual entry refuses a mismatched requesting identity'
    Check ([SetupEntryProbe]::Click($window,$refusal.Id,'OK')) 'Refusal is acknowledged only on the owned window'
    Check ($refusal.WaitForExit(10000) -and $refusal.ExitCode -eq 10) 'Refused entry returns its expected exit code'
    Assert-Files $plan 'Requester refusal preserves the complete installation'
    Check ((Digest $config) -ceq $configHash) 'Requester refusal preserves exact configuration bytes'

    $stage='same_version_servicing'
    $damaged=Join-Path $app 'Advanced-Diagnostics.ps1'
    Require-UnlinkedPath $damaged
    $originalHash=Digest $damaged
    [IO.File]::WriteAllText($damaged,'Synthetic damaged application fixture.',(New-Object Text.UTF8Encoding($false)))
    Check ((Digest $damaged) -cne $originalHash) 'Owned fixture is genuinely damaged before servicing'
    $setup=Launch-Setup
    $servicingExecuted=$true
    $window=Wait-Window $setup 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$setup.Id,'Tailscale Quick Repair is ready.')) 'Normal standalone entry reports successful servicing'
    Assert-Files $plan 'Actual entry restores every fixed baseline file including damaged content'
    Check ([SetupEntryProbe]::Click($window,$setup.Id,'OK')) 'Servicing completion is acknowledged through the real dialog'
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'Normally launched standalone Setup exits successfully'
    Disable-OwnedTasks

    $stage='installed_relaunch'
    $watch=[Diagnostics.Stopwatch]::StartNew();$appProcess=$null
    while($watch.Elapsed.TotalSeconds -lt 20){
        $found=@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue)
        if($found.Count -gt 1){throw 'Unexpected resident process count.'}
        if($found.Count -eq 1){$appProcess=$found[0];break};Start-Sleep -Milliseconds 100
    }
    Check ($null -ne $appProcess) 'Setup itself launches the installed application'
    $appExe=Join-Path $app 'TailscaleQuickRepair.exe'
    Remember-Process $appProcess $appExe
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper' 60
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'Installed WPF window loads and responds'
    $watch=[Diagnostics.Stopwatch]::StartNew();$acknowledged=$false
    while($watch.Elapsed.TotalSeconds -lt 20){
        $pending=Get-ItemProperty -LiteralPath $productRegistry -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
        if(-not $pending -or $null -eq $pending.PendingRestartVersionCode){$acknowledged=$true;break}
        $appProcess.Refresh();if($appProcess.HasExited){break};Start-Sleep -Milliseconds 100
    }
    Check $acknowledged 'Installed application clears the restart acknowledgement'
    Check ((Digest $config) -ceq $configHash) 'Servicing and launch preserve all configuration bytes'
    Check ((Native $type 'ReadConfiguredPeer') -ceq 'fixture-device.invalid' -and [bool](Native $type 'IsStartupEnabled')) 'Target and startup preference remain unchanged'
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq $baselineVersion -and $installed.versionCode -eq $baselineCode) 'Servicing keeps the exact baseline version'

    $stage='tray_and_activation'
    Check ([SetupEntryProbe]::Close($appWindow,$appProcess.Id)) 'Close targets only the owned installed window'
    $watch=[Diagnostics.Stopwatch]::StartNew();$hidden=$false
    while($watch.Elapsed.TotalSeconds -lt 10){
        $appProcess.Refresh();if($appProcess.HasExited){break}
        if([SetupEntryProbe]::Find($appProcess.Id,'Tailscale Quick Repair','HwndWrapper') -eq [IntPtr]::Zero){$hidden=$true;break}
        Start-Sleep -Milliseconds 100
    }
    Check $hidden 'Window close preserves the resident tray process'
    $second=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName=$appExe;UseShellExecute=$false;WorkingDirectory=$app})
    if(-not $second.WaitForExit(10000)){Remember-Process $second $appExe;throw 'Secondary instance exceeded its bound.'}
    Check ($second.ExitCode -eq 0) 'Second launch signals the resident instance and exits'
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper'
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'The same resident window restores and responds'
    Check (@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue).Count -eq 1) 'Only one installed resident instance remains'
    Assert-Files $plan 'Resident operation preserves all fixed installation files'
    $passed=$true
}catch{
    $e=$_.Exception;while($e.InnerException){$e=$e.InnerException};$failure=$e.GetType().FullName
}finally{
    if($leaseType){try{[void](Native $leaseType 'ReleaseOperationLock')}catch{$passed=$false;$failure='LeaseCleanupFailure'}}
    foreach($entry in $ownedProcesses){
        try{
            $p=$entry.process;$p.Refresh()
            if(-not $p.HasExited){
                if($p.StartTime.ToUniversalTime().Ticks -ne $entry.started -or $p.MainModule.FileName -ine $entry.path){throw 'Owned process identity changed.'}
                $p.Kill();if(-not $p.WaitForExit(5000)){throw 'Owned process did not stop.'}
            }
        }catch{$passed=$false;$failure='OwnedProcessCleanupFailure'}
    }
    if($owned){foreach($name in $taskNames){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){[void](Disable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue)}}}
    # Keep failing fixture state for investigation; never delete it to force a pass.
    if($passed -and $owned){
        try{
            foreach($p in @($app,$program,$recovery)){
                Require-UnlinkedPath $p
                if(Test-Path -LiteralPath $p){if(@(Get-ChildItem -LiteralPath $p -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unexpected link in owned fixture.'}}
            }
            foreach($name in $taskNames){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop}
            Remove-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction Stop
            if(Test-Path -LiteralPath $productRegistry){Remove-Item -LiteralPath $productRegistry -Recurse -Force}
            foreach($p in @($shortcut,$app,$program,$recovery)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force}}
            Require-EmptyProductState;$cleanupPassed=$true
        }catch{$passed=$false;$failure='OwnedStateCleanupFailure'}
    }
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    [pscustomobject]@{
        schema=1;passed=$passed;testSource=$env:GITHUB_SHA;baselineSource=[string]$pins.source
        baselineVersion=$baselineVersion;candidateSha256=$candidateHash;payloadSha256=$payloadHash
        cases=@($cases.ToArray());cleanupPassed=$cleanupPassed;failureType=$failure;failureReason=$failureReason;stage=$stage
        setupEntryExecuted=$entryExecuted;sameVersionServicingExecuted=$servicingExecuted
        versionUpgradeTested=$false;desktopElevationTested=$false;publicFeedVerified=$false
        scope='Fixed clean baseline on an already elevated disposable Windows desktop: cancellation, requester refusal, real same-version file repair, installed WPF relaunch, close-to-tray and second-instance activation. Version upgrade, secure-desktop consent and public update delivery are not tested.'
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $report -Encoding UTF8
}
if(-not $passed){throw 'Clean Setup entry acceptance failed; typed evidence preserved.'}
Write-Host 'Clean Setup entry and same-version servicing passed. Version upgrade and desktop consent remain separate.'
