# Called only after the owned native lab has verified every engine recovery point.
# Hold the seventh target, then stop the unchanged standalone installer itself.
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
    & (Join-Path $PSScriptRoot 'test-replacement-pause.ps1')
    if($newPlan.Count -ne 11 -or $oldPlan.Count -ne 11){throw 'Fixed standalone recovery plans required.'}
    Assert-Files $oldPlan 'Pending entry starts from every exact predecessor file'
    Check (-not(Test-Path -LiteralPath $recovery)) 'Pending entry refuses any earlier recovery journal'
    $point=6
    $target=[string]$newPlan[$point].Target
    Require-UnlinkedPath $target
    Check ($target -ceq (Join-Path $app 'Tailscale-Repair-UI.ps1')) 'Pending entry holds only the seventh pinned file'
    $oldTargets=@{}
    foreach($file in $oldPlan){$oldTargets[$file.Target]=[string]$file.Sha256}
    $pause=$null;$interrupted=$null;$started=0
    try{
        $pause=[Tqr.Acceptance.ReplacementPause]::new($target)
        $interrupted=Launch-Installer $newExe $newHash
        $started=$interrupted.StartTime.ToUniversalTime().Ticks
        Check ($interrupted.MainModule.FileName -ieq $newExe -and (Digest $newExe) -ceq $newHash) 'Pending entry starts the unchanged standalone installer'
        Check ($pause.WaitForRequiredBreak(5000)) 'Pending entry reaches an acknowledgement-required replacement break'
        # A fresh read of the held target could block behind its outstanding
        # acknowledgement. Inspect other files now, and the full layout after death.
        $prefixMatches=$true;$changedPrefix=$false;$unchangedSuffix=$false
        for($i=0;$i -lt $newPlan.Count;$i++){
            if($i -eq $point){continue}
            $file=$newPlan[$i];Require-UnlinkedPath $file.Target
            $expected=if($i -lt $point){[string]$file.Sha256}else{[string]$oldTargets[$file.Target]}
            if((Digest $file.Target) -cne $expected){$prefixMatches=$false}
            if($oldTargets[$file.Target] -cne $file.Sha256){
                if($i -lt $point){$changedPrefix=$true}else{$unchangedSuffix=$true}
            }
        }
        $next=$target+'.setup.new';Require-UnlinkedPath $next
        Check ($prefixMatches -and $changedPrefix -and $unchangedSuffix -and
            (Digest $next) -ceq $newPlan[$point].Sha256) 'Pending entry observes six completed replacements before the held file'
        $journal=Join-Path $recovery 'transaction.json';Require-UnlinkedPath $journal
        $record=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
        $journalHash=Digest $journal
        Check ($record.state -ceq 'prepared' -and @($record.entries).Count -eq 11) 'Pending entry observes the complete prepared native journal'
        $interrupted.Refresh()
        Check (-not $interrupted.HasExited -and $interrupted.StartTime.ToUniversalTime().Ticks -eq $started -and
            $interrupted.MainModule.FileName -ieq $newExe -and $interrupted.Id -ne $PID -and
            (Digest $newExe) -ceq $newHash) 'Pending entry identifies only its owned standalone installer'
        $interrupted.Kill()
        Check ($interrupted.WaitForExit(5000)) 'Pending entry confirms standalone process death before releasing the hold'
        $pause.Dispose();$pause=$null
        $mixedPlan=$true
        for($i=0;$i -lt $newPlan.Count;$i++){
            $file=$newPlan[$i];Require-UnlinkedPath $file.Target
            $expected=if($i -lt $point){[string]$file.Sha256}else{[string]$oldTargets[$file.Target]}
            if((Digest $file.Target) -cne $expected){$mixedPlan=$false}
        }
        Check ($mixedPlan -and $changedPrefix -and $unchangedSuffix) 'Pending entry proves a genuinely mixed predecessor and candidate layout'
        Check ((Digest $journal) -ceq $journalHash -and (Digest $config) -ceq $configHash -and
            (Digest $next) -ceq $newPlan[$point].Sha256) 'Pending entry preserves the interrupted journal and settings for Setup'
        $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
        Check ($installed.version -ceq $oldVersion -and $installed.versionCode -eq $oldCode) 'Pending entry retains predecessor version identity before normal Setup'
        return [int]$point
    }finally{
        if($pause){
            try{
                if($interrupted){
                    $interrupted.Refresh()
                    if(-not $interrupted.HasExited){
                        if($interrupted.StartTime.ToUniversalTime().Ticks -ne $started -or
                           $interrupted.MainModule.FileName -ine $newExe -or $interrupted.Id -eq $PID){
                            throw 'Standalone cleanup identity changed.'
                        }
                        $interrupted.Kill()
                    }
                }
            }finally{$pause.Dispose()}
        }
        # The enclosing lab waits for recorded owned processes on failure.
        # Neither this helper nor its cleanup restores files or removes journals.
    }
}
