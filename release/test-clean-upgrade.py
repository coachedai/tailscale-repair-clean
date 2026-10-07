#!/usr/bin/env python3
"""Synthetic two-version input regressions and native upgrade boundaries."""
import copy
import importlib.util
import io
import json
import re
from pathlib import Path
import tempfile
import unittest
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('upgrade', ROOT / 'release/prepare-clean-upgrade.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)


def encoded(value):
    return json.dumps(value, sort_keys=True).encode('utf-8')


def zipped(files):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items(): z.writestr(name, data)
    return out.getvalue()


def fixture(number, source, run):
    version = '3.0.0-rc.' + str(number)
    code = 30001000 + number
    identity = {'schema': 1, 'product': 'Tailscale Quick Repair', 'version': version, 'versionCode': code}
    payloads = []
    for setup in (False, True):
        files = {name: b'synthetic-content' for name in (
            'app/Advanced-Diagnostics.ps1', 'app/Tailscale-Repair-UI.ps1',
            'app/TailscaleQuickRepair.Operations.dll', 'app/TailscaleQuickRepairSetup.exe',
            'app/TailscaleQuickRepairUpdater.exe')}
        files['version.json'] = encoded(dict(identity, channel='preview'))
        if setup:
            for name in ('app/TailscaleQuickRepair.exe', 'program/Auto-Repair-Monitor.ps1',
                         'program/Repair-Backend.ps1', 'program/TailscaleQuickRepair.Operations.dll'):
                files[name] = b'synthetic-content'
        else:
            files['app/protected-update.json'] = b'synthetic-content'
        records = lambda items: [{'path': n, 'size': len(b), 'sha256': u.baseline.digest(b)} for n, b in items]
        records_app = records((n[4:], b) for n, b in files.items() if n.startswith('app/') and n != 'app/protected-update.json')
        files['app/integrity-manifest.json'] = encoded(dict(identity, algorithm='SHA256', profile='setup' if setup else 'update', files=records_app))
        files['package-manifest.json'] = encoded(dict(identity, files=records(files.items())))
        payloads.append(zipped(files))
    payloads.append(b'MZsynthetic-executable' + payloads[1])
    pin = {'schema': 1, 'repository': u.baseline.REPOSITORY, 'repositoryId': u.baseline.REPOSITORY_ID,
           'source': source * 40, 'tree': str(number - 10) * 40, 'runId': run,
           'version': version, 'versionCode': code,
           'artifacts': {'packages': {'id': run * 10, 'name': 'candidate-validation-packages', 'size': 10, 'sha256': 'a' * 64},
                         'evidence': {'id': run * 10 + 1, 'name': 'startup-tests', 'size': 10, 'sha256': 'b' * 64}}, 'files': {}}
    files = dict(zip(u.baseline.asset_names(pin), payloads))
    pin['files'] = {n: {'size': len(b), 'sha256': u.baseline.digest(b)} for n, b in files.items()}
    return pin, files


class PairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old, old_files = fixture(12, '1', 21)
        self.new, new_files = fixture(13, '2', 22)
        self.files = dict(old_files, **new_files)
        self.source = 'c' * 40
        self.counts = {role: {n: 1 for n in u.baseline.REPORTS} for role in ('predecessor', 'candidate')}
        self.directory = u.stage(self.root, self.old, self.new, self.files, self.counts, self.source)

    def verify(self):
        return u.verify(self.directory, self.old, self.new, self.source)

    def change_receipt(self, fn):
        path = self.directory / u.RECEIPT
        record = json.loads(path.read_text())
        fn(record)
        path.write_text(json.dumps(record))

    def test_valid_pair_roundtrip(self):
        result = self.verify()
        self.assertEqual(len(list(self.directory.iterdir())), 13)
        self.assertIs(result['upgradeExecuted'], False)
        self.assertGreater(result['candidate']['versionCode'], result['predecessor']['versionCode'])

    def test_no_overwrite_of_staged_evidence(self):
        with self.assertRaises(u.Refused):
            u.stage(self.root, self.old, self.new, self.files, self.counts, self.source)

    def test_equal_or_reversed_versions_are_rejected(self):
        for left, right in ((self.old, self.old), (self.new, self.old), (self.new, self.new)):
            with self.subTest(left=left['version'], right=right['version']):
                with self.assertRaises(u.Refused): u.validate_pair(left, right)

    def test_identical_source_tree_run_or_artifact_are_rejected(self):
        for key in ('source', 'tree', 'runId'):
            pin = copy.deepcopy(self.new);pin[key] = self.old[key]
            with self.assertRaises(u.Refused): u.validate_pair(self.old, pin)
        pin = copy.deepcopy(self.new);pin['artifacts']['packages']['id'] = self.old['artifacts']['packages']['id']
        with self.assertRaises(u.Refused): u.validate_pair(self.old, pin)

    def test_invalid_pin_types_and_repository(self):
        for key, value in (('schema', True), ('versionCode', True), ('versionCode', '30001013'),
                           ('repositoryId', 1), ('repository', 'example/fixture'),
                           ('source', 'invalid'), ('version', '../fixture')):
            with self.subTest(key=key):
                pin = copy.deepcopy(self.new);pin[key] = value
                with self.assertRaises(u.Refused): u.validate_pair(self.old, pin)

    def test_each_distribution_rejects_changed_bytes(self):
        for name in self.files:
            path = self.directory / name;original = path.read_bytes();path.write_bytes(original + b'changed')
            with self.subTest(name=name):
                with self.assertRaises(u.Refused): self.verify()
            path.write_bytes(original)

    def test_wrong_checksum(self):
        (self.directory / (next(iter(self.files)) + '.sha256')).write_text('0' * 64)
        with self.assertRaises(u.Refused): self.verify()

    def test_extra_file_or_directory(self):
        for name in ('unexpected.md', 'unexpected.txt'):
            path = self.directory / name;path.write_text('synthetic')
            with self.assertRaises(u.Refused): self.verify()
            path.unlink()
        (self.directory / 'unexpected').mkdir()
        with self.assertRaises(u.Refused): self.verify()

    def test_missing_distribution(self):
        (self.directory / next(iter(self.files))).unlink()
        with self.assertRaises(u.Refused): self.verify()

    def test_linked_input_is_rejected(self):
        names = list(self.files);path = self.directory / names[0];path.unlink()
        try: path.symlink_to(self.directory / names[1])
        except OSError: self.skipTest('Symbolic links unavailable')
        with self.assertRaises(u.inputs.Refused): self.verify()

    def test_linked_parent_and_traversal_are_rejected(self):
        alias = self.root / 'alias'
        try: alias.symlink_to(self.directory, target_is_directory=True)
        except OSError: self.skipTest('Symbolic links unavailable')
        with self.assertRaises(u.inputs.Refused): u.verify(alias, self.old, self.new, self.source)
        with self.assertRaises(u.inputs.Refused): u.inputs.no_links(self.directory / '..' / self.directory.name)

    def test_receipt_wrong_source_or_extra_field(self):
        self.change_receipt(lambda r: r.update(testSource='d' * 40))
        with self.assertRaises(u.Refused): self.verify()
        self.change_receipt(lambda r: r.update(testSource=self.source, extra=True))
        with self.assertRaises(u.Refused): self.verify()

    def test_receipt_cannot_claim_execution_or_publication(self):
        for key in ('installerExecuted', 'upgradeExecuted', 'desktopConsentTested', 'publicFeedVerified', 'publicationAllowed'):
            self.change_receipt(lambda r: r.update({key: True}))
            with self.subTest(key=key):
                with self.assertRaises(u.Refused): self.verify()
            self.change_receipt(lambda r: r.update({key: False}))

    def test_receipt_pin_changes_rejected(self):
        self.change_receipt(lambda r: r['candidate']['artifacts']['packages'].update(id=99))
        with self.assertRaises(u.Refused): self.verify()

    def test_receipt_boolean_not_integer_identity(self):
        self.change_receipt(lambda r: r.update(schema=True))
        with self.assertRaises(u.Refused): self.verify()

    def test_invalid_evidence_counts(self):
        name = u.baseline.REPORTS[0]
        for value in (True, 0, -1, '1', None, 10001):
            self.change_receipt(lambda r: r['assertionCounts']['candidate'].update({name: value}))
            with self.assertRaises(u.Refused): self.verify()

    def test_missing_evidence_role(self):
        self.change_receipt(lambda r: r['assertionCounts'].pop('candidate'))
        with self.assertRaises(u.Refused): self.verify()

    def test_invalid_or_oversized_receipt(self):
        path = self.directory / u.RECEIPT
        for raw in (b'{"schema":1,"schema":1}', b'{"x":NaN}', b' ' * 65537):
            path.write_bytes(raw)
            with self.assertRaises((u.Refused, u.inputs.Refused)): self.verify()

    def test_manifest_tampering_rejected_even_with_outer_hash_changed(self):
        name = u.baseline.asset_names(self.new)[1]
        inner = u.baseline.archive(self.files[name], windows=True)
        inner['app/Tailscale-Repair-UI.ps1'] = b'changed-synthetic-content'
        bad = zipped(inner)
        pin = copy.deepcopy(self.new);pin['files'][name] = {'size': len(bad), 'sha256': u.baseline.digest(bad)}
        files = dict(self.files);files[name] = bad
        with self.assertRaises(u.Refused): u.verify_files(files, self.old, pin)

    def test_embedded_payload_must_be_exact(self):
        name = u.baseline.asset_names(self.new)[2]
        bad = b'MZsynthetic-without-payload'
        pin = copy.deepcopy(self.new);pin['files'][name] = {'size': len(bad), 'sha256': u.baseline.digest(bad)}
        files = dict(self.files);files[name] = bad
        with self.assertRaises(u.Refused): u.verify_files(files, self.old, pin)

    def test_non_main_or_failed_run_not_accepted(self):
        run = {'repository': {'id': u.baseline.REPOSITORY_ID, 'full_name': u.baseline.REPOSITORY},
               'head_repository': {'id': u.baseline.REPOSITORY_ID, 'full_name': u.baseline.REPOSITORY},
               'id': self.new['runId'], 'head_sha': self.new['source'], 'head_branch': 'main',
               'event': 'push', 'path': '.github/workflows/preflight.yml', 'status': 'completed',
               'conclusion': 'success', 'run_attempt': 1, 'head_commit': {'tree_id': self.new['tree']}}
        u.baseline.verify_run(run, self.new)
        for key, value in (('head_branch', 'work/public'), ('conclusion', 'failure'), ('run_attempt', 2), ('status', 'in_progress')):
            altered = dict(run);altered[key] = value
            with self.assertRaises(u.Refused): u.baseline.verify_run(altered, self.new)

    def test_arbitrary_endpoint_rejected_before_request(self):
        with self.assertRaises(u.Refused): u.baseline.api('repos/example/fixture', self.new)


class NativeWiringTests(unittest.TestCase):
    def setUp(self):
        self.native = (ROOT / 'release/test-clean-version-upgrade.ps1').read_text('utf-8-sig')
        self.jobs = yaml.safe_load((ROOT / '.github/workflows/preflight.yml').read_text('utf-8-sig'))['jobs']

    def test_guard_and_byte_verifier_precede_native_code(self):
        for term in ('GITHUB_ACTIONS', 'github-hosted', 'GITHUB_REPOSITORY_ID', 'PSEdition',
                     'TQR_NATIVE_LAB_RUN', 'prepare-clean-upgrade.py', 'Require-EmptyProductState'):
            self.assertLess(self.native.index(term), self.native.index('Add-Type -Path'))
        self.assertIn('if($LASTEXITCODE -ne 0)', self.native)

    def test_transition_executes_real_candidate_not_reflection(self):
        section = self.native.split("$stage='actual_version_upgrade'", 1)[1].split("$stage='installed_candidate_activation'", 1)[0]
        self.assertIn('$setup=Launch-Installer $newExe $newHash', section)
        self.assertIn('Assert-Files $newPlan', section)
        self.assertIn('$installed.versionCode -gt $oldCode', section)
        calls = re.findall(r"Native\s+\$[a-zA-Z]+\s+'([^']+)'", section)
        self.assertEqual(set(calls), {'ReadConfiguredPeer', 'IsStartupEnabled'})

    def test_old_installer_is_really_executed_for_downgrade(self):
        section = self.native.split("$stage='downgrade_refusal'", 1)[1].split('}catch{', 1)[0]
        self.assertIn('Launch-Installer $oldExe $oldHash', section)
        self.assertIn('Assert-Files $newPlan', section)
        self.assertIn('$older.ExitCode -eq 10', section)

    def test_no_network_reset_or_unbounded_process_cleanup(self):
        for value in ('Restart-Service', 'Start-Service', 'netsh ', 'tailscale up',
                      'Set-DnsClientServerAddress', 'Stop-Process -Name', '--self-test'):
            self.assertNotIn(value, self.native)
        self.assertIn('StartTime.ToUniversalTime().Ticks -ne $entry.started', self.native)
        self.assertIn('if($passed -and $owned)', self.native)

    def test_evidence_does_not_claim_unperformed_acceptance(self):
        section = self.native.split('[pscustomobject]@{')[-1]
        for term in ('desktopElevationTested=$false', 'publicFeedVerified=$false', 'interruptedUpgradeTested=$false'):
            self.assertIn(term, section)
        for term in ('$identity.User', '$env:USERNAME', '$env:COMPUTERNAME', '.Message', '$configHash'):
            self.assertNotIn(term, section)

    def test_native_job_waits_for_verified_same_run_inputs(self):
        job = self.jobs['clean-version-upgrade']
        self.assertEqual(job['needs'], ['preflight', 'clean-upgrade-inputs', 'clean-setup-entry'])
        self.assertEqual(job['defaults']['run']['shell'], 'powershell')
        self.assertEqual(job['permissions'], {'contents': 'read', 'actions': 'read'})
        self.assertIn("github.repository_id == '1398720044'", job['if'])
        transfer = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/download-artifact@'))
        self.assertEqual(set(transfer['with']), {'name', 'path'})
        self.assertEqual(transfer['with']['name'], 'clean-version-upgrade-inputs')

    def test_output_allowlists_are_exact(self):
        for name, count in (('clean-upgrade-inputs', 13), ('clean-version-upgrade', 2)):
            job = self.jobs[name]
            upload = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/upload-artifact@'))
            paths = upload['with']['path'].splitlines()
            self.assertEqual(len(paths), count)
            self.assertTrue(all('*' not in p for p in paths))
            self.assertEqual(job['permissions'], {'contents': 'read', 'actions': 'read'})
            self.assertIs(job['steps'][0]['with']['persist-credentials'], False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
