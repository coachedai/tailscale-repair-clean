#!/usr/bin/env python3
"""Offline contracts for owned process termination; not native acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


def validate(main, driver, child):
    def needs(source, *terms):
        for term in terms:
            if term not in source:
                raise AssertionError('Required process recovery boundary absent')

    stages = [main.index("$stage='" + name + "'") for name in
              ('seed_predecessor', 'controlled_file_rollback', 'process_file_recovery',
               'held_operation_refusal', 'actual_version_upgrade')]
    if stages != sorted(stages):
        raise AssertionError('Recovery stage order changed')
    needs(main, 'test-process-recovery-boundaries.py', 'test-process-file-recovery.ps1',
          '$processRecoveryPoints=Invoke-PinnedProcessFileRecovery',
          '$processFileRecoveryTested=$false;$processRecoveryPoints=0',
          '-not $processFileRecoveryTested -or $processRecoveryPoints -ne 11')
    needs(driver, '-not $owned', '-not $controlledRollbackTested', '$rollbackPointsPassed -ne 11',
          'github-hosted', 'GITHUB_REPOSITORY_ID', 'TQR_NATIVE_LAB_RUN', 'PSEdition',
          'prepare-clean-upgrade.py', 'if($LASTEXITCODE -ne 0)',
          'for($point=1;$point -le 11;$point++)', '$points -eq 11',
          'Remember-Process $process $hostPath', '$apply.Kill()', '$apply.WaitForExit(5000)',
          '$apply.StartTime.ToUniversalTime().Ticks -eq $applyStarted',
          '$apply.MainModule.FileName -ieq $hostPath', '$apply.Id -ne $PID',
          '$ready.WaitOne(20000)', '$restore.WaitForExit(20000)', '$restore.ExitCode -eq 0',
          '$restore.StartTime.ToUniversalTime().Ticks -ne $applyStarted')
    needs(driver, "'prepared'", '@($record.entries).Count -eq 11',
          '(Digest $journal) -ceq $journalHash', 'Assert-Files $oldPlan',
          '(Digest $config) -ceq $configHash', "@('.setup.new','.setup.recover')",
          'native recovery finish its own cleanup')
    for guard in ('github-hosted', 'GITHUB_REPOSITORY_ID', 'TQR_NATIVE_LAB_RUN',
                  'TQR_CRASH_NONCE', 'TQR_CRASH_OWNER_STARTED',
                  'prepare-clean-upgrade.py', 'Child installer integrity refused.'):
        if child.index(guard) >= child.index('[Reflection.Assembly]::Load'):
            raise AssertionError('Child loads code before authorization')
    needs(child, "[ValidateSet('apply','recover')]", '[ValidateRange(1,11)]',
          "'TryAcquireOperationLock' @('setup')", "'ApplyFilesCore' @($plan,$WorkDirectory,$callback)",
          "'RecoverInterruptedFileTransaction'", '$plan.Count -ne 11',
          '[Reflection.Assembly]::Load($candidateBytes)', '$hasher.ComputeHash($candidateBytes)',
          'OpenExisting', '$owner.Id -eq $PID', '$owner.MainModule.FileName -ine $hostPath',
          '$owner.StartTime.ToUniversalTime().Ticks -ne [int64]$env:TQR_CRASH_OWNER_STARTED',
          '$WorkDirectory -cne $env:TQR_CRASH_WORK', '$proceed.WaitOne(60000)',
          '[Environment]::Exit(91)', '$step -eq $Checkpoint')
    for source in (driver, child):
        for forbidden in ('Remove-Item', 'Copy-Item', 'WriteAllText', 'WriteAllBytes',
                          'File.Delete', 'Directory.Delete', 'Stop-Process -Name',
                          'Restart-Service', 'Restart-NetAdapter', 'netsh '):
            if forbidden in source:
                raise AssertionError('Test gained manual recovery or broad mutation')
    counter = driver.index('$points++')
    for term in ('Assert-Files $oldPlan', 'settings after recovery', 'own cleanup'):
        if driver.rindex(term) >= counter:
            raise AssertionError('Success counter precedes recovery evidence')
    report = main.rsplit('[pscustomobject]@{', 1)[1]
    needs(report, 'processFileRecoveryTested=$processFileRecoveryTested',
          'processRecoveryPoints=$processRecoveryPoints', 'interruptedUpgradeTested=$false',
          'desktopElevationTested=$false', 'publicFeedVerified=$false')
    for forbidden in ('$identity.User', '$record', '$configHash', '$env:TQR_CRASH_', '.Message'):
        if forbidden in report:
            raise AssertionError('Raw identity entered report')
    return True


class ProcessRecoveryContracts(unittest.TestCase):
    def setUp(self):
        self.sources = [(ROOT / name).read_text('utf-8-sig') for name in
                        ('test-clean-version-upgrade.ps1', 'test-process-file-recovery.ps1',
                         'test-setup-transaction-child.ps1')]

    def test_complete_contract(self):
        self.assertTrue(validate(*self.sources))

    def test_weakened_variants_are_rejected(self):
        variants = (
            (0, '-not $processFileRecoveryTested -or $processRecoveryPoints -ne 11'),
            (1, 'for($point=1;$point -le 11;$point++)'),
            (1, '$apply.StartTime.ToUniversalTime().Ticks -eq $applyStarted'),
            (1, '$apply.MainModule.FileName -ieq $hostPath'),
            (1, '$apply.Kill()'),
            (1, '$apply.WaitForExit(5000)'),
            (1, '(Digest $journal) -ceq $journalHash'),
            (1, '$restore.ExitCode -eq 0'),
            (2, 'GITHUB_REPOSITORY_ID'),
            (2, 'prepare-clean-upgrade.py'),
            (2, '$owner.StartTime.ToUniversalTime().Ticks -ne [int64]$env:TQR_CRASH_OWNER_STARTED'),
            (2, "'TryAcquireOperationLock' @('setup')"),
            (2, '$step -eq $Checkpoint'),
            (2, "'RecoverInterruptedFileTransaction'"),
            (0, 'interruptedUpgradeTested=$false'),
        )
        for index, term in variants:
            with self.subTest(index=index, term=term):
                changed = self.sources.copy()
                self.assertIn(term, changed[index])
                changed[index] = changed[index].replace(term, 'REMOVED')
                with self.assertRaises((AssertionError, ValueError)):
                    validate(*changed)

    def test_manual_cleanup_is_rejected(self):
        for index in (1, 2):
            for term in ('Remove-Item', 'Copy-Item', 'Stop-Process -Name'):
                with self.subTest(index=index, term=term):
                    changed = self.sources.copy()
                    changed[index] += '\n' + term
                    with self.assertRaises(AssertionError):
                        validate(*changed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
