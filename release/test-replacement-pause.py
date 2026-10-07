#!/usr/bin/env python3
"""Offline contracts for a synthetic native file-pause prerequisite."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent


def validate(helper, probe, caller):
    def require(source, *terms):
        if any(term not in source for term in terms):
            raise AssertionError('File-pause boundary missing')

    library, native_probe = helper.split('public static class ReplacementPauseProbe', 1)
    require(library, 'RequestOplock = 0x00090240', 'ReadHandleLevel = 3', 'AckRequired = 1',
            'IoPending = 997', '0x80000000, 1, IntPtr.Zero, 3, 0x40200000',
            'immediate || error != IoPending', 'milliseconds < 1 || milliseconds > 5000',
            'GetOverlappedResult(file, overlapped, out transferred, false)',
            'Marshal.ReadInt16(output, 2) != 24',
            'Marshal.ReadInt32(output, 12) & AckRequired) == 0',
            'FileAttributes.ReparsePoint', 'CancelIoEx(file, overlapped)',
            'signal.WaitOne(5000)', 'file.Dispose()', 'Undrained.Add(this)',
            'Marshal.FreeHGlobal(value)')
    for token in ('File.Write', 'File.Copy', 'File.Move', 'File.Replace', 'File.Delete',
                  'Directory.Delete', 'Process.Start', 'Process.Kill', 'WriteProcessMemory'):
        if token in library:
            raise AssertionError('Read-only hold gained a mutation')
    if library.index('Undrained.Add(this)') > library.index('Marshal.FreeHGlobal(value)'):
        raise AssertionError('Undrained native storage would be released')
    require(native_probe, 'Directory.GetFileSystemEntries(full).Length == 0',
            'File.Copy(target, backup)', '!pause.WaitForRequiredBreak(25)',
            'File.Replace(next, target, null)', 'pause.WaitForRequiredBreak(5000)',
            '!worker.Join(250)', 'worker.Join(5000) && workerFailure == null',
            'pause.Dispose(); pause.Dispose()', 'worker.IsBackground = true', 'reader.Join(5000) && readerFailure == null',
            'Require(stopped && readStopped)')
    if native_probe.count('checks++') != 10:
        raise AssertionError('Incomplete native assertion sequence')
    blocked = native_probe.index('Require(!worker.Join(250))')
    release = native_probe.index('pause.Dispose(); pause = null;', blocked)
    if 'File.Read' in native_probe[blocked:release]:
        raise AssertionError('Fresh read could deadlock behind the break')
    for token in ('github-hosted', 'GITHUB_REPOSITORY_ID', '1398720044', 'TQR_NATIVE_LAB_RUN',
                  'PSEdition', 'check-repository.py', 'test-replacement-pause.py'):
        if probe.index(token) >= probe.index('Add-Type -Path'):
            raise AssertionError('Native probe precedes source/runner guard')
    require(probe, '$null=& python', "if($LASTEXITCODE -ne 0)", 'Require-ProbePath $temporary',
            "'TqrReplacementProbe-'", 'if(Test-Path -LiteralPath $probeRoot)',
            '$checks -isnot [int] -or $checks -ne 10', 'if($probePassed)',
            '$items.Count -ne 2', '$item.Name -cnotin $expected',
            '[IO.Directory]::Delete($probeRoot,$true)',
            'Standalone termination remains separate.')
    for token in ('Start-Process', 'Process.Start', 'Launch-Installer', 'Restart-Service',
                  'GetFolderPath', 'TailscaleQuickRepair.SetupRecovery', 'Stop-Process'):
        if token in probe or token in helper:
            raise AssertionError('Synthetic probe gained product/process access')
    call = "    & (Join-Path $PSScriptRoot 'test-replacement-pause.ps1')"
    require(caller, call)
    if caller.count(call) != 1 or not (
            caller.index('Standalone recovery inputs failed verification.') < caller.index(call)
            < caller.index('Assert-Files $oldPlan') < caller.index('[Diagnostics.Process]::Start')):
        raise AssertionError('Native prerequisite was moved past installed mutation')
    return True


class FilePauseContracts(unittest.TestCase):
    def setUp(self):
        self.sources = [(ROOT / name).read_text('utf-8-sig') for name in
                        ('ReplacementPause.cs', 'test-replacement-pause.ps1',
                         'test-pending-standalone-recovery.ps1')]

    def test_complete_contract(self):
        self.assertTrue(validate(*self.sources))

    def test_ioctl_and_storage_layout(self):
        self.assertEqual((9 << 16) | (144 << 2), 0x00090240)
        self.assertEqual(2 + 2 + 4 + 4, 12)
        self.assertEqual(8 + 8 + 4 + 4 + 8, 32)
        self.assertIn('Allocate(12); output = Allocate(24)', self.sources[0])

    def test_weakened_variants_are_refused(self):
        variants = ((0, 'immediate || error != IoPending'),
                    (0, 'Marshal.ReadInt32(output, 12) & AckRequired) == 0'),
                    (0, 'CancelIoEx(file, overlapped)'), (0, 'Undrained.Add(this)'),
                    (0, '!worker.Join(250)'), (0, 'FileAttributes.ReparsePoint'),
                    (0, 'worker.Join(5000) && workerFailure == null'),
                    (1, 'github-hosted'), (1, 'GITHUB_REPOSITORY_ID'),
                    (1, 'TQR_NATIVE_LAB_RUN'), (1, 'check-repository.py'),
                    (1, '$checks -isnot [int] -or $checks -ne 10'),
                    (1, 'if($probePassed)'), (1, '$item.Name -cnotin $expected'),
                    (2, "    & (Join-Path $PSScriptRoot 'test-replacement-pause.ps1')"))
        for index, term in variants:
            with self.subTest(index=index, term=term):
                changed = self.sources.copy(); self.assertIn(term, changed[index])
                changed[index] = changed[index].replace(term, 'REMOVED')
                with self.assertRaises((AssertionError, ValueError)):
                    validate(*changed)

    def test_product_or_process_access_is_refused(self):
        for index in (0, 1):
            for token in ('Process.Start', 'Launch-Installer', 'Restart-Service'):
                with self.subTest(index=index, token=token):
                    changed = self.sources.copy(); changed[index] += '\n' + token
                    with self.assertRaises(AssertionError): validate(*changed)

    def test_read_during_acknowledgement_is_refused(self):
        changed = self.sources.copy()
        changed[0] = changed[0].replace('pause.Dispose(); pause = null;',
                                      'File.ReadAllText(target); pause.Dispose(); pause = null;', 1)
        with self.assertRaises(AssertionError): validate(*changed)

    def test_native_assertions_are_not_optional(self):
        changed = self.sources.copy(); changed[0] = changed[0].replace('checks++;', '', 1)
        with self.assertRaises(AssertionError): validate(*changed)

    def test_late_prerequisite_is_refused(self):
        changed = self.sources.copy()
        call = "    & (Join-Path $PSScriptRoot 'test-replacement-pause.ps1')"
        changed[2] = changed[2].replace(call, '') + '\n' + call
        with self.assertRaises(AssertionError): validate(*changed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
