# Called only from the owned native lab after every process-recovery point passes.
# Leave one real interrupted transaction for the unchanged standalone entry.
function New-PinnedPendingStandaloneJournal {
    if(-not $owned -or -not $controlledRollbackTested -or $rollbackPointsPassed -ne 11 -or
       -not $processFileRecoveryTested -or $processRecoveryPoints -ne 11 -or -not $leaseRefused -or $leaseType -or
       $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
       $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
       $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
       $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
       $env:GITHUB_REF_NAME -notin @('main','work/public') -or
       $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
       $PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Owned standalone recovery boundary refused.'}
    $null=& python -B (Join-Path $PSScriptRoot 'prepare-clean-upgrade.py') verify $InputDirectory
    if($LASTEXITCODE -ne 0){throw 'Standalone recovery inputs failed verification.'}
    if($newPlan.Count -ne 11 -or $oldPlan.Count -ne 11){throw 'Fixed standalone recovery plans required.'}
    & (Join-Path $PSScriptRoot 'test-replacement-pause.ps1')
    Assert-Files $oldPlan 'Pending entry starts from every exact predecessor file'
    Check (-not(Test-Path -LiteralPath $recovery)) 'Pending entry refuses any earlier recovery journal'
    $point=6
    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childScript=Join-Path $PSScriptRoot 'test-setup-transaction-child.ps1'
    Require-UnlinkedPath $hostPath
    Require-UnlinkedPath $childScript
    Require-UnlinkedPath $work
    $owner=[Diagnostics.Process]::GetCurrentProcess()
    $nonce=[Guid]::NewGuid().ToString('N')
    $ready=$null;$proceed=$null
    try{
        $created=$false
        $ready=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,('Local\TqrTxnReady-'+$nonce),[ref]$created)
        if(-not $created){throw 'Existing standalone readiness event refused.'}
        $created=$false
        $proceed=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,('Local\TqrTxnProceed-'+$nonce),[ref]$created)
        if(-not $created){throw 'Existing standalone continuation event refused.'}
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$childScript,
            '-Mode','apply','-Checkpoint',[string]$point,'-InputDirectory',$InputDirectory,'-WorkDirectory',$work)
        foreach($argument in $arguments){if($argument.Contains('"') -or $argument.Contains("`r") -or $argument.Contains("`n")){throw 'Standalone child argument refused.'}}
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=$hostPath;$info.Arguments=($arguments|ForEach-Object {'"'+$_+'"'}) -join ' '
        $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.EnvironmentVariables['TQR_CRASH_NONCE']=$nonce
        $info.EnvironmentVariables['TQR_CRASH_OWNER']=[string]$PID
        $info.EnvironmentVariables['TQR_CRASH_OWNER_STARTED']=[string]$owner.StartTime.ToUniversalTime().Ticks
        $info.EnvironmentVariables['TQR_CRASH_WORK']=$work
        $apply=[Diagnostics.Process]::Start($info)
        Remember-Process $apply $hostPath
        $started=$apply.StartTime.ToUniversalTime().Ticks
        Check ($ready.WaitOne(20000)) 'Pending entry reaches the sixth real replacement callback'
        $oldTargets=@{}
        foreach($file in $oldPlan){$oldTargets[$file.Target]=[string]$file.Sha256}
        $mixedPlan=$true;$changedPrefix=$false;$unchangedSuffix=$false
        for($i=0;$i -lt $newPlan.Count;$i++){
            $file=$newPlan[$i];Require-UnlinkedPath $file.Target
            $expected=if($i -lt $point){[string]$file.Sha256}else{[string]$oldTargets[$file.Target]}
            if((Digest $file.Target) -cne $expected){$mixedPlan=$false}
            if($oldTargets[$file.Target] -cne $file.Sha256){
                if($i -lt $point){$changedPrefix=$true}else{$unchangedSuffix=$true}
            }
        }
        Check ($mixedPlan -and $changedPrefix -and $unchangedSuffix) 'Pending entry proves a genuinely mixed predecessor and candidate layout'
        $journal=Join-Path $recovery 'transaction.json';Require-UnlinkedPath $journal
        $record=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
        $journalHash=Digest $journal
        Check ($record.state -ceq 'prepared' -and @($record.entries).Count -eq 11) 'Pending entry observes the complete prepared native journal'
        $apply.Refresh()
        Check (-not $apply.HasExited -and $apply.StartTime.ToUniversalTime().Ticks -eq $started -and
            $apply.MainModule.FileName -ieq $hostPath -and $apply.Id -ne $PID) 'Pending entry identifies only its owned transaction process'
        $apply.Kill()
        Check ($apply.WaitForExit(5000)) 'Pending entry confirms process death without exception unwinding'
        Check ((Digest $journal) -ceq $journalHash -and (Digest $config) -ceq $configHash -and
            (Digest $newPlan[$point-1].Target) -ceq $newPlan[$point-1].Sha256) 'Pending entry preserves the interrupted journal and settings for Setup'
        $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
        Check ($installed.version -ceq $oldVersion -and $installed.versionCode -eq $oldCode) 'Pending entry retains predecessor version identity before normal Setup'
        return [int]$point
    }finally{
        if($ready){$ready.Dispose()};if($proceed){$proceed.Dispose()}
        # Only the enclosing lab cleans recorded process identities on failure.
        # No files are restored and no recovery record is removed here.
    }
}
