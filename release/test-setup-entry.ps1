param(
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
# Runs the unchanged standalone executable through its real entry point.
# Only synthetic state on an empty hosted Windows runner is permitted.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$repository='coachedai/tailscale-repair-clean'
$releasedHash='bdd905f8bd9dc771a3a8fd0ec5093157f30a7d0c2a8ac6d578b5ff6fd74626ce'
$candidateHash='ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17'
$payloadHash='f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
   $env:GITHUB_REF_NAME -notin @('main','work/public') -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or $PSVersionTable.PSEdition -cne 'Desktop' -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Empty hosted Windows entry-test environment required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Hosted administrator context required; this does not test desktop consent.'
}
if($env:TQR_SETUP_RELOCATION_TEST_APPDIR){throw 'Relocation overrides are not permitted in entry acceptance.'}
$repo=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
$origin=git -C $repo remote get-url origin
if($LASTEXITCODE -ne 0 -or $origin -cnotmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$'){throw 'Repository remote mismatch.'}
$head=git -C $repo rev-parse HEAD
if($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA){throw 'Checkout identity mismatch.'}
foreach($leaf in @('publish.json','preview-publish.json')){
    $p=Get-Content -LiteralPath (Join-Path $repo ('release/'+$leaf)) -Raw|ConvertFrom-Json
    if($p.publish -isnot [bool] -or $p.publish){throw 'Publication must remain disabled.'}
}
function Require-UnlinkedPath([string]$Path){
    $part=[IO.Path]::GetFullPath($Path)
    while($part){
        if(Test-Path -LiteralPath $part){
            if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected test path refused.'}
        }
        $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
    }
}
$runnerRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($p in @($InputDirectory,$EvidenceDirectory)){
    if(-not ([IO.Path]::GetFullPath($p)).StartsWith($runnerRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Inputs and evidence must be in runner temporary storage.'}
    Require-UnlinkedPath $p
}
$report=Join-Path $EvidenceDirectory 'setup-entry-results.json'
if(Test-Path -LiteralPath $report){throw 'Existing entry-test evidence must not be overwritten.'}
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$released=Join-Path $InputDirectory 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.11.zip'
$candidate=Join-Path $InputDirectory 'TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe'
$payload=Join-Path $InputDirectory 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.12.zip'
foreach($p in @($released,$candidate,$payload)){Require-UnlinkedPath $p}
if((Digest $released) -cne $releasedHash -or (Digest $candidate) -cne $candidateHash -or (Digest $payload) -cne $payloadHash){throw 'Exact original distribution bytes are required.'}
$receipt=Get-Content -LiteralPath (Join-Path $InputDirectory 'input-receipt.json') -Raw|ConvertFrom-Json
if($receipt.passed -isnot [bool] -or -not $receipt.passed -or $receipt.testSource -cne $env:GITHUB_SHA -or $receipt.predecessorArtifactId -ne 11103704932 -or $receipt.candidateArtifactId -ne 11107315062){throw 'Same-source fixture receipt required.'}
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
    if(Test-Path -LiteralPath $productRegistry){throw 'Existing product registry state refused.'}
    if(Get-Service Tailscale -ErrorAction SilentlyContinue){throw 'A runner without a Tailscale service is required.'}
    if(@(Get-Process -Name 'tailscale*','TailscaleQuickRepair*' -ErrorAction SilentlyContinue).Count){throw 'Existing product process refused.'}
    if(Get-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction SilentlyContinue){throw 'Existing startup preference refused.'}
    foreach($name in $taskNames){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Existing product task refused.'}}
}
Require-EmptyProductState
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'SetupEntryProbe.cs')
$work=Join-Path $runnerRoot ('TqrSetupEntry-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$cases=New-Object 'Collections.Generic.List[object]'
$ownedProcesses=New-Object 'Collections.Generic.List[object]'
$flags=[Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$entryExecuted=$false;$passed=$false;$owned=$false;$cleanupPassed=$false;$leaseType=$null;$stage='initial';$failure='';$failureReason=''
function Check([bool]$Value,[string]$Name){
    $script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Entry assertion failed.'}
    Write-Host ('PASS Setup entry: '+$Name)
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
function Entry-Failure([string]$Code){
    $script:failureReason=$Code
    throw 'Setup entry observation stopped.'
}
function Remember-Process($Process,[string]$Path){
    # Process.Start can return before the native image is available to MainModule.
    # Do not read windows or register cleanup ownership until identity is verified.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt 10){
        $Process.Refresh()
        if($Process.HasExited){Entry-Failure 'process_exited_before_identity'}
        $module=$null
        try{$module=$Process.MainModule}catch [ComponentModel.Win32Exception]{}
        if($module -and $module.FileName -ieq $Path){
            $ownedProcesses.Add([pscustomobject]@{process=$Process;path=$Path;started=$Process.StartTime.ToUniversalTime().Ticks})
            return
        }
        Start-Sleep -Milliseconds 50
    }
    Entry-Failure 'process_identity_timeout'
}
function Launch-Setup([string]$Arguments=''){
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$candidate;$info.Arguments=$Arguments;$info.WorkingDirectory=$work
    $info.UseShellExecute=$false
    $p=[Diagnostics.Process]::Start($info)
    Remember-Process $p $candidate
    $script:entryExecuted=$true
    return $p
}
function Wait-Window($Process,[string]$Title,[string]$ClassPrefix='',[int]$TimeoutSeconds=30){
    if($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60){Entry-Failure 'invalid_window_timeout'}
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
    foreach($name in $taskNames){[void](Disable-ScheduledTask -TaskName $name -ErrorAction Stop)}
}
try{
    $stage='cancel_initial_dialog'
    $cancel=Launch-Setup
    $window=Wait-Window $cancel 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$cancel.Id,'Choose the Tailscale target')) 'Fresh Setup displays its actual target-choice dialog'
    Check ([SetupEntryProbe]::Click($window,$cancel.Id,'Cancel')) 'Cancel is invoked on the owned Setup window'
    Check ($cancel.WaitForExit(10000) -and $cancel.ExitCode -eq 0) 'Cancelled Setup exits normally'
    Require-EmptyProductState
    Check $true 'Cancellation leaves all product locations and integration absent'
    $stage='establish_original_rc11'
    $oldRoot=Join-Path $work 'rc11';$newRoot=Join-Path $work 'rc12'
    # Whole-archive hashes above authorize only the exact reviewed distribution bytes.
    [IO.Compression.ZipFile]::ExtractToDirectory($released,$oldRoot)
    [IO.Compression.ZipFile]::ExtractToDirectory($payload,$newRoot)
    $oldAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $oldRoot 'app/TailscaleQuickRepairSetup.exe')))
    $oldType=$oldAssembly.GetType('PublicSetupHost',$true)
    $newAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($candidate))
    $newType=$newAssembly.GetType('PublicSetupHost',$true)
    $oldManifest=Native $oldType 'ReadPackageManifest' @($oldRoot)
    $newManifest=Native $newType 'ReadPackageManifest' @($newRoot)
    $oldFiles=Native $oldType 'VerifyPackage' @($oldRoot,$oldManifest)
    $newFiles=Native $newType 'VerifyPackage' @($newRoot,$newManifest)
    Check ($oldFiles.Count -eq 11 -and $newFiles.Count -eq 11) 'Original and candidate native manifests verify all files'
    Check ((Native $oldType 'GetAppDir') -ceq $app -and (Native $oldType 'GetProgramDir') -ceq $program) 'Original installer resolves only the guarded empty product roots'
    $owned=$true
    Check ([bool](Native $oldType 'TryAcquireOperationLock' @('setup'))) 'Original installer acquires its real operation lease'
    $leaseType=$oldType
    [void](Native $oldType 'ApplyFiles' @($oldFiles,$work))
    [void](Native $oldType 'CompleteInstalledIntegration' @('fixture-device.invalid',$true,$false,[int64]30001011))
    Disable-OwnedTasks
    Assert-Files $oldFiles 'Original RC11 installer establishes the genuine released baseline'
    [void](Native $oldType 'ReleaseOperationLock');$leaseType=$null
    $config=Join-Path $app 'config.json'
    $settings=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
    $settings|Add-Member -NotePropertyName retainedFixture -NotePropertyValue 'retained'
    [IO.File]::WriteAllText($config,($settings|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $configHash=Digest $config
    $stage='refuse_different_requester'
    $refusal=Launch-Setup '--requester-sid S-1-0-0'
    $window=Wait-Window $refusal 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$refusal.Id,'same Windows account')) 'Real Setup entry refuses a different requesting identity'
    Check ([SetupEntryProbe]::Click($window,$refusal.Id,'OK')) 'Identity refusal dialog is dismissed on its owning process'
    Check ($refusal.WaitForExit(10000) -and $refusal.ExitCode -eq 10) 'Rejected Setup returns its expected failure code'
    Assert-Files $oldFiles 'Identity refusal leaves every original RC11 file unchanged'
    Check ((Digest $config) -ceq $configHash) 'Identity refusal preserves complete configuration bytes'
    $stage='launch_standalone_upgrade'
    # No install-method invocation, test switch, target override or command argument.
    $setup=Launch-Setup
    $window=Wait-Window $setup 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$setup.Id,'Tailscale Quick Repair is ready.')) 'Unmodified standalone entry reports successful installation'
    Assert-Files $newFiles 'Normal Setup entry installs every exact RC12 file'
    Check ([SetupEntryProbe]::Click($window,$setup.Id,'OK')) 'Normal Setup completion is acknowledged through its real dialog'
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'Normal standalone Setup exits with success'
    Disable-OwnedTasks
    $stage='observe_setup_launched_application'
    $watch=[Diagnostics.Stopwatch]::StartNew();$appProcess=$null
    while($watch.Elapsed.TotalSeconds -lt 20){
        $found=@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue)
        if($found.Count -gt 1){throw 'Unexpected multiple resident processes.'}
        if($found.Count -eq 1){$appProcess=$found[0];break}
        Start-Sleep -Milliseconds 100
    }
    Check ($null -ne $appProcess) 'Setup itself launches the installed native application'
    $appExe=Join-Path $app 'TailscaleQuickRepair.exe'
    Remember-Process $appProcess $appExe
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper' 60
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'The real installed WPF window loads and responds'
    $watch=[Diagnostics.Stopwatch]::StartNew();$acknowledged=$false
    while($watch.Elapsed.TotalSeconds -lt 20){
        $pending=Get-ItemProperty -LiteralPath $productRegistry -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
        if(-not $pending -or $null -eq $pending.PendingRestartVersionCode){$acknowledged=$true;break}
        $appProcess.Refresh();if($appProcess.HasExited){break};Start-Sleep -Milliseconds 100
    }
    Check $acknowledged 'The refreshed application clears the real restart acknowledgement'
    Check ((Digest $config) -ceq $configHash) 'Full launch and relaunch preserve complete configuration bytes'
    Check ((Native $newType 'ReadConfiguredPeer') -ceq 'fixture-device.invalid' -and [bool](Native $newType 'IsStartupEnabled')) 'Target and startup preferences survive the actual Setup entry'
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq '3.0.0-rc.12' -and $installed.versionCode -eq 30001012) 'Normally launched application has the verified RC12 installation'
    $stage='tray_and_activation'
    Check ([SetupEntryProbe]::Close($appWindow,$appProcess.Id)) 'Window close is sent only to the owned installed application'
    $watch=[Diagnostics.Stopwatch]::StartNew();$hidden=$false
    while($watch.Elapsed.TotalSeconds -lt 10){
        $appProcess.Refresh();if($appProcess.HasExited){break}
        if([SetupEntryProbe]::Find($appProcess.Id,'Tailscale Quick Repair','HwndWrapper') -eq [IntPtr]::Zero){$hidden=$true;break}
        Start-Sleep -Milliseconds 100
    }
    Check $hidden 'Closing the installed window keeps its process resident in the tray'
    $second=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName=$appExe;UseShellExecute=$false;WorkingDirectory=$app})
    if(-not $second.WaitForExit(10000)){Remember-Process $second $appExe;throw 'Secondary instance did not exit within the bound.'}
    Check ($second.ExitCode -eq 0) 'Second launch signals the resident instance and exits normally'
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper'
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'The same resident window restores and responds after second launch'
    Check (@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue).Count -eq 1) 'Only one native resident instance remains'
    Assert-Files $newFiles 'Resident operation leaves all installed release files intact'
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
                $p.Kill();if(-not $p.WaitForExit(5000)){throw 'Owned test process did not stop.'}
            }
        }catch{$passed=$false;$failure='OwnedProcessCleanupFailure'}
    }
    if($owned){
        foreach($name in $taskNames){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){[void](Disable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue)}}
    }
    if($passed -and $owned){
        try{
            foreach($p in @($app,$program,$recovery)){
                Require-UnlinkedPath $p
                if(Test-Path -LiteralPath $p){if(@(Get-ChildItem -LiteralPath $p -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unexpected owned-state link.'}}
            }
            foreach($name in $taskNames){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop}
            Remove-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction Stop
            if(Test-Path -LiteralPath $productRegistry){Remove-Item -LiteralPath $productRegistry -Recurse -Force}
            foreach($p in @($shortcut,$app,$program,$recovery)){if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force}}
            Require-EmptyProductState
            $cleanupPassed=$true
        }catch{$passed=$false;$failure='OwnedStateCleanupFailure'}
    }
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    [pscustomobject]@{
        schema=1;passed=$passed;testSource=$env:GITHUB_SHA;candidateSource='36bd301fdff27737c2a0e3ad2375ce277ffc955c'
        releasedSha256=$releasedHash;candidateSha256=$candidateHash;payloadSha256=$payloadHash
        cases=@($cases.ToArray());cleanupPassed=$cleanupPassed;failureType=$failure;failureReason=$failureReason;stage=$stage
        setupEntryExecuted=$entryExecuted;desktopElevationTested=$false;publicFeedVerified=$false
        scope='Unchanged standalone process on an already elevated hosted Windows desktop: fresh dialog cancellation, requester refusal, actual upgrade entry, installed app restart acknowledgement, close-to-tray and second-instance activation. Secure-desktop UAC and public update delivery are not tested.'
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $report -Encoding UTF8
}
if(-not $passed){throw 'Setup entry acceptance failed; typed evidence was preserved.'}
Write-Host 'Actual Setup entry and installed relaunch passed on an elevated hosted runner. Desktop consent remains separate.'