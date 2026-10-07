param(
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
# Two exact distributed versions on an empty hosted runner; never a user's PC.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$repository='coachedai/tailscale-repair-clean'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
   $env:GITHUB_REF_NAME -notin @('main','work/public') -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or $PSVersionTable.PSEdition -cne 'Desktop' -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Empty hosted Windows upgrade environment required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Hosted administrator context required; desktop consent is not tested.'
}
if($env:TQR_SETUP_RELOCATION_TEST_APPDIR){throw 'Relocation overrides are not permitted.'}
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
$report=Join-Path $EvidenceDirectory 'clean-version-upgrade-results.json'
if(Test-Path -LiteralPath $report){throw 'Existing evidence must not be overwritten.'}
& python -B (Join-Path $PSScriptRoot 'test-controlled-rollback.py')
if($LASTEXITCODE -ne 0){throw 'Controlled rollback wiring checks failed.'}
# The verifier also requires exact repository/checkout identity and release locks.
& python -B (Join-Path $PSScriptRoot 'prepare-clean-upgrade.py') verify $InputDirectory
if($LASTEXITCODE -ne 0){throw 'Pinned upgrade inputs failed verification.'}
$oldPins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'clean-baseline.json') -Raw|ConvertFrom-Json
$newPins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'clean-upgrade.json') -Raw|ConvertFrom-Json
$oldVersion=[string]$oldPins.version;$newVersion=[string]$newPins.version
$oldCode=[int64]$oldPins.versionCode;$newCode=[int64]$newPins.versionCode
if($oldCode -ge $newCode){throw 'A strictly newer version is required.'}
$oldExe=Join-Path $InputDirectory ('TailscaleQuickRepair-Standalone-'+$oldVersion+'.exe')
$newExe=Join-Path $InputDirectory ('TailscaleQuickRepair-Standalone-'+$newVersion+'.exe')
$oldZip=Join-Path $InputDirectory ('TailscaleQuickRepair-SetupPackage-'+$oldVersion+'.zip')
$newZip=Join-Path $InputDirectory ('TailscaleQuickRepair-SetupPackage-'+$newVersion+'.zip')
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$oldHash=Digest $oldExe;$newHash=Digest $newExe
$oldZipHash=Digest $oldZip;$newZipHash=Digest $newZip
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
$work=Join-Path $runnerRoot ('TqrVersionUpgrade-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$cases=New-Object 'Collections.Generic.List[object]'
$ownedProcesses=New-Object 'Collections.Generic.List[object]'
$flags=[Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
$passed=$false;$owned=$false;$cleanupPassed=$false;$leaseType=$null
$upgradeExecuted=$false;$downgradeRefused=$false;$leaseRefused=$false
$controlledRollbackTested=$false;$rollbackPointsPassed=0
$stage='initial';$failure='';$failureReason=''
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Version upgrade assertion failed.'}
    Write-Host ('PASS version upgrade: '+$Name)
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
function Entry-Failure([string]$Code){$script:failureReason=$Code;throw 'Version upgrade observation stopped.'}
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
function Launch-Installer([string]$Path,[string]$Expected,[string]$Arguments=''){
    if(($Path -cne $newExe -or $Expected -cne $newHash) -and
       ($Path -cne $oldExe -or $Expected -cne $oldHash)){throw 'Unpinned installer refused.'}
    Require-UnlinkedPath $Path
    if((Digest $Path) -cne $Expected){throw 'Installer changed before execution.'}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Path;$info.Arguments=$Arguments;$info.WorkingDirectory=$work;$info.UseShellExecute=$false
    $p=[Diagnostics.Process]::Start($info);Remember-Process $p $Path
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
    $stage='candidate_cancellation'
    $cancel=Launch-Installer $newExe $newHash
    $window=Wait-Window $cancel 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$cancel.Id,'Choose the Tailscale target')) 'Candidate Setup displays its real initial dialog'
    Check ([SetupEntryProbe]::Click($window,$cancel.Id,'Cancel')) 'Candidate cancellation targets only its owned window'
    Check ($cancel.WaitForExit(10000) -and $cancel.ExitCode -eq 0) 'Candidate cancellation exits normally'
    Require-EmptyProductState;Check $true 'Candidate cancellation leaves installation state absent'

    $stage='seed_predecessor'
    if((Digest $oldZip) -cne $oldZipHash -or (Digest $newZip) -cne $newZipHash){throw 'Payload changed before extraction.'}
    $oldRoot=Join-Path $work 'predecessor';$newRoot=Join-Path $work 'candidate'
    [IO.Compression.ZipFile]::ExtractToDirectory($oldZip,$oldRoot)
    [IO.Compression.ZipFile]::ExtractToDirectory($newZip,$newRoot)
    $oldAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $oldRoot 'app/TailscaleQuickRepairSetup.exe')))
    $oldType=$oldAssembly.GetType('PublicSetupHost',$true)
    $newAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($newExe))
    $newType=$newAssembly.GetType('PublicSetupHost',$true)
    $oldManifest=Native $oldType 'ReadPackageManifest' @($oldRoot)
    $newManifest=Native $newType 'ReadPackageManifest' @($newRoot)
    $oldPlan=Native $oldType 'VerifyPackage' @($oldRoot,$oldManifest)
    $newPlan=Native $newType 'VerifyPackage' @($newRoot,$newManifest)
    Check ($oldPlan.Count -eq 11 -and $newPlan.Count -eq 11) 'Both actual native manifests verify their complete file plans'
    Check ((Native $oldType 'GetAppDir') -ceq $app -and (Native $oldType 'GetProgramDir') -ceq $program -and
           (Native $newType 'GetAppDir') -ceq $app -and (Native $newType 'GetProgramDir') -ceq $program) 'Both installers resolve only the guarded empty product roots'
    # Predecessor seeding and controlled-fault rollback use native methods.
    # The actual version transition still requires the distributed process.
    Check ([bool](Native $oldType 'TryAcquireOperationLock' @('setup'))) 'Predecessor seed obtains the real installation lease'
    $leaseType=$oldType;$owned=$true
    [void](Native $oldType 'ApplyFiles' @($oldPlan,$work))
    [void](Native $oldType 'CompleteInstalledIntegration' @('fixture-device.invalid',$true,$false,$oldCode))
    Disable-OwnedTasks;Assert-Files $oldPlan 'Predecessor installation matches its fixed manifest'
    [void](Native $oldType 'ReleaseOperationLock');$leaseType=$null
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq $oldVersion -and $installed.versionCode -eq $oldCode) 'Installed predecessor has the strictly older pinned version'
    $config=Join-Path $app 'config.json'
    $settings=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
    $settings|Add-Member -NotePropertyName retainedFixture -NotePropertyValue 'retained'
    [IO.File]::WriteAllText($config,($settings|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $configHash=Digest $config

    $stage='controlled_file_rollback'
    # Exercise the candidate's real exception-recovery path at every file
    # replacement. These callbacks do not model process death or power loss.
    Check ([bool](Native $newType 'TryAcquireOperationLock' @('setup'))) 'Controlled rollback owns the actual Setup lease'
    $leaseType=$newType
    $oldTargets=@{}
    foreach($file in $oldPlan){$oldTargets[$file.Target]=[string]$file.Sha256}
    $differentFiles=@($newPlan|Where-Object {$oldTargets[$_.Target] -cne $_.Sha256})
    Check ($differentFiles.Count -gt 0) 'Rollback exercises genuinely different predecessor and candidate bytes'
    for($checkpoint=1;$checkpoint -le $newPlan.Count;$checkpoint++){
        Assert-Files $oldPlan ('Rollback point '+$checkpoint+' starts with the exact predecessor')
        Check (-not (Test-Path -LiteralPath $recovery)) ('Rollback point '+$checkpoint+' has no previous recovery journal')
        $script:rollbackCheckpoint=$checkpoint
        $script:rollbackFaultReached=$false
        $script:rollbackCandidateObserved=$false
        $script:rollbackPreparedObserved=$false
        $fault=[Action[int]]{
            param($step)
            if($step -eq $script:rollbackCheckpoint){
                $script:rollbackFaultReached=$true
                $current=$newPlan[$step-1]
                Require-UnlinkedPath $current.Target
                $script:rollbackCandidateObserved=((Digest $current.Target) -ceq $current.Sha256)
                $journal=Join-Path $recovery 'transaction.json'
                Require-UnlinkedPath $journal
                $record=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
                $script:rollbackPreparedObserved=($record.state -ceq 'prepared' -and @($record.entries).Count -eq $newPlan.Count)
                throw [InvalidOperationException]::new('Synthetic replacement fault.')
            }
        }
        $failed=$false
        try{[void](Native $newType 'ApplyFilesCore' @($newPlan,$work,$fault))}catch{$failed=$true}
        Check ($failed -and $script:rollbackFaultReached -and $script:rollbackCandidateObserved -and
               $script:rollbackPreparedObserved) ('Rollback point '+$checkpoint+' injects only after a verified candidate replacement')
        Assert-Files $oldPlan ('Rollback point '+$checkpoint+' restores every exact predecessor file')
        Check ((Digest $config) -ceq $configHash) ('Rollback point '+$checkpoint+' preserves all configuration bytes')
        $temporaryAbsent=$true
        foreach($file in $newPlan){
            foreach($suffix in @('.setup.new','.setup.recover')){
                if(Test-Path -LiteralPath ($file.Target+$suffix)){$temporaryAbsent=$false}
            }
        }
        Check ($temporaryAbsent -and -not (Test-Path -LiteralPath $recovery)) ('Rollback point '+$checkpoint+' completes native recovery without manual cleanup')
        $rollbackPointsPassed++
    }
    Check ($rollbackPointsPassed -eq 11 -and $rollbackPointsPassed -eq $newPlan.Count) 'All fixed candidate replacement points pass controlled rollback'
    Check ((Native $newType 'ReadConfiguredPeer') -ceq 'fixture-device.invalid' -and [bool](Native $newType 'IsStartupEnabled')) 'Controlled rollback preserves target and startup preferences'
    $controlledRollbackTested=$true
    [void](Native $newType 'ReleaseOperationLock');$leaseType=$null

    $stage='held_operation_refusal'
    Check ([bool](Native $oldType 'TryAcquireOperationLock' @('maintenance'))) 'Fixture owns a real competing operation lease'
    $leaseType=$oldType
    $blocked=Launch-Installer $newExe $newHash
    $window=Wait-Window $blocked 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$blocked.Id,'Another Quick Repair operation')) 'Candidate refuses a real competing operation'
    Check ([SetupEntryProbe]::Click($window,$blocked.Id,'OK')) 'Operation refusal is acknowledged only on the owned window'
    Check ($blocked.WaitForExit(10000) -and $blocked.ExitCode -eq 10) 'Blocked upgrade returns the expected refusal code'
    Assert-Files $oldPlan 'Blocked upgrade preserves every predecessor file'
    Check ((Digest $config) -ceq $configHash) 'Blocked upgrade preserves exact configuration bytes'
    $leaseRefused=$true
    [void](Native $oldType 'ReleaseOperationLock');$leaseType=$null

    $stage='actual_version_upgrade'
    $setup=Launch-Installer $newExe $newHash
    $upgradeExecuted=$true
    $window=Wait-Window $setup 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$setup.Id,'Tailscale Quick Repair is ready.')) 'Unmodified candidate entry reports a successful version upgrade'
    Assert-Files $newPlan 'Real version upgrade installs all exact candidate files'
    Check ([SetupEntryProbe]::Click($window,$setup.Id,'OK')) 'Upgrade completion uses the real Setup dialog'
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'Actual standalone version upgrade exits successfully'
    Disable-OwnedTasks
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq $newVersion -and $installed.versionCode -eq $newCode -and
           $installed.versionCode -gt $oldCode) 'Installed metadata records the genuinely newer candidate'
    Check ((Digest $config) -ceq $configHash) 'Version transition preserves the entire configuration byte-for-byte'
    Check ((Native $newType 'ReadConfiguredPeer') -ceq 'fixture-device.invalid' -and [bool](Native $newType 'IsStartupEnabled')) 'Target and startup preferences survive the version transition'

    $stage='installed_candidate_activation'
    $watch=[Diagnostics.Stopwatch]::StartNew();$appProcess=$null
    while($watch.Elapsed.TotalSeconds -lt 20){
        $found=@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue)
        if($found.Count -gt 1){throw 'Unexpected resident process count.'}
        if($found.Count -eq 1){$appProcess=$found[0];break};Start-Sleep -Milliseconds 100
    }
    Check ($null -ne $appProcess) 'Candidate Setup itself launches the installed application'
    $appExe=Join-Path $app 'TailscaleQuickRepair.exe';Remember-Process $appProcess $appExe
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper' 60
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'The upgraded WPF application loads and responds'
    $watch=[Diagnostics.Stopwatch]::StartNew();$acknowledged=$false
    while($watch.Elapsed.TotalSeconds -lt 20){
        $pending=Get-ItemProperty -LiteralPath $productRegistry -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
        if(-not $pending -or $null -eq $pending.PendingRestartVersionCode){$acknowledged=$true;break}
        $appProcess.Refresh();if($appProcess.HasExited){break};Start-Sleep -Milliseconds 100
    }
    Check $acknowledged 'Upgraded application clears its restart acknowledgement'
    Check ([SetupEntryProbe]::Close($appWindow,$appProcess.Id)) 'Close targets only the upgraded owned window'
    $watch=[Diagnostics.Stopwatch]::StartNew();$hidden=$false
    while($watch.Elapsed.TotalSeconds -lt 10){
        $appProcess.Refresh();if($appProcess.HasExited){break}
        if([SetupEntryProbe]::Find($appProcess.Id,'Tailscale Quick Repair','HwndWrapper') -eq [IntPtr]::Zero){$hidden=$true;break}
        Start-Sleep -Milliseconds 100
    }
    Check $hidden 'The upgraded application remains resident after window close'
    $second=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName=$appExe;UseShellExecute=$false;WorkingDirectory=$app})
    if(-not $second.WaitForExit(10000)){Remember-Process $second $appExe;throw 'Secondary instance exceeded its bound.'}
    Check ($second.ExitCode -eq 0) 'Second candidate launch activates the existing instance'
    $appWindow=Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper'
    Check ([SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'The same upgraded window restores and responds'
    Check (@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue).Count -eq 1) 'Only one upgraded resident instance remains'

    $stage='downgrade_refusal'
    $older=Launch-Installer $oldExe $oldHash
    $window=Wait-Window $older 'Tailscale Quick Repair Setup'
    Check ([SetupEntryProbe]::Contains($window,$older.Id,'Setup will not downgrade it.')) 'The genuine predecessor installer refuses the newer installation'
    Check ([SetupEntryProbe]::Click($window,$older.Id,'OK')) 'Downgrade refusal targets only its owned window'
    Check ($older.WaitForExit(10000) -and $older.ExitCode -eq 10) 'Older installer returns its expected refusal code'
    Assert-Files $newPlan 'Downgrade refusal leaves all candidate files unchanged'
    Check ((Digest $config) -ceq $configHash) 'Upgrade, activation and downgrade refusal preserve complete configuration bytes'
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq $newVersion -and $installed.versionCode -eq $newCode) 'Candidate version remains installed after downgrade refusal'
    $appProcess.Refresh()
    Check (-not $appProcess.HasExited -and [SetupEntryProbe]::Responsive($appWindow,$appProcess.Id)) 'Downgrade refusal does not disturb the upgraded application'
    $downgradeRefused=$true;$passed=$true
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
        schema=1;passed=$passed;testSource=$env:GITHUB_SHA
        predecessorSource=[string]$oldPins.source;candidateSource=[string]$newPins.source
        predecessorVersion=$oldVersion;candidateVersion=$newVersion
        predecessorSha256=$oldHash;candidateSha256=$newHash;payloadSha256=$newZipHash
        cases=@($cases.ToArray());cleanupPassed=$cleanupPassed;failureType=$failure;failureReason=$failureReason;stage=$stage
        versionUpgradeExecuted=$upgradeExecuted;downgradeRefused=$downgradeRefused;competingOperationRefused=$leaseRefused
        controlledFileRollbackTested=$controlledRollbackTested;controlledRollbackPoints=$rollbackPointsPassed
        desktopElevationTested=$false;publicFeedVerified=$false;interruptedUpgradeTested=$false
        scope='Pinned RC12 seeded by its native installer methods; unchanged RC13 standalone process performs the version transition on an already elevated disposable Windows runner. Includes controlled exception rollback after each candidate file replacement, settings preservation, lease refusal, installed tray activation and real RC12 downgrade refusal. Process termination, power loss, secure-desktop consent and public delivery are not tested.'
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $report -Encoding UTF8
}
if(-not $passed -or -not $controlledRollbackTested -or $rollbackPointsPassed -ne 11){throw 'Version upgrade acceptance failed; typed evidence preserved.'}
Write-Host 'Pinned native version upgrade and downgrade refusal passed; desktop consent and delivery remain separate.'
