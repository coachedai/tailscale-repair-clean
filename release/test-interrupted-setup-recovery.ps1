param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory='.\upgrade-evidence'
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/3.0')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
   $env:RUNNER_ARCH -cne 'X64' -or $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $releaseValidation) -or $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or
   -not $env:GITHUB_RUN_ID -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Interrupted Setup lab requires a disposable native Windows runner.'}

$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   (git -C $repo remote get-url origin).Trim() -notmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$' -or
   ((Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish -and -not $releaseValidation)){
    throw 'Exact isolated source is required.'
}
$publishMetadata=Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json
$candidateChannel=[string]$publishMetadata.channel
if($candidateChannel -notin @('stable','preview')){throw 'Interrupted Setup candidate channel is invalid.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrInterruptedSetup-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($lab)
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$recovery=Join-Path $env:ProgramData 'TailscaleQuickRepair.SetupRecovery'
$taskNames=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false;$cleanup=$true;$child=$null;$failure=$null;$stage='preflight'
$legacyHash='bad4deb522afd9442e918cacde1f58cc1509635de3be172626846060516df470'
function Check([bool]$Value,[string]$Name){$script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value});if(-not $Value){throw 'Interrupted Setup assertion failed.'};Write-Host ('PASS interrupted Setup: '+$Name)}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Expand-Verified([string]$Zip,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try{
        $total=0L
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/');if($name.EndsWith('/')){continue}
            $total+=$entry.Length
            if($name -match '(^/|:|(^|/)\.{1,2}(/|$))' -or -not $seen.Add($name) -or $total -gt 12MB -or $seen.Count -gt 96){throw 'Unsafe or oversized package.'}
        }
    }finally{$archive.Dispose()}
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination
    $manifest=Get-Content (Join-Path $Destination 'package-manifest.json') -Raw|ConvertFrom-Json
    if($manifest.schema -ne 1 -or $seen.Count -ne @($manifest.files).Count+1){throw 'Package envelope mismatch.'}
    foreach($f in $manifest.files){
        $name=([string]$f.path).Replace('\','/');$p=Join-Path $Destination $name
        if(-not $seen.Contains($name) -or (Get-Item $p).Length -ne $f.size -or (Hash $p) -cne ([string]$f.sha256).ToLowerInvariant()){throw 'Package file verification failed.'}
    }
    return $manifest
}
function Run-Child(
    [string]$Phase,
    [string]$Package,
    [int]$PauseAfter=0,
    [string]$Ready='',
    [switch]$ExpectKill,
    [string]$Peer='integration-replay.invalid',
    [bool]$Startup=$true,
    [long]$VersionCode=0
){
    $report=Join-Path $lab ($Phase+'-'+[Guid]::NewGuid().ToString('N')+'.json')
    $work=Join-Path $lab ($Phase+'-work-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "'+(Join-Path $PSScriptRoot 'interrupted-setup-child.ps1')+
        '" -Phase '+$Phase+' -Package "'+$Package+'" -Work "'+$work+'" -PauseAfter '+$PauseAfter+
        ' -Ready "'+$Ready+'" -Peer "'+$Peer+'" -Startup '+$Startup.ToString().ToLowerInvariant()+
        ' -VersionCode '+$VersionCode+' -Channel '+$candidateChannel+' -Report "'+$report+'"'
    $script:child=[Diagnostics.Process]::Start($psi)
    if($ExpectKill){
        $deadline=[DateTime]::UtcNow.AddSeconds(45)
        while(-not(Test-Path -LiteralPath $Ready) -and -not $script:child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
        if(-not(Test-Path -LiteralPath $Ready)){throw ($Phase+' child did not reach the owned kill boundary.')}
        Check (-not $script:child.HasExited) ($Phase+' child is still active at the owned kill boundary')
        $script:child.Kill();[void]$script:child.WaitForExit(10000)
        Check $script:child.HasExited ($Phase+' child was terminated only after its explicit fixture marker')
        $script:child.Dispose();$script:child=$null
        return $null
    }
    if(-not $script:child.WaitForExit(120000)){throw ($Phase+' child exceeded its bound; no rerun.')}
    $result=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
    Copy-Item $report (Join-Path $evidence ([IO.Path]::GetFileName($report)))
    Check ($script:child.ExitCode -eq 0 -and $result.passed -is [bool] -and $result.passed -and $result.source -ceq $env:GITHUB_SHA) ($Phase+' child completed its recorded boundary')
    $script:child.Dispose();$script:child=$null
    return $result
}
try{
    Check (-not(Test-Path $app) -and -not(Test-Path $program) -and -not(Test-Path $recovery) -and -not(Get-Service Tailscale -ErrorAction SilentlyContinue)) 'Interrupted Setup lab starts with empty owned product and recovery roots'
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
    foreach($name in $taskNames){$exists=$false;try{[void]$folder.GetTask($name);$exists=$true}catch{};Check (-not $exists) 'No existing product task is reused'}

    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url='https://github.com/coachedai/tailscale-repair-clean/releases/download/v3.0.0-phase5.2.1/TailscaleQuickRepair-SetupPackage-3.0.0-phase5.2.1.zip'
    $legacyZip=Join-Path $lab 'published-5.2.1.zip'
    $wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','TqrInterruptedSetupAcceptance');$wc.DownloadFile($url,$legacyZip);$wc.Dispose()
    Check ((Get-Item $legacyZip).Length -eq 140164 -and (Hash $legacyZip) -ceq $legacyHash) 'Published 5.2.1 package matches its pinned exact release digest'

    $legacy=Join-Path $lab 'legacy';$legacyManifest=Expand-Verified $legacyZip $legacy
    Check ($legacyManifest.version -ceq '3.0.0-phase5.2.1') 'Baseline is the genuine published 5.2.1 payload'

    $setupZip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*SetupPackage-*.zip' -File)
    Check ($setupZip.Count -eq 1) 'Exactly one upstream-tested protected candidate is reused'
    $candidate=Join-Path $lab 'candidate';$candidateManifest=Expand-Verified $setupZip[0].FullName $candidate

    [void](Run-Child 'InstallLegacy' $legacy)
    [void](Run-Child 'LegacyIntegration' $legacy)
    Check ((Test-Path -LiteralPath $app -PathType Container) -and (Test-Path -LiteralPath $program -PathType Container)) 'Published baseline files are installed by their compiled Setup core'
    $legacyAuto=$folder.GetTask($taskNames[1])
    Check ($legacyAuto.Definition.Triggers.Count -eq 1 -and
        $legacyAuto.Definition.Triggers.Item(1).Repetition.Interval -ceq 'PT5M') 'Published 5.2.1 automatic task is installed before interruption testing'
    $legacyRun=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$false)
    try{$legacyStartup=if($legacyRun){$legacyRun.GetValue('Tailscale Quick Repair',$null)}else{$null}}finally{if($legacyRun){$legacyRun.Dispose()}}
    Check ($null -eq $legacyStartup) 'Published baseline integration keeps the fixture startup preference off'

    $candidateType=[Reflection.Assembly]::LoadFile((Join-Path $candidate 'app\TailscaleQuickRepairSetup.exe')).GetType('PublicSetupHost')
    $resolve=$candidateType.GetMethod('ResolveInstallTarget',[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $resolve){throw 'Candidate target resolver unavailable.'}

    $baseline=@{}
    $changedIndex=0;$changedTarget='';$changedSha='';$index=0
    foreach($f in $candidateManifest.files){
        $index++
        $target=[string]$resolve.Invoke($null,@([string]$f.path))
        $exists=Test-Path -LiteralPath $target -PathType Leaf
        $oldHash=if($exists){Hash $target}else{'absent'}
        $baseline[[string]$f.path]=[pscustomobject]@{target=$target;existed=$exists;sha=$oldHash}
        if($changedIndex -eq 0 -and (-not $exists -or $oldHash -cne ([string]$f.sha256).ToLowerInvariant())){
            $changedIndex=$index;$changedTarget=$target;$changedSha=([string]$f.sha256).ToLowerInvariant()
        }
    }
    Check ($changedIndex -gt 0) 'Candidate contains at least one real payload change from published 5.2.1'

    function Test-BaselineRestored {
        foreach($entry in $candidateManifest.files){
            $before=$baseline[[string]$entry.path]
            if($before.existed){
                if(-not(Test-Path -LiteralPath $before.target -PathType Leaf) -or (Hash $before.target) -cne $before.sha){return $false}
            }elseif(Test-Path -LiteralPath $before.target){return $false}
        }
        return $true
    }
    function Test-CandidateInstalled {
        foreach($entry in $candidateManifest.files){
            $target=[string]$resolve.Invoke($null,@([string]$entry.path))
            if(-not(Test-Path -LiteralPath $target -PathType Leaf) -or (Hash $target) -cne ([string]$entry.sha256).ToLowerInvariant()){return $false}
        }
        return $true
    }

    # Scenario 1: kill Setup after a real changed-file replacement, then kill
    # rollback itself after one restored entry. A third process must restore all.
    $applyReady=Join-Path $lab 'apply-first.ready'
    [void](Run-Child 'ApplyPause' $candidate $changedIndex $applyReady -ExpectKill)
    Check (Test-Path -LiteralPath (Join-Path $recovery 'transaction.json') -PathType Leaf) 'Killed Setup leaves its protected persistent recovery journal'
    Check ((Test-Path -LiteralPath $changedTarget -PathType Leaf) -and (Hash $changedTarget) -ceq $changedSha) 'Killed Setup occurred after the selected changed file was actually replaced'

    $journalPath=Join-Path $recovery 'transaction.json'
    $journalRaw=Get-Content -LiteralPath $journalPath -Raw
    $journal=$journalRaw|ConvertFrom-Json
    $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Check ($journal.schema -eq 1 -and $journal.state -ceq 'prepared' -and
        [string]$journal.userSid -ceq $currentSid -and
        @($journal.entries).Count -eq @($candidateManifest.files).Count) 'Recovery journal covers the complete candidate file set and initiating Windows account before mutation'

    # The recovery root is machine-wide, but app targets are per-user. A journal
    # from another Windows account must be refused before any target is touched.
    $differentSid=if($currentSid -cne 'S-1-5-18'){'S-1-5-18'}else{'S-1-5-32-544'}
    $ownerField='"userSid":"'+$currentSid+'"'
    Check ($journalRaw.Contains($ownerField)) 'Prepared recovery journal contains exactly the initiating SID field'
    $tampered=$journalRaw.Replace($ownerField,('"userSid":"'+$differentSid+'"'))
    Check ($tampered -cne $journalRaw) 'Cross-user recovery fixture changes only the journal owner value'
    [IO.File]::WriteAllText($journalPath,$tampered,(New-Object Text.UTF8Encoding($false)))
    $changedBeforeRefusal=Hash $changedTarget
    [void](Run-Child 'RecoverRefuse' $candidate)
    Check ((Test-Path -LiteralPath $journalPath -PathType Leaf) -and
        (Hash $changedTarget) -ceq $changedBeforeRefusal) 'Another Windows account is refused without changing the candidate file or deleting recovery evidence'
    [IO.File]::WriteAllText($journalPath,$journalRaw,(New-Object Text.UTF8Encoding($false)))
    Check ([IO.File]::ReadAllText($journalPath) -ceq $journalRaw) 'Original same-user recovery journal is restored exactly for the remaining kill tests'

    $recoverReady=Join-Path $lab 'recover-first.ready'
    [void](Run-Child 'RecoveryPause' $candidate 1 $recoverReady -ExpectKill)
    Check (Test-Path -LiteralPath (Join-Path $recovery 'transaction.json') -PathType Leaf) 'Killing recovery preserves the same prepared transaction for another attempt'
    [void](Run-Child 'Recover' $candidate)
    Check (-not(Test-Path -LiteralPath $recovery)) 'Retry after killed restore removes only the completed recovery transaction'
    Check (Test-BaselineRestored) 'Third process restores every published baseline file hash and removes candidate-only files'

    # Scenario 2: kill again, but this time allow all old files to restore and
    # kill after the rolledBack journal is durable and one backup is deleted.
    $applyReady2=Join-Path $lab 'apply-rollback-cleanup.ready'
    [void](Run-Child 'ApplyPause' $candidate $changedIndex $applyReady2 -ExpectKill)
    $rollbackReady=Join-Path $lab 'rollback-cleanup.ready'
    [void](Run-Child 'RecoveryPause' $candidate -1001 $rollbackReady -ExpectKill)
    $rolledJournal=Get-Content (Join-Path $recovery 'transaction.json') -Raw|ConvertFrom-Json
    Check ($rolledJournal.state -ceq 'rolledBack') 'Rollback cleanup kill occurs only after the restored old file set is durably marked rolledBack'
    Check (Test-BaselineRestored) 'All baseline file hashes are already restored before rollback backup cleanup'
    $expectedBackups=@($rolledJournal.entries|Where-Object {$_.existed}).Count
    $remainingBackups=@(Get-ChildItem -LiteralPath $recovery -Filter '*.bak' -File).Count
    Check ($expectedBackups -gt 0 -and $remainingBackups -lt $expectedBackups) 'Rollback cleanup was killed after at least one verified backup had already been removed'
    [void](Run-Child 'Recover' $candidate)
    Check (-not(Test-Path -LiteralPath $recovery) -and (Test-BaselineRestored)) 'Next process finishes rolled-back cleanup without requiring an already deleted backup'

    # Scenario 3: complete the candidate payload, durably mark it committed,
    # delete one old backup, then kill Setup. Recovery must keep the verified new
    # payload and only finish its interrupted cleanup.
    $commitReady=Join-Path $lab 'commit-cleanup.ready'
    [void](Run-Child 'ApplyPause' $candidate -2001 $commitReady -ExpectKill)
    $committedJournal=Get-Content (Join-Path $recovery 'transaction.json') -Raw|ConvertFrom-Json
    Check ($committedJournal.state -ceq 'committed') 'Commit cleanup kill occurs only after the entire new payload is durably marked committed'
    Check (Test-CandidateInstalled) 'Every candidate manifest file has its expected SHA-256 before committed cleanup resumes'
    $expectedCommittedBackups=@($committedJournal.entries|Where-Object {$_.existed}).Count
    $remainingCommittedBackups=@(Get-ChildItem -LiteralPath $recovery -Filter '*.bak' -File).Count
    Check ($expectedCommittedBackups -gt 0 -and $remainingCommittedBackups -lt $expectedCommittedBackups) 'Committed cleanup was killed after at least one old backup had already been removed'
    [void](Run-Child 'Recover' $candidate)
    Check (-not(Test-Path -LiteralPath $recovery) -and (Test-CandidateInstalled)) 'Next process keeps the committed candidate payload and finishes cleanup without a deleted backup'

    # Scenario 4: the candidate payload is already committed but Windows
    # integration is interrupted. The same fixed sequence must be safe to replay
    # from a fresh Setup process without rolling the payload backwards.
    $integrationPeer='integration-replay.invalid'
    $markerPath=Join-Path $app 'protected-update.json'
    $markerText=([ordered]@{schema=2;versionCode=[int64]$candidateManifest.versionCode;channel=$candidateChannel}|ConvertTo-Json -Compress)
    [IO.File]::WriteAllText($markerPath,$markerText,(New-Object Text.UTF8Encoding($false)))
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction SilentlyContinue

    $earlyReady=Join-Path $lab 'integration-early.ready'
    [void](Run-Child -Phase 'IntegrationPause' -Package $candidate -PauseAfter 2 -Ready $earlyReady -ExpectKill -Peer $integrationPeer -Startup $true -VersionCode ([int64]$candidateManifest.versionCode))

    $earlyConfig=Get-Content (Join-Path $app 'config.json') -Raw|ConvertFrom-Json
    $earlyAuto=$folder.GetTask($taskNames[1])
    $earlyRun=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$false)
    try{$earlyStartup=if($earlyRun){$earlyRun.GetValue('Tailscale Quick Repair',$null)}else{$null}}finally{if($earlyRun){$earlyRun.Dispose()}}
    $earlyRestart=Get-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction SilentlyContinue
    Check ([string]$earlyConfig.peer -ceq $integrationPeer) 'Killed integration preserves the completed target update'
    Check ($earlyAuto.Definition.Triggers.Count -eq 1) 'Kill after repair-task replacement leaves the still-unmodified 5.2.1 automatic task visible'
    Check ($null -eq $earlyStartup) 'Kill before startup integration leaves the previous startup preference unchanged'
    Check ((Test-Path -LiteralPath $markerPath -PathType Leaf) -and (-not $earlyRestart -or $null -eq $earlyRestart.PendingRestartVersionCode)) 'Early integration kill keeps the handoff marker and cannot claim restart completion'
    Check (Test-CandidateInstalled) 'Early integration kill never rolls the already committed candidate payload backwards'

    [void](Run-Child -Phase 'IntegrationComplete' -Package $candidate -Peer $integrationPeer -Startup $true -VersionCode ([int64]$candidateManifest.versionCode))

    $repairTask=$folder.GetTask($taskNames[0]);$autoTask=$folder.GetTask($taskNames[1])
    Check ($repairTask.Definition.Triggers.Count -eq 0 -and $autoTask.Definition.Triggers.Count -eq 4 -and
        $autoTask.Definition.Triggers.Item(1).Repetition.Interval -ceq 'PT5M' -and
        -not [bool]$autoTask.Definition.Settings.StartWhenAvailable) 'Fresh Setup replay converges both tasks to the current protected definitions'
    $runKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$false)
    try{$startupValue=if($runKey){[string]$runKey.GetValue('Tailscale Quick Repair',$null)}else{''}}finally{if($runKey){$runKey.Dispose()}}
    $expectedStartup='"'+(Join-Path $app 'TailscaleQuickRepair.exe')+'" --start-in-tray'
    Check ($startupValue -ceq $expectedStartup) 'Integration replay applies the requested startup preference exactly'
    $shortcut=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'Tailscale Quick Repair.lnk'
    $shell=New-Object -ComObject WScript.Shell;$link=$null
    try{$link=$shell.CreateShortcut($shortcut);$shortcutTarget=[string]$link.TargetPath}finally{
        if($link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
        if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    }
    Check ((Test-Path -LiteralPath $shortcut -PathType Leaf) -and
        [IO.Path]::GetFullPath($shortcutTarget) -ieq [IO.Path]::GetFullPath((Join-Path $app 'TailscaleQuickRepair.exe'))) 'Integration replay leaves the Start menu shortcut targeting the installed app'
    $restartKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\TailscaleQuickRepair',$false)
    try{
        if(-not $restartKey){throw 'Restart acknowledgement key is missing.'}
        $restartValue=$restartKey.GetValue('PendingRestartVersionCode',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $restartKind=$restartKey.GetValueKind('PendingRestartVersionCode')
    }finally{if($restartKey){$restartKey.Dispose()}}
    Check ($restartKind -eq [Microsoft.Win32.RegistryValueKind]::QWord -and
        [int64]$restartValue -eq [int64]$candidateManifest.versionCode -and
        -not(Test-Path -LiteralPath $markerPath)) 'Completed replay writes the exact restart acknowledgement before clearing the handoff marker'
    Check (Test-CandidateInstalled) 'Integration replay leaves every committed candidate payload hash unchanged'

    # Late interruption: restart acknowledgement is durable, but the marker
    # remains because Setup has not crossed its final completion step.
    [IO.File]::WriteAllText($markerPath,$markerText,(New-Object Text.UTF8Encoding($false)))
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction SilentlyContinue
    $lateReady=Join-Path $lab 'integration-late.ready'
    [void](Run-Child -Phase 'IntegrationPause' -Package $candidate -PauseAfter 6 -Ready $lateReady -ExpectKill -Peer $integrationPeer -Startup $true -VersionCode ([int64]$candidateManifest.versionCode))
    $lateRestart=Get-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction Stop
    Check ([int64]$lateRestart.PendingRestartVersionCode -eq [int64]$candidateManifest.versionCode -and
        (Test-Path -LiteralPath $markerPath -PathType Leaf)) 'Late integration kill preserves both the exact restart acknowledgement and unfinished handoff marker'
    Check (Test-CandidateInstalled) 'Late integration kill also leaves the committed payload untouched'

    [void](Run-Child -Phase 'IntegrationComplete' -Package $candidate -Peer $integrationPeer -Startup $true -VersionCode ([int64]$candidateManifest.versionCode))
    Check (-not(Test-Path -LiteralPath $markerPath) -and (Test-CandidateInstalled)) 'Fresh Setup process safely replays late integration and clears the marker only at final completion'

    # Remove only fixture-owned Windows integration after all assertions so the
    # following protected-handoff suite starts from an empty product footprint.
    foreach($name in $taskNames){try{$folder.DeleteTask($name,0)}catch{}}
    $cleanupRun=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{$cleanupRun.DeleteValue('Tailscale Quick Repair',$false)}finally{$cleanupRun.Dispose()}
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
    foreach($name in $taskNames){$exists=$false;try{[void]$folder.GetTask($name);$exists=$true}catch{};Check (-not $exists) 'Only fixture-owned Quick Repair tasks are removed after integration replay acceptance'}

    # Preserve the final candidate installation intact, but move it out of the
    # product paths so the following handoff test starts from an empty install.
    $appArchive=Join-Path (Split-Path -Parent $app) ('TqrInterruptedEvidence-'+[Guid]::NewGuid().ToString('N'))
    $programArchive=Join-Path (Split-Path -Parent $program) ('TqrInterruptedEvidence-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::Move($app,$appArchive)
    [IO.Directory]::Move($program,$programArchive)
    Check ((-not(Test-Path -LiteralPath $app)) -and (-not(Test-Path -LiteralPath $program))) 'Recovered/committed fixture is preserved by same-volume rename before the next independent compatibility test'

    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($child){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)}}catch{$cleanup=$false};$child.Dispose()}
    $cases.Add([pscustomobject]@{name='Interrupted Setup lab kills only its explicitly owned child processes; failed file evidence remains on the disposable runner';passed=$cleanup})
    [pscustomobject]@{passed=($passed -and $cleanup);source=$env:GITHUB_SHA;fromVersion='3.0.0-phase5.2.1';cases=@($cases.ToArray());failure=$failure;
      scope='Persistent payload-file recovery plus replay-safe post-file Windows integration after killed Setup processes';
      limits=@('Post-file integration converges to the candidate state rather than rolling task/startup/shortcut state back to 5.2.1','This does not simulate whole-PC power loss or storage-controller write loss','Physical UAC/relaunch behavior remains a separate gate','No live tailnet or user machine is touched','Recovery journal contains only fixed package-relative paths and file digest metadata')}|
      ConvertTo-Json -Depth 9|Set-Content (Join-Path $evidence 'interrupted-setup-results.json') -Encoding UTF8
}
if(-not $passed -or -not $cleanup){throw 'Interrupted Setup recovery acceptance failed; inspect preserved evidence.'}
