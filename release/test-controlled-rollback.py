#!/usr/bin/env python3
"""Offline wiring contracts; native fault and recovery execution is separate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


class ControlledRollbackWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / 'test-clean-version-upgrade.ps1').read_text('utf-8-sig')
        self.block = self.source.split("    $stage='controlled_file_rollback'\n", 1)[1].split(
            "    $stage='process_file_recovery'\n", 1)[0]

    def test_existing_guard_and_input_verification_precede_native_work(self):
        for guard in ('github-hosted', 'GITHUB_REPOSITORY_ID', 'TQR_NATIVE_LAB_RUN',
                      'PSEdition', 'prepare-clean-upgrade.py', 'Require-EmptyProductState'):
            self.assertLess(self.source.index(guard), self.source.index('Add-Type -Path'))
        self.assertIn('test-controlled-rollback.py', self.source)
        self.assertIn("if($LASTEXITCODE -ne 0){throw 'Controlled rollback wiring checks failed.'}", self.source)

    def test_faults_follow_seed_and_precede_actual_process_upgrade(self):
        stages = [self.source.index("$stage='" + name + "'") for name in
                  ('seed_predecessor', 'controlled_file_rollback', 'held_operation_refusal',
                   'actual_version_upgrade')]
        self.assertEqual(stages, sorted(stages))
        self.assertEqual(self.source.count("$stage='controlled_file_rollback'"), 1)

    def test_fault_loop_covers_every_fixed_file(self):
        self.assertIn('for($checkpoint=1;$checkpoint -le $newPlan.Count;$checkpoint++)', self.block)
        self.assertIn('$oldPlan.Count -eq 11 -and $newPlan.Count -eq 11', self.source)
        self.assertIn('$rollbackPointsPassed -eq 11 -and $rollbackPointsPassed -eq $newPlan.Count', self.block)
        self.assertEqual(self.block.count('$rollbackPointsPassed++'), 1)

    def test_unchanged_native_transaction_and_callback_are_required(self):
        self.assertIn("Native $newType 'TryAcquireOperationLock' @('setup')", self.block)
        self.assertIn("Native $newType 'ApplyFilesCore' @($newPlan,$work,$fault)", self.block)
        self.assertIn('$fault=[Action[int]]', self.block)
        self.assertIn('$step -eq $script:rollbackCheckpoint', self.block)
        self.assertIn("throw [InvalidOperationException]::new('Synthetic replacement fault.')", self.block)
        self.assertIn("Native $newType 'ReleaseOperationLock'", self.block)

    def test_mutation_and_prepared_journal_must_be_observed(self):
        self.assertIn('$differentFiles.Count -gt 0', self.block)
        self.assertIn('((Digest $current.Target) -ceq $current.Sha256)', self.block)
        self.assertIn("$record.state -ceq 'prepared'", self.block)
        self.assertIn('@($record.entries).Count -eq $newPlan.Count', self.block)
        for flag in ('rollbackFaultReached', 'rollbackCandidateObserved', 'rollbackPreparedObserved'):
            self.assertIn('$script:' + flag + '=$false', self.block)
        self.assertIn('$failed -and $script:rollbackFaultReached -and $script:rollbackCandidateObserved -and', self.block)
        self.assertIn('$script:rollbackPreparedObserved)', self.block)

    def test_restoration_is_verified_without_manual_repair(self):
        self.assertIn('Assert-Files $oldPlan', self.block)
        self.assertIn('(Digest $config) -ceq $configHash', self.block)
        self.assertIn("@('.setup.new','.setup.recover')", self.block)
        self.assertIn('$temporaryAbsent -and -not (Test-Path -LiteralPath $recovery)', self.block)
        for forbidden in ('Remove-Item', 'Copy-Item', 'WriteAllText', 'WriteAllBytes',
                          "Native $oldType 'ApplyFiles'", 'File.Delete', 'Directory.Delete',
                          'RecoverInterruptedFileTransaction'):
            self.assertNotIn(forbidden, self.block)

    def test_recovery_assertions_precede_success_counter(self):
        counter = self.block.index('$rollbackPointsPassed++')
        for required in ('injects only after a verified', 'restores every exact',
                         'preserves all configuration', 'without manual cleanup'):
            self.assertLess(self.block.index(required), counter)
        self.assertGreater(self.block.index('$controlledRollbackTested=$true'), counter)

    def test_report_is_typed_and_does_not_overclaim(self):
        report = self.source.rsplit('[pscustomobject]@{', 1)[1]
        self.assertIn('controlledFileRollbackTested=$controlledRollbackTested', report)
        self.assertIn('controlledRollbackPoints=$rollbackPointsPassed', report)
        for field in ('interruptedUpgradeTested=$false', 'desktopElevationTested=$false',
                      'publicFeedVerified=$false'):
            self.assertIn(field, report)
        for value in ('$configHash', '$identity.User', '$record', '.Message', '$env:USERNAME'):
            self.assertNotIn(value, report)
        self.assertIn('Later integration-stage termination, power loss, secure-desktop consent and public delivery are not tested.', report)

    def test_no_new_network_or_process_kill_in_fault_loop(self):
        for token in ('Start-Service', 'Restart-Service', 'Restart-NetAdapter', 'netsh ',
                      'Set-DnsClientServerAddress', 'Start-Process', 'Process.Start', '.Kill(',
                      'Set-Content', 'CompleteInstalledIntegration'):
            self.assertNotIn(token, self.block)

    def test_final_exit_gate_requires_all_points(self):
        self.assertIn('$controlledRollbackTested=$false;$rollbackPointsPassed=0', self.source)
        self.assertIn('if(-not $passed -or -not $controlledRollbackTested -or $rollbackPointsPassed -ne 11 -or', self.source)
        self.assertIn('if($passed -and $owned)', self.source)
        self.assertIn('Existing evidence must not be overwritten.', self.source)

    def test_original_real_upgrade_and_downgrade_remain(self):
        real = self.source.split("$stage='actual_version_upgrade'", 1)[1].split(
            "$stage='installed_candidate_activation'", 1)[0]
        self.assertIn('$setup=Launch-Installer $newExe $newHash', real)
        self.assertNotIn("Native $newType 'ApplyFiles'", real)
        self.assertIn('$older=Launch-Installer $oldExe $oldHash', self.source)
        self.assertIn("'Only one upgraded resident instance remains'", self.source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
