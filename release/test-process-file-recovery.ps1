# Loaded only after the enclosing native lab establishes an owned predecessor.
function Invoke-PinnedProcessFileRecovery {
    if(-not $owned -or -not $controlledRollbackTested -or $rollbackPointsPassed -ne 11 -or $leaseType -or
       $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
       $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
       $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
       $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
       $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
       $PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Owned recovery preconditions missing.'}
    & (Join-Path $PSScriptRoot 'test-process-result.ps1')
    # Keep verifier status text out of the integer result; its exit code remains mandatory.
    $null = & python -B (Join-Path $PSScriptRoot 'prepare-clean-upgrade.py') verify $InputDirectory
    if($LASTEXITCODE -ne 0){throw 'Process recovery input verification failed.'}
    if($newPlan.Count -ne 11 -or $oldPlan.Count -ne 11){throw 'Fixed file plans required.'}
    $childScript=Join-Path $PSScriptRoot 'test-setup-transaction-child.ps1'
    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Require-UnlinkedPath $childScript
    Require-UnlinkedPath $work
    $owner=[Diagnostics.Process]::GetCurrentProcess()
    $points=0
    for($point=1;$point -le 11;$point++){
        Assert-Files $oldPlan ('Process point '+$point+' begins with exact predecessor files')
        Check (-not(Test-Path -LiteralPath $recovery)) ('Process point '+$point+' has no earlier recovery evidence')
        $nonce=[Guid]::NewGuid().ToString('N')
        $ready=$null;$proceed=$null
        try{
            $created=$false
            $ready=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,('Local\TqrTxnReady-'+$nonce),[ref]$created)
            if(-not $created){throw 'Existing readiness event refused.'}
            $created=$false
            $proceed=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,('Local\TqrTxnProceed-'+$nonce),[ref]$created)
            if(-not $created){throw 'Existing continuation event refused.'}
            function Launch-TransactionChild([string]$Mode){
                if($Mode -cnotin @('apply','recover')){throw 'Child operation refused.'}
                $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$childScript,
                    '-Mode',$Mode,'-Checkpoint',[string]$point,'-InputDirectory',$InputDirectory,'-WorkDirectory',$work)
                foreach($argument in $arguments){if($argument.Contains('"') -or $argument.Contains("`r") -or $argument.Contains("`n")){throw 'Child argument refused.'}}
                $info=[Diagnostics.ProcessStartInfo]::new()
                $info.FileName=$hostPath;$info.Arguments=($arguments|ForEach-Object {'"'+$_+'"'}) -join ' '
                $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
                $info.EnvironmentVariables['TQR_CRASH_NONCE']=$nonce
                $info.EnvironmentVariables['TQR_CRASH_OWNER']=[string]$PID
                $info.EnvironmentVariables['TQR_CRASH_OWNER_STARTED']=[string]$owner.StartTime.ToUniversalTime().Ticks
                $info.EnvironmentVariables['TQR_CRASH_WORK']=$work
                $process=[Diagnostics.Process]::Start($info)
                Remember-Process $process $hostPath
                return $process
            }
            $apply=Launch-TransactionChild 'apply'
            $applyStarted=$apply.StartTime.ToUniversalTime().Ticks
            Check ($ready.WaitOne(20000)) ('Process point '+$point+' reaches its actual replacement callback')
            $journal=Join-Path $recovery 'transaction.json'
            Require-UnlinkedPath $journal
            $record=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
            $journalHash=Digest $journal
            Check ($record.state -ceq 'prepared' -and @($record.entries).Count -eq 11 -and
                (Digest $newPlan[$point-1].Target) -ceq $newPlan[$point-1].Sha256) ('Process point '+$point+' observes durable recovery metadata and candidate bytes')
            $apply.Refresh()
            Check (-not $apply.HasExited -and $apply.StartTime.ToUniversalTime().Ticks -eq $applyStarted -and
                $apply.MainModule.FileName -ieq $hostPath -and $apply.Id -ne $PID) ('Process point '+$point+' identifies only its owned transaction process')
            $apply.Kill()
            Check ($apply.WaitForExit(5000)) ('Process point '+$point+' confirms forced process termination')
            Check ((Digest $journal) -ceq $journalHash -and
                (Digest $newPlan[$point-1].Target) -ceq $newPlan[$point-1].Sha256) ('Process point '+$point+' retains interrupted state without exception rollback')
            Check ((Digest $config) -ceq $configHash) ('Process point '+$point+' preserves settings at termination')
            [void]$ready.Reset()
            $restore=Launch-TransactionChild 'recover'
            Check ($ready.WaitOne(20000) -and $restore.StartTime.ToUniversalTime().Ticks -ne $applyStarted) ('Process point '+$point+' reacquires the native lease in a fresh process')
            [void]$proceed.Set()
            Check ($restore.WaitForExit(20000) -and $restore.ExitCode -eq 0) ('Process point '+$point+' finishes the actual native recovery entry')
            Assert-Files $oldPlan ('Process point '+$point+' restores every exact predecessor file')
            Check ((Digest $config) -ceq $configHash) ('Process point '+$point+' preserves complete settings after recovery')
            $temporaryAbsent=$true
            foreach($file in $newPlan){foreach($suffix in @('.setup.new','.setup.recover')){
                if(Test-Path -LiteralPath ($file.Target+$suffix)){$temporaryAbsent=$false}
            }}
            Check ($temporaryAbsent -and -not(Test-Path -LiteralPath $recovery)) ('Process point '+$point+' lets native recovery finish its own cleanup')
            $points++
        }finally{
            if($ready){$ready.Dispose()};if($proceed){$proceed.Dispose()}
            # The enclosing lab stops only recorded process identities and keeps
            # failed on-disk fixtures. No file or journal is repaired by this test.
        }
    }
    Check ($points -eq 11) 'All candidate file boundaries pass fresh-process recovery'
    return [int]$points
}
