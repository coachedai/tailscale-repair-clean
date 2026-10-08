#!/usr/bin/env python3
"""Synthetic negative regressions for complete native evidence acceptance."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('upgrade_evidence', ROOT / 'verify-upgrade-evidence.py')
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)
SOURCE = 'c' * 40


def pin(version, code, source, digest):
    return {'repository': v.REPOSITORY, 'repositoryId': int(v.REPOSITORY_ID),
            'source': source * 40, 'version': version, 'versionCode': code,
            'files': {prefix + version + suffix: {'sha256': digest * 64}
                      for prefix, suffix in (('TailscaleQuickRepair-Standalone-', '.exe'),
                                             ('TailscaleQuickRepair-SetupPackage-', '.zip'))}}


def fixture():
    old = pin('3.0.0-rc.12', 30001012, 'a', 'd')
    new = pin('3.0.0-rc.13', 30001013, 'b', 'e')
    report = dict(v.identities(old, new, SOURCE), schema=3, standaloneRecoveryCheckpoint=6, failureType='', failureReason='',
                  stage='downgrade_refusal', scope=v.SCOPE,
                  cases=[{'name': name, 'passed': True} for name in v.expected_cases()])
    report.update({name: True for name in v.TRUE_FIELDS})
    report.update({name: False for name in v.FALSE_FIELDS})
    report.update({name: 11 for name in v.COUNT_FIELDS})
    return report, old, new


class NativeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.report, self.old, self.new = fixture()

    def accepted(self, report=None):
        return v.validate(self.report if report is None else report, self.old, self.new, SOURCE)

    def test_complete_synthetic_report(self):
        self.assertEqual(self.accepted(), 266)
        names = v.expected_cases()
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(sum(name.startswith('Rollback point ') for name in names), 66)
        self.assertEqual(sum(name.startswith('Process point ') for name in names), 143)

    def test_no_input_mutation(self):
        before = copy.deepcopy((self.report, self.old, self.new))
        self.accepted()
        self.assertEqual((self.report, self.old, self.new), before)

    def test_every_required_field_is_mandatory(self):
        for key in self.report:
            with self.subTest(key=key):
                changed = copy.deepcopy(self.report); del changed[key]
                with self.assertRaises(v.Refused): self.accepted(changed)

    def test_unexpected_fields_are_refused(self):
        changed = copy.deepcopy(self.report); changed['rawFixture'] = 'synthetic-private-value'
        with self.assertRaises(v.Refused) as result: self.accepted(changed)
        self.assertNotIn('synthetic-private-value', str(result.exception))

    def test_success_flags_require_actual_true(self):
        for key in v.TRUE_FIELDS:
            for value in (False, None, 1, 0, 'true', 'false', [], {}):
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(self.report); changed[key] = value
                    with self.assertRaises(v.Refused): self.accepted(changed)

    def test_untested_flags_must_remain_actual_false(self):
        for key in v.FALSE_FIELDS:
            for value in (True, None, 0, 1, 'false', [], {}):
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(self.report); changed[key] = value
                    with self.assertRaises(v.Refused): self.accepted(changed)

    def test_scalar_point_counts(self):
        for key in v.COUNT_FIELDS:
            for value in (0, 10, 12, 11.0, '11', True, False, None, [11], ['synthetic status', 11]):
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(self.report); changed[key] = value
                    with self.assertRaises(v.Refused): self.accepted(changed)

    def test_every_assertion_must_succeed(self):
        for index in range(266):
            with self.subTest(index=index):
                changed = copy.deepcopy(self.report); changed['cases'][index]['passed'] = False
                with self.assertRaises(v.Refused): self.accepted(changed)

    def test_each_missing_assertion_is_refused(self):
        for index in range(266):
            with self.subTest(index=index):
                changed = copy.deepcopy(self.report); del changed['cases'][index]
                with self.assertRaises(v.Refused): self.accepted(changed)

    def test_fake_complete_count_does_not_replace_evidence(self):
        for length in (0, 1, 107, 223, 252, 263, 265):
            with self.subTest(length=length):
                changed = copy.deepcopy(self.report); changed['cases'] = changed['cases'][:length]
                with self.assertRaises(v.Refused): self.accepted(changed)
        changed = copy.deepcopy(self.report)
        changed['cases'] = [copy.deepcopy(changed['cases'][0]) for _ in range(266)]
        with self.assertRaises(v.Refused): self.accepted(changed)

    def test_case_order_and_duplicate_name(self):
        for indices in ((0, 1), (10, 12), (80, 223), (250, 251)):
            changed = copy.deepcopy(self.report); left, right = indices
            changed['cases'][left], changed['cases'][right] = changed['cases'][right], changed['cases'][left]
            with self.assertRaises(v.Refused): self.accepted(changed)
        changed = copy.deepcopy(self.report)
        changed['cases'][1]['name'] = changed['cases'][0]['name']
        with self.assertRaises(v.Refused): self.accepted(changed)

    def test_case_shape_and_unsafe_values(self):
        for value in (None, True, {}, {'name': 'synthetic', 'passed': True},
                      {'name': v.expected_cases()[0], 'passed': 'true'},
                      {'name': v.expected_cases()[0], 'passed': 1},
                      {'name': v.expected_cases()[0], 'passed': True, 'raw': 'synthetic'}):
            changed = copy.deepcopy(self.report); changed['cases'][0] = value
            with self.assertRaises(v.Refused): self.accepted(changed)
        for value in (None, {}, True, 'synthetic', tuple(self.report['cases'])):
            changed = copy.deepcopy(self.report); changed['cases'] = value
            with self.assertRaises(v.Refused): self.accepted(changed)

    def test_exact_source_versions_and_package_hashes(self):
        for key in v.IDENTITY_FIELDS:
            for value in ('f' * 64, '', None, self.report[key] + ' '):
                with self.subTest(key=key):
                    changed = copy.deepcopy(self.report); changed[key] = value
                    with self.assertRaises(v.Refused): self.accepted(changed)

    def test_terminal_state_failure_fields_and_scope(self):
        for key, values in (('schema', (True, '3', 1, 2, 3.0)),
                            ('stage', ('process_file_recovery', 'actual_version_upgrade', '')),
                            ('failureType', ('SyntheticException', None)),
                            ('failureReason', ('synthetic_failure', False)),
                            ('scope', ('Everything is tested.', v.SCOPE + ' extra', None))):
            for value in values:
                changed = copy.deepcopy(self.report); changed[key] = value
                with self.assertRaises(v.Refused): self.accepted(changed)

    def test_pin_source_repository_and_version_boundaries(self):
        for target in (self.old, self.new):
            for key, value in (('repository', 'fixture/other'), ('repositoryId', True),
                               ('source', 'invalid'), ('versionCode', False), ('version', 'other')):
                saved = target[key]; target[key] = value
                try:
                    with self.assertRaises(v.Refused): self.accepted()
                finally: target[key] = saved
        self.new['source'] = self.old['source']
        with self.assertRaises(v.Refused): self.accepted()

    def test_invalid_expected_test_source(self):
        for value in (None, 'bad', SOURCE.upper(), '', 'a' * 41):
            with self.assertRaises(v.Refused): v.validate(self.report, self.old, self.new, value)

    def test_decoder_rejects_duplicate_and_nonfinite_json(self):
        for raw in (b'{"passed":true,"passed":false}', b'{"x":NaN}', b'{"x":Infinity}',
                    b'\xff', b'', b'bad', b'[] trailing'):
            with self.assertRaises(v.Refused): v.decode(raw)
        raw = json.dumps(self.report).encode('utf-8')
        self.assertEqual(self.accepted(v.decode(raw)), 266)
        self.assertEqual(self.accepted(v.decode(b'\xef\xbb\xbf' + raw)), 266)

    def test_decoder_is_bounded(self):
        for raw in (b'x' * (v.MAX_REPORT + 1), b'[' * 2000 + b']' * 2000):
            with self.assertRaises(v.Refused): v.decode(raw)

    def test_file_read_is_read_only_bounded_and_link_safe(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'fixture.json'
            raw = json.dumps(self.report).encode('utf-8'); path.write_bytes(raw)
            self.assertEqual(v.read_json(path), self.report)
            self.assertEqual(path.read_bytes(), raw)
            linked = Path(root) / 'linked.json'
            try: linked.symlink_to(path)
            except (OSError, NotImplementedError): self.skipTest('Symbolic links unavailable.')
            with self.assertRaises(v.Refused): v.read_json(linked)
            path.write_bytes(b'x' * (v.MAX_REPORT + 1))
            with self.assertRaises(v.Refused): v.read_json(path)

    def test_nesting_bound_ignores_escaped_string_contents(self):
        value = {'label': '{' * 50 + '\\' + '"' + ']' * 50}
        self.assertEqual(v.decode(json.dumps(value).encode()), value)
        self.assertEqual(v.decode(b'[' * 12 + b'0' + b']' * 12)[0][0][0][0][0][0][0][0][0][0][0][0], 0)
        with self.assertRaises(v.Refused): v.decode(b'[' * 13 + b'0' + b']' * 13)

    def test_special_files_and_linked_parent_are_refused(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / 'folder'; directory.mkdir()
            with self.assertRaises(v.Refused): v.read_json(directory)
            if hasattr(os, 'mkfifo'):
                fifo = directory / 'pipe'; os.mkfifo(fifo)
                with self.assertRaises(v.Refused): v.read_json(fifo)
            path = directory / 'fixture.json'; path.write_bytes(b'{}')
            link = Path(root) / 'redirect'
            try: link.symlink_to(directory, target_is_directory=True)
            except (OSError, NotImplementedError): self.skipTest('Symbolic links unavailable.')
            with self.assertRaises(v.Refused): v.read_json(link / 'fixture.json')

    def test_malformed_pin_records_are_refused(self):
        for value in (None, [], True, {}, {'TailscaleQuickRepair-Standalone-3.0.0-rc.13.exe': []}):
            changed = copy.deepcopy(self.new); changed['files'] = value
            with self.assertRaises(v.Refused): v.validate(self.report, self.old, changed, SOURCE)

    def test_workflow_enforces_gate_after_native_execution(self):
        import yaml
        workflow = yaml.safe_load((ROOT.parent / '.github/workflows/preflight.yml').read_text('utf-8-sig'))
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        preflight = workflow['jobs']['preflight']['steps']
        self.assertEqual(sum(s.get('run') == 'python3 -B release/test-upgrade-evidence.py' for s in preflight), 1)
        job = workflow['jobs']['clean-version-upgrade']
        self.assertEqual(job['permissions'], {'contents': 'read', 'actions': 'read'})
        self.assertEqual(job['needs'], ['preflight', 'clean-upgrade-inputs', 'clean-setup-entry'])
        self.assertEqual(job['defaults']['run']['shell'], 'powershell')
        names = [s.get('name') for s in job['steps']]
        execute = names.index('Exercise actual version transition and downgrade refusal')
        index = names.index('Require genuine scoped version-transition evidence')
        self.assertGreater(index, execute)
        step = job['steps'][index]
        self.assertNotIn('if', step)
        self.assertNotIn('continue-on-error', step)
        command = step['run']
        self.assertIn('python -B release/verify-upgrade-evidence.py', command)
        self.assertIn("if($LASTEXITCODE -ne 0){throw 'Complete native evidence gate refused.'}", command)
        self.assertIn('release/check-repository.py --ci', command)
        self.assertIn('git diff --exit-code', command)
        uploader = job['steps'][names.index('Preserve typed version-transition evidence only')]
        self.assertEqual(uploader['if'], 'always()')
        self.assertEqual(len(uploader['with']['path'].splitlines()), 2)
        self.assertNotIn('*', uploader['with']['path'])

    def test_cli_refuses_outside_ci_without_echoing_arguments(self):
        args = [sys.executable, '-B', str(ROOT / 'verify-upgrade-evidence.py'), 'synthetic-private-value']
        env = {k: val for k, val in os.environ.items() if not k.startswith(('GITHUB_', 'RUNNER_'))}
        result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr.strip(), 'Native evidence refused; values withheld.')
        self.assertNotIn('synthetic-private-value', result.stderr)

def pending_contract(main, driver):
    def needs(source, *terms):
        for term in terms:
            if term not in source:
                raise AssertionError('Required pending-entry contract absent')
    stages = [main.index("$stage='" + x + "'") for x in
              ('process_file_recovery', 'held_operation_refusal', 'pending_standalone_recovery',
               'actual_version_upgrade', 'installed_candidate_activation')]
    if stages != sorted(stages):
        raise AssertionError('Pending entry stage order changed')
    needs(main, 'test-pending-standalone-recovery.ps1',
          '$standaloneRecoveryCheckpoint=New-PinnedPendingStandaloneJournal',
          '$standaloneJournalRecoveryTested=$false;$standaloneRecoveryCheckpoint=0',
          '$standaloneProcessTerminationTested=$false',
          '$standaloneRecoveryCheckpoint -is [int] -and $standaloneRecoveryCheckpoint -eq 6',
          '-not $standaloneProcessTerminationTested -or',
          '-not $standaloneJournalRecoveryTested -or $standaloneRecoveryCheckpoint -ne 6',
          'standaloneJournalRecoveryTested=$standaloneJournalRecoveryTested',
          'standaloneRecoveryCheckpoint=$standaloneRecoveryCheckpoint',
          'standaloneProcessTerminationTested=$standaloneProcessTerminationTested')
    needs(driver, '-not $owned', '-not $controlledRollbackTested', '$rollbackPointsPassed -ne 11',
          '-not $processFileRecoveryTested', '$processRecoveryPoints -ne 11', '-not $leaseRefused',
          'github-hosted', 'GITHUB_REPOSITORY_ID', 'TQR_NATIVE_LAB_RUN', 'PSEdition',
          '$null=& python', 'prepare-clean-upgrade.py', 'if($LASTEXITCODE -ne 0)',
          'test-replacement-pause.ps1', '$point=6', 'return [int]$point',
          '$target=[string]$newPlan[$point].Target', 'Require-UnlinkedPath $target',
          "$target -ceq (Join-Path $app 'Tailscale-Repair-UI.ps1')",
          '$pause=[Tqr.Acceptance.ReplacementPause]::new($target)',
          '$interrupted=Launch-Installer $newExe $newHash',
          '$pause.WaitForRequiredBreak(5000)', '$interrupted.Kill()', '$interrupted.WaitForExit(5000)',
          '$interrupted.StartTime.ToUniversalTime().Ticks -eq $started',
          '$interrupted.MainModule.FileName -ieq $newExe', '$interrupted.Id -ne $PID',
          '(Digest $newExe) -ceq $newHash',
          '$prefixMatches -and $changedPrefix -and $unchangedSuffix',
          '$mixedPlan -and $changedPrefix -and $unchangedSuffix',
          "@($record.entries).Count -eq 11", "$record.state -ceq 'prepared'",
          '(Digest $journal) -ceq $journalHash', '(Digest $config) -ceq $configHash',
          '(Digest $next) -ceq $newPlan[$point].Sha256',
          '$installed.versionCode -eq $oldCode')
    for term in ('GITHUB_REPOSITORY_ID', 'prepare-clean-upgrade.py', 'Require-UnlinkedPath $target',
                 'test-replacement-pause.ps1', 'Assert-Files $oldPlan'):
        if driver.index(term) >= driver.index('$interrupted=Launch-Installer'):
            raise AssertionError('Installer launch precedes required gate')
    order = [driver.index(term) for term in
             ('$pause=[Tqr.Acceptance.ReplacementPause]::new($target)',
              '$interrupted=Launch-Installer', '$pause.WaitForRequiredBreak(5000)',
              '$prefixMatches -and', "$record.state -ceq 'prepared'",
              '$interrupted.MainModule.FileName -ieq $newExe -and $interrupted.Id -ne $PID',
              '$interrupted.Kill()', '$interrupted.WaitForExit(5000)', '$pause.Dispose();$pause=$null',
              '$mixedPlan=$true', '(Digest $journal) -ceq $journalHash', 'return [int]$point')]
    if order != sorted(order):
        raise AssertionError('Required interruption or recovery ordering changed')
    paused = driver.split('$pause.WaitForRequiredBreak(5000)', 1)[1].split('$pause.Dispose();$pause=$null', 1)[0]
    needs(paused, 'if($i -eq $point){continue}')
    if 'Digest $target' in paused or 'Get-Content -LiteralPath $target' in paused:
        raise AssertionError('A held-target read could block the lab')
    cleanup = driver.split('    }finally{', 1)[1]
    needs(cleanup, '$interrupted.StartTime.ToUniversalTime().Ticks -ne $started',
          '$interrupted.MainModule.FileName -ine $newExe', '$interrupted.Id -eq $PID',
          '$interrupted.Kill()', 'finally{$pause.Dispose()}')
    pending = main.split("$stage='pending_standalone_recovery'", 1)[1].split("$stage='actual_version_upgrade'", 1)[0]
    if pending.index('$standaloneProcessTerminationTested=$true') <= pending.index("'Pending entry returns only the verified checkpoint number'"):
        raise AssertionError('Termination flag precedes checked native outcome')
    real = main.split("$stage='actual_version_upgrade'", 1)[1].split(
        "$stage='installed_candidate_activation'", 1)[0]
    needs(real, '$setup=Launch-Installer $newExe $newHash', 'Assert-Files $newPlan',
          '(Digest $config) -ceq $configHash', '$setup.ExitCode -eq 0',
          "$temporaryAbsent -and -not(Test-Path -LiteralPath $recovery)",
          '$standaloneJournalRecoveryTested=$true')
    if real.index('$standaloneJournalRecoveryTested=$true') <= real.index('$temporaryAbsent -and'):
        raise AssertionError('Recovery success precedes required evidence')
    for forbidden in ('Remove-Item', 'Copy-Item', 'WriteAllText', 'WriteAllBytes',
                      'File.Delete', 'Directory.Delete', 'RecoverInterruptedFileTransaction',
                      'Stop-Process -Name', 'Restart-Service', 'Restart-NetAdapter', 'netsh '):
        if forbidden in driver or forbidden in real:
            raise AssertionError('Manual recovery or broad mutation entered pending entry')
    for forbidden in ('[Diagnostics.Process]::Start', 'test-setup-transaction-child.ps1',
                      'Native ', 'WriteProcessMemory', 'CreateRemoteThread', 'Start-Sleep'):
        if forbidden in driver:
            raise AssertionError('Standalone test must use the unchanged pinned executable')
    report = main.rsplit('[pscustomobject]@{', 1)[1]
    needs(report, 'schema=3', 'desktopElevationTested=$false',
          'publicFeedVerified=$false', 'interruptedUpgradeTested=$false')
    for term in ('$record', '$identity.User', '$configHash', '$journalHash', '$nonce', '.Message'):
        if term in report:
            raise AssertionError('Local state entered published evidence')
    return True


class PendingStandaloneContracts(unittest.TestCase):
    def setUp(self):
        self.main = (ROOT / 'test-clean-version-upgrade.ps1').read_text('utf-8-sig')
        self.driver = (ROOT / 'test-pending-standalone-recovery.ps1').read_text('utf-8-sig')

    def test_scoped_pending_entry_contract(self):
        self.assertTrue(pending_contract(self.main, self.driver))

    def test_weakened_pending_entry_variants_are_refused(self):
        cases = (
            (0, '-not $standaloneJournalRecoveryTested -or $standaloneRecoveryCheckpoint -ne 6'),
            (0, '$standaloneRecoveryCheckpoint -is [int] -and $standaloneRecoveryCheckpoint -eq 6'),
            (0, 'interruptedUpgradeTested=$false'),
            (1, '-not $owned'), (1, '$processRecoveryPoints -ne 11'),
            (1, 'GITHUB_REPOSITORY_ID'), (1, '$null=& python'), (1, 'if($LASTEXITCODE -ne 0)'),
            (1, '$interrupted=Launch-Installer $newExe $newHash'), (1, '$interrupted.Kill()'),
            (1, '$interrupted.WaitForExit(5000)'), (1, '$interrupted.MainModule.FileName -ieq $newExe'),
            (1, '$interrupted.StartTime.ToUniversalTime().Ticks -eq $started'),
            (1, '$mixedPlan -and $changedPrefix -and $unchangedSuffix'),
            (1, '(Digest $journal) -ceq $journalHash'), (1, '(Digest $config) -ceq $configHash'),
            (0, '-not $standaloneProcessTerminationTested -or'),
            (1, '$pause.WaitForRequiredBreak(5000)'),
            (1, '(Digest $newExe) -ceq $newHash'),
            (1, '$prefixMatches -and $changedPrefix -and $unchangedSuffix'),
            (1, 'if($i -eq $point){continue}'),
            (1, '$pause.Dispose();$pause=$null'),
            (1, '$interrupted.MainModule.FileName -ine $newExe'),
            (1, '$interrupted.StartTime.ToUniversalTime().Ticks -ne $started'),

        )
        for index, term in cases:
            with self.subTest(index=index, term=term):
                sources = [self.main, self.driver]
                self.assertIn(term, sources[index])
                sources[index] = sources[index].replace(term, 'REMOVED')
                with self.assertRaises((AssertionError, ValueError)):
                    pending_contract(*sources)

    def test_manual_recovery_and_early_success_are_refused(self):
        for token in ('Remove-Item', 'Copy-Item', 'RecoverInterruptedFileTransaction'):
            with self.subTest(token=token):
                with self.assertRaises(AssertionError):
                    pending_contract(self.main, self.driver + '\n' + token)
        changed = self.main.replace('$standaloneJournalRecoveryTested=$true', '')
        changed = changed.replace("$stage='actual_version_upgrade'", """$stage='actual_version_upgrade'
    $standaloneJournalRecoveryTested=$true""")
        with self.assertRaises(AssertionError): pending_contract(changed, self.driver)

    def test_pending_checkpoint_is_exact_integer(self):
        report, old, new = fixture()
        for value in (None, True, False, 0, 5, 7, 11, '6', 6.0, [6]):
            with self.subTest(value=value):
                changed = copy.deepcopy(report); changed['standaloneRecoveryCheckpoint'] = value
                with self.assertRaises(v.Refused): v.validate(changed, old, new, SOURCE)

    def test_old_complete_evidence_cannot_claim_pending_entry(self):
        report, old, new = fixture()
        report['schema'] = 1
        del report['standaloneJournalRecoveryTested']
        del report['standaloneRecoveryCheckpoint']
        del report['standaloneProcessTerminationTested']
        report['cases'] = [case for case in report['cases'] if not case['name'].startswith(
            ('Pending entry ', 'Standalone entry completes pending'))]
        self.assertEqual(len(report['cases']), 252)
        with self.assertRaises(v.Refused): v.validate(report, old, new, SOURCE)

    def test_early_release_and_held_reads_are_refused(self):
        release = '$pause.Dispose();$pause=$null'
        changed = self.driver.replace(release, '', 1)
        changed = changed.replace('$interrupted.Kill()', release + '\n        $interrupted.Kill()', 1)
        with self.assertRaises((AssertionError, ValueError)):
            pending_contract(self.main, changed)
        changed = self.driver.replace('$prefixMatches=$true', 'Digest $target; $prefixMatches=$true', 1)
        with self.assertRaises(AssertionError): pending_contract(self.main, changed)

    def test_engine_host_cannot_substitute_for_standalone(self):
        for token in ('test-setup-transaction-child.ps1', 'Native ', 'CreateRemoteThread'):
            with self.subTest(token=token):
                with self.assertRaises(AssertionError):
                    pending_contract(self.main, self.driver + '\n' + token)

    def test_previous_journal_scope_is_not_standalone_death_evidence(self):
        report, old, new = fixture()
        report['schema'] = 2
        del report['standaloneProcessTerminationTested']
        with self.assertRaises(v.Refused): v.validate(report, old, new, SOURCE)
        report['schema'] = 3
        report['standaloneProcessTerminationTested'] = True
        report['cases'] = report['cases'][:263]
        with self.assertRaises(v.Refused): v.validate(report, old, new, SOURCE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
