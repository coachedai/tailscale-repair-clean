#!/usr/bin/env python3
"""Offline boundaries for the native Setup entry acceptance job."""
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'release/test-setup-entry.ps1').read_text()
PROBE = (ROOT / 'release/SetupEntryProbe.cs').read_text()
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/preflight.yml').read_text())


class EntryBoundaryTests(unittest.TestCase):
    def test_empty_hosted_environment_required(self):
        for required in ["RUNNER_ENVIRONMENT -cne 'github-hosted'", "GITHUB_REPOSITORY_ID -cne '1398720044'",
                         "GITHUB_REF_NAME -notin @('main','work/public')", 'TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID',
                         'Require-EmptyProductState', 'Require-UnlinkedPath', 'Checkout identity mismatch']:
            self.assertIn(required, SCRIPT)

    def test_exact_fixture_hashes_are_required_before_any_launch(self):
        self.assertIn('bdd905f8bd9dc771a3a8fd0ec5093157f30a7d0c2a8ac6d578b5ff6fd74626ce', SCRIPT)
        self.assertIn('ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17', SCRIPT)
        self.assertLess(SCRIPT.index('Exact original distribution bytes are required.'), SCRIPT.index('function Launch-Setup'))
        self.assertIn('receipt.testSource -cne $env:GITHUB_SHA', SCRIPT)
        self.assertIn('TailscaleQuickRepair-SetupPackage-3.0.0-rc.11.zip', SCRIPT)
        self.assertIn('TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe', SCRIPT)
        self.assertIn('receipt.predecessorArtifactId -ne 11103704932', SCRIPT)
        self.assertIn('receipt.candidateArtifactId -ne 11107315062', SCRIPT)

    def test_real_entry_is_not_replaced_with_installer_methods(self):
        for forbidden in ["Native $newType 'Install'", "Native $newType 'ApplyFiles'", "Native $newType 'CompleteInstalledIntegration'",
                          "'--verify-bundle'", "'--self-test-installer'", 'Invoke-WebRequest', 'Invoke-RestMethod']:
            self.assertNotIn(forbidden, SCRIPT)
        self.assertIn('$setup=Launch-Setup\n', SCRIPT)
        self.assertIn('$info.FileName=$candidate;$info.Arguments=$Arguments;', SCRIPT)

    def test_original_baseline_still_uses_original_installer(self):
        self.assertIn("Native $oldType 'ApplyFiles'", SCRIPT)
        self.assertIn("Assert-Files $oldFiles 'Original RC11 installer", SCRIPT)
        self.assertIn("Assert-Files $newFiles 'Normal Setup entry", SCRIPT)

    def test_consent_and_public_delivery_are_not_claimed(self):
        self.assertIn('desktopElevationTested=$false;publicFeedVerified=$false', SCRIPT)
        self.assertNotIn('EnableLUA', SCRIPT)
        self.assertNotIn('ConsentPromptBehavior', SCRIPT)
        self.assertNotIn('uiAccess', PROBE)

    def test_process_cleanup_uses_recorded_identity(self):
        self.assertIn('$p.StartTime.ToUniversalTime().Ticks -ne $entry.started', SCRIPT)
        self.assertIn('$p.MainModule.FileName -ine $entry.path', SCRIPT)
        self.assertNotRegex(SCRIPT, r'(?i)Stop-Process\s+-Name|taskkill')

    def test_process_identity_wait_is_bounded_and_precedes_window_access(self):
        start = SCRIPT.index('function Remember-Process')
        end = SCRIPT.index('function Launch-Setup', start)
        method = SCRIPT[start:end]
        self.assertIn('$watch.Elapsed.TotalSeconds -lt 10', method)
        self.assertIn("Entry-Failure 'process_exited_before_identity'", method)
        self.assertIn('$module.FileName -ieq $Path', method)
        self.assertIn("Entry-Failure 'process_identity_timeout'", method)
        self.assertIn('failureReason=$failureReason', SCRIPT)

    def test_installed_app_window_wait_is_bounded(self):
        self.assertIn("function Wait-Window($Process,[string]$Title,[string]$ClassPrefix='',[int]$TimeoutSeconds=30)", SCRIPT)
        self.assertIn("$TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60", SCRIPT)
        self.assertEqual(SCRIPT.count("Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper' 60"), 1)
        self.assertEqual(SCRIPT.count("Wait-Window $appProcess 'Tailscale Quick Repair' 'HwndWrapper'"), 2)
        self.assertNotIn("while($watch.Elapsed.TotalSeconds -lt 60)", SCRIPT)

    def test_window_reads_and_messages_are_process_scoped(self):
        self.assertIn('owner == (uint)process', PROBE)
        self.assertIn('if (!Owned(window, process)) return true;', PROBE)
        self.assertIn('if (!Owned(parent, process)) return false;', PROBE)
        self.assertIn('return Owned(window, process) && PostMessage', PROBE)
        self.assertIn('SendMessageTimeout', PROBE)

    def test_no_raw_window_or_machine_capture(self):
        for forbidden in ['GetWindowText', 'CopyFromScreen', 'PrintWindow', 'GetClipboardData', 'Console.Write', 'File.Write']:
            self.assertNotIn(forbidden, PROBE)
        self.assertNotIn('$_.Exception.Message', SCRIPT)
        self.assertIn('$failure=$e.GetType().FullName', SCRIPT)

    def test_entry_job_has_no_write_permissions_or_token(self):
        job = WORKFLOW['jobs']['setup-entry']
        self.assertEqual(job['permissions'], {'contents': 'read', 'actions': 'read'})
        self.assertEqual(job['needs'], ['preflight', 'migration-inputs'])
        self.assertEqual(job['runs-on'], 'windows-latest')
        self.assertEqual(job['timeout-minutes'], 5)
        for step in job['steps']:
            self.assertNotIn('GH_TOKEN', step.get('env', {}))
            if 'checkout@' in step.get('uses', ''):
                self.assertFalse(step['with']['persist-credentials'])

    def test_entry_results_are_separate_and_typed(self):
        job = WORKFLOW['jobs']['setup-entry']
        upload = [s for s in job['steps'] if 'upload-artifact@' in s.get('uses', '')]
        self.assertEqual(len(upload), 1)
        self.assertEqual(upload[0]['with']['name'], 'setup-entry-evidence')
        self.assertNotIn('*', upload[0]['with']['path'])
        self.assertIn('Existing entry-test evidence must not be overwritten.', SCRIPT)
        self.assertIn('setupEntryExecuted=$entryExecuted', SCRIPT)

    def test_original_gates_remain_present(self):
        for name in ['preflight', 'startup-windows', 'migration-inputs', 'released-migration']:
            self.assertIn(name, WORKFLOW['jobs'])
        native = WORKFLOW['jobs']['released-migration']
        self.assertTrue(any('test-released-setup-migration.ps1' in s.get('run', '') for s in native['steps']))

    def test_live_residency_and_restart_are_checked(self):
        for required in ['PendingRestartVersionCode', 'HwndWrapper', 'Responsive($appWindow',
                         'Closing the installed window keeps its process resident in the tray',
                         'Second launch signals the resident instance and exits normally']:
            self.assertIn(required, SCRIPT)


if __name__ == '__main__':
    unittest.main(verbosity=2)