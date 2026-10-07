#!/usr/bin/env python3
"""Synthetic regressions for the read-only clean baseline boundary."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('clean_baseline', ROOT / 'release/prepare-clean-baseline.py')
BASELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASELINE)
PINS = json.loads((ROOT / 'release/clean-baseline.json').read_text())


def raw(value):
    return json.dumps(value, sort_keys=True).encode('utf-8')


def pin(data):
    return {'size': len(data), 'sha256': BASELINE.digest(data)}


def bundle(files):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        for key, value in files.items():
            archive.writestr(key, value)
    return stream.getvalue()


def package(setup):
    files = {name: b'Synthetic fixture.\n' for name in (
        'app/Advanced-Diagnostics.ps1', 'app/Tailscale-Repair-UI.ps1',
        'app/TailscaleQuickRepair.Operations.dll', 'app/TailscaleQuickRepairSetup.exe',
        'app/TailscaleQuickRepairUpdater.exe')}
    if setup:
        for name in ('app/TailscaleQuickRepair.exe', 'program/Auto-Repair-Monitor.ps1',
                     'program/Repair-Backend.ps1', 'program/TailscaleQuickRepair.Operations.dll'):
            files[name] = b'Synthetic fixture.\n'
    else:
        files['app/protected-update.json'] = raw({'schema': 2, 'versionCode': PINS['versionCode'], 'channel': 'preview'})
    identity = {'schema': 1, 'product': 'Tailscale Quick Repair', 'version': PINS['version'], 'versionCode': PINS['versionCode']}
    integrity = dict(identity, algorithm='SHA256', profile='setup' if setup else 'update', files=[
        dict(path=n[4:], **pin(data)) for n, data in files.items()
        if n.startswith('app/') and n != 'app/protected-update.json'])
    files['app/integrity-manifest.json'] = raw(integrity)
    files['version.json'] = raw(dict(identity, channel='preview'))
    files['package-manifest.json'] = raw(dict(identity, files=[dict(path=n, **pin(data)) for n, data in files.items()]))
    return bundle({n.replace('/', '\\'): data for n, data in files.items()})


def fixture():
    pins = copy.deepcopy(PINS)
    update, setup = package(False), package(True)
    standalone = b'MZ' + setup + b'Synthetic fixture.'
    files = dict(zip(BASELINE.asset_names(pins), (update, setup, standalone)))
    pins['files'] = {n: pin(data) for n, data in files.items()}
    files['TailscaleQuickRepair-Bootstrap-' + pins['version'] + '.exe'] = b'MZsynthetic'
    files['TailscaleQuickRepair-Setup-' + pins['version'] + '.exe'] = b'MZsynthetic'
    files.update({n + '.sha256': BASELINE.digest(data).encode('ascii') for n, data in list(files.items())})
    build = {'schema': 1, 'source': pins['source'], 'passed': True, 'profile': 'Development',
             'publicFeedVerified': False, 'publishable': False, 'cases': [{'name': 'Synthetic case', 'passed': True}]}
    files['build-validation.json'] = raw(build)
    report = {'source': pins['source'], 'passed': True, 'cases': [{'name': 'Synthetic case', 'passed': True}]}
    evidence = {'tqr-startup-evidence/' + name: raw(report) for name in BASELINE.REPORTS}
    evidence['tqr-startup-evidence/native-recurrence-trace.json'] = raw({
        'source': pins['source'], 'channelRestored': True, 'eventReadError': 0})
    evidence['tqr-startup-dist/build-validation.json'] = raw(build)
    packages, proof = bundle(files), bundle(evidence)
    pins['artifacts']['packages'].update(pin(packages))
    pins['artifacts']['evidence'].update(pin(proof))
    return pins, files, evidence


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.pins, self.files, self.evidence = fixture()

    def verify(self):
        packages, proof = bundle(self.files), bundle(self.evidence)
        self.pins['artifacts']['packages'].update(pin(packages))
        self.pins['artifacts']['evidence'].update(pin(proof))
        return BASELINE.verify_payloads(packages, proof, self.pins)

    def test_workflow_is_read_only_and_waits_for_source_gate(self):
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/preflight.yml').read_text())
        job = workflow['jobs']['clean-baseline']
        self.assertEqual(job['needs'], 'preflight')
        self.assertEqual(job['runs-on'], 'ubuntu-latest')
        self.assertEqual(job['permissions'], {'contents': 'read', 'actions': 'read'})
        self.assertIn(BASELINE.REPOSITORY, job['if'])
        self.assertIn(str(BASELINE.REPOSITORY_ID), job['if'])
        self.assertEqual(job['steps'][0]['with']['ref'], '${{ github.sha }}')
        self.assertIs(job['steps'][0]['with']['persist-credentials'], False)
        commands = '\n'.join(step.get('run', '') for step in job['steps'])
        self.assertIn('python3 -B release/prepare-clean-baseline.py', commands)
        for forbidden in ('msiexec', 'Start-Process', 'git push', 'gh release', 'sudo', 'powershell'):
            self.assertNotIn(forbidden, commands)
        uploader = job['steps'][-1]
        self.assertEqual(uploader['with']['if-no-files-found'], 'error')
        uploaded = uploader['with']['path'].splitlines()
        expected = set(BASELINE.asset_names(PINS)) | {n + '.sha256' for n in BASELINE.asset_names(PINS)} | {'baseline-receipt.json'}
        self.assertEqual({line.rsplit('/', 1)[-1] for line in uploaded}, expected)
        self.assertNotIn('*', uploader['with']['path'])
        self.assertNotIn('.md', uploader['with']['path'])
        self.assertIn('release/test-clean-baseline.py', str(workflow['jobs']['preflight']['steps']))

    def test_valid_pins_and_synthetic_packages(self):
        BASELINE.validate_pins(self.pins)
        files, counts = self.verify()
        self.assertEqual(set(files), set(BASELINE.asset_names(self.pins)))
        self.assertEqual(counts, {name: 1 for name in BASELINE.REPORTS})

    def test_pin_schema_and_boundary(self):
        for key, value in [('repository', 'fixture/not-allowed'), ('repositoryId', 1), ('schema', True),
                           ('source', 'invalid'), ('tree', 'invalid'), ('runId', True), ('versionCode', False),
                           ('version', '../fixture'), ('version', '3.0.0'), ('extra', 'fixture')]:
            with self.subTest(key=key, value=value):
                changed = copy.deepcopy(self.pins); changed[key] = value
                with self.assertRaises(BASELINE.Refused):
                    BASELINE.validate_pins(changed)

    def test_artifact_and_asset_pins(self):
        for key, value in [('id', 0), ('id', True), ('name', 'wrong'), ('size', -1),
                           ('size', BASELINE.MAX_ARCHIVE + 1), ('sha256', 'bad')]:
            changed = copy.deepcopy(self.pins); changed['artifacts']['packages'][key] = value
            with self.assertRaises(BASELINE.Refused):
                BASELINE.validate_pins(changed)
        changed = copy.deepcopy(self.pins); changed['files']['fixture.md'] = pin(b'fixture')
        with self.assertRaises(BASELINE.Refused):
            BASELINE.validate_pins(changed)

    def test_json_duplicates_and_nonfinite_values(self):
        for value in (b'{"passed":true,"passed":false}', b'{"x":NaN}', b'{"x":Infinity}', b'\xff', b'bad'):
            with self.assertRaises(BASELINE.Refused):
                BASELINE.decode(value)

    def test_integrity_has_no_soft_failure(self):
        for value in (b'fixture changed', b'', b'fixture\x00'):
            with self.assertRaises(BASELINE.Refused):
                BASELINE.verify_bytes(value, pin(b'fixture'))

    def test_unsafe_archive_paths(self):
        for name in ('../a', '/a', 'a/../b', 'a//b', './a', 'a\\b', 'C:/a', 'a:stream',
                     'a./b', 'a /b', 'a\x01b', 'CON', 'app/NUL.txt', 'app/LPT1'):
            with self.subTest(name=name), self.assertRaises(BASELINE.Refused):
                BASELINE.archive(bundle({name: b'fixture'}))

    def test_windows_package_normalization_and_collision(self):
        self.assertEqual(BASELINE.archive(bundle({'app\\file': b'fixture'}), windows=True), {'app/file': b'fixture'})
        for files in ({'app/file': b'a', 'app\\file': b'b'}, {'app/File': b'a', 'app/file': b'b'}):
            with self.assertRaises(BASELINE.Refused):
                BASELINE.archive(bundle(files), windows=True)

    def test_archive_symlink_and_directory(self):
        for mode, name in [(stat.S_IFLNK | 0o777, 'link'), (stat.S_IFDIR | 0o755, 'folder/')]:
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as handle:
                info = zipfile.ZipInfo(name); info.create_system = 3; info.external_attr = mode << 16
                handle.writestr(info, b'fixture')
            with self.assertRaises(BASELINE.Refused):
                BASELINE.archive(stream.getvalue())

    def test_archive_size_and_entry_limits(self):
        for data in (b'bad', bundle({str(n): b'x' for n in range(101)}), bundle({'large': b'x' * (4 * 1024 * 1024 + 1)})):
            with self.assertRaises(BASELINE.Refused):
                BASELINE.archive(data)

    def test_missing_or_extra_distribution_is_refused(self):
        for action in ('missing', 'extra'):
            with self.subTest(action=action):
                self.setUp()
                if action == 'missing':
                    del self.files[BASELINE.asset_names(self.pins)[0]]
                else:
                    self.files['fixture.md'] = b'fixture'
                with self.assertRaises(BASELINE.Refused):
                    self.verify()

    def test_checksum_and_embedded_payload(self):
        key = BASELINE.asset_names(self.pins)[2]
        self.files[key + '.sha256'] = b'0' * 64
        with self.assertRaises(BASELINE.Refused):
            self.verify()
        self.files[key] = b'MZsynthetic-not-a-package'
        self.files[key + '.sha256'] = BASELINE.digest(self.files[key]).encode()
        self.pins['files'][key] = pin(self.files[key])
        with self.assertRaisesRegex(BASELINE.Refused, 'embedded_payload'):
            self.verify()

    def test_package_manifest_and_version(self):
        for changed in ('wrong_version', 'wrong_hash', 'wrong_size', 'extra_file', 'duplicate_record'):
            files = BASELINE.archive(package(True), windows=True)
            if changed == 'wrong_version':
                value = BASELINE.decode(files['version.json']); value['versionCode'] += 1; files['version.json'] = raw(value)
            elif changed == 'extra_file':
                files['app/fixture.md'] = b'fixture'
            else:
                value = BASELINE.decode(files['package-manifest.json'])
                if changed == 'wrong_hash': value['files'][0]['sha256'] = '0' * 64
                if changed == 'wrong_size': value['files'][0]['size'] = True
                if changed == 'duplicate_record': value['files'][0] = value['files'][1]
                files['package-manifest.json'] = raw(value)
            with self.subTest(changed=changed), self.assertRaises(BASELINE.Refused):
                BASELINE.verify_package(bundle(files), self.pins, True)

    def test_evidence_must_be_present_typed_and_same_source(self):
        key = 'tqr-startup-evidence/' + BASELINE.REPORTS[0]
        for value in [None, {'passed': True}, {'source': self.pins['source'], 'passed': 'true'},
                      {'source': self.pins['source'], 'passed': 1}, {'source': self.pins['source'], 'passed': True, 'cases': []},
                      {'source': self.pins['source'], 'passed': True, 'cases': [{'passed': False}]},
                      {'source': 'a' * 40, 'passed': True, 'cases': [{'passed': True}]}]:
            self.setUp()
            if value is None: del self.evidence[key]
            else: self.evidence[key] = raw(value)
            with self.assertRaises(BASELINE.Refused):
                self.verify()

    def test_recurrence_restoration_and_no_read_error(self):
        key = 'tqr-startup-evidence/native-recurrence-trace.json'
        for name, value in [('channelRestored', False), ('channelRestored', 'true'), ('eventReadError', 1), ('eventReadError', '0')]:
            self.setUp(); trace = BASELINE.decode(self.evidence[key]); trace[name] = value; self.evidence[key] = raw(trace)
            with self.assertRaisesRegex(BASELINE.Refused, 'recurrence'):
                self.verify()

    def test_build_is_not_release_acceptance(self):
        for key, value in [('publishable', True), ('publicFeedVerified', True), ('profile', 'PublicRelease')]:
            self.setUp(); build = BASELINE.decode(self.files['build-validation.json']); build[key] = value
            self.files['build-validation.json'] = self.evidence['tqr-startup-dist/build-validation.json'] = raw(build)
            with self.assertRaisesRegex(BASELINE.Refused, 'publication_boundary'):
                self.verify()

    def test_evidence_build_receipt_must_match_packages(self):
        self.evidence['tqr-startup-dist/build-validation.json'] += b' '
        with self.assertRaisesRegex(BASELINE.Refused, 'build_receipt'):
            self.verify()

    def run_metadata(self):
        repo = {'id': BASELINE.REPOSITORY_ID, 'full_name': BASELINE.REPOSITORY}
        return {'id': self.pins['runId'], 'repository': repo, 'head_repository': repo.copy(),
                'head_sha': self.pins['source'], 'head_branch': 'main', 'event': 'push',
                'path': '.github/workflows/preflight.yml', 'status': 'completed', 'conclusion': 'success',
                'run_attempt': 1, 'head_commit': {'tree_id': self.pins['tree']}}

    def test_only_successful_exact_main_run(self):
        good = self.run_metadata(); BASELINE.verify_run(good, self.pins)
        for key, value in [('id', 1), ('head_sha', 'a' * 40), ('head_branch', 'work/public'),
                           ('conclusion', 'failure'), ('status', 'in_progress'), ('run_attempt', 2),
                           ('run_attempt', True), ('event', 'pull_request'), ('path', '.github/workflows/other.yml')]:
            changed = copy.deepcopy(good); changed[key] = value
            with self.assertRaises(BASELINE.Refused): BASELINE.verify_run(changed, self.pins)
        for key in ('repository', 'head_repository'):
            changed = copy.deepcopy(good); changed[key]['id'] = 1
            with self.assertRaises(BASELINE.Refused): BASELINE.verify_run(changed, self.pins)

    def test_artifact_identity_and_expiry(self):
        pin = self.pins['artifacts']['packages']
        good = {'id': pin['id'], 'name': pin['name'], 'size_in_bytes': pin['size'],
                'expired': False, 'digest': 'sha256:' + pin['sha256'], 'workflow_run': {
                    'id': self.pins['runId'], 'repository_id': BASELINE.REPOSITORY_ID,
                    'head_repository_id': BASELINE.REPOSITORY_ID, 'head_sha': self.pins['source'], 'head_branch': 'main'}}
        BASELINE.verify_artifact(good, pin, self.pins)
        for key, value in [('id', 1), ('name', 'wrong'), ('expired', True), ('expired', 'false'),
                           ('digest', 'sha256:' + '0' * 64), ('size_in_bytes', pin['size'] + 1)]:
            changed = copy.deepcopy(good); changed[key] = value
            with self.assertRaises(BASELINE.Refused): BASELINE.verify_artifact(changed, pin, self.pins)
        for key, value in [('repository_id', 1), ('head_repository_id', 1), ('head_sha', 'a' * 40), ('id', 1), ('head_branch', 'other')]:
            changed = copy.deepcopy(good); changed['workflow_run'][key] = value
            with self.assertRaises(BASELINE.Refused): BASELINE.verify_artifact(changed, pin, self.pins)

    def test_api_only_reads_fixed_endpoints(self):
        with mock.patch.object(BASELINE.subprocess, 'Popen') as start:
            for path in ('repos/fixture/other', 'repos/' + BASELINE.REPOSITORY + '/contents',
                         'https://example.invalid/', 'repos/' + BASELINE.REPOSITORY + '/actions/artifacts/1/zip'):
                with self.assertRaises(BASELINE.Refused): BASELINE.api(path, self.pins)
            start.assert_not_called()

    def test_api_response_is_bounded_and_uses_get(self):
        class Process:
            def __init__(self, data): self.stdout = io.BytesIO(data); self.returncode = 0
            def wait(self, timeout): return self.returncode
            def poll(self): return self.returncode
            def kill(self): self.returncode = -9
        for data, okay in [(b'{}', True), (b'x' * (BASELINE.MAX_ARCHIVE + 1), False)]:
            with mock.patch.object(BASELINE.subprocess, 'Popen', return_value=Process(data)) as call:
                path = 'repos/' + BASELINE.REPOSITORY
                if okay: self.assertEqual(BASELINE.api(path, self.pins), {})
                else:
                    with self.assertRaises(BASELINE.Refused): BASELINE.api(path, self.pins)
                self.assertIn('GET', call.call_args.args[0])
                self.assertNotIn('shell', call.call_args.kwargs)

    def test_no_real_environment_or_network_needed(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(BASELINE.subprocess, 'Popen') as start:
            with self.assertRaisesRegex(BASELINE.Refused, 'ci_boundary'):
                BASELINE.environment(ROOT)
            start.assert_not_called()

    def test_staging_is_allowlisted_and_non_destructive(self):
        assets, counts = self.verify()
        with tempfile.TemporaryDirectory() as tmp:
            output = BASELINE.stage(Path(tmp), self.pins, assets, counts, 'a' * 40)
            self.assertEqual(set(p.name for p in output.iterdir()), set(assets) | {n + '.sha256' for n in assets} | {'baseline-receipt.json'})
            receipt = json.loads((output / 'baseline-receipt.json').read_text())
            for key in ('installerExecuted', 'upgradeExecuted', 'desktopConsentTested', 'publicFeedVerified', 'publicationAllowed'):
                self.assertIs(receipt[key], False)
            saved = (output / 'baseline-receipt.json').read_bytes()
            with self.assertRaisesRegex(BASELINE.Refused, 'existing_output'):
                BASELINE.stage(Path(tmp), self.pins, assets, counts, 'a' * 40)
            self.assertEqual((output / 'baseline-receipt.json').read_bytes(), saved)

    def test_staging_fails_before_writing_bad_bytes(self):
        assets, counts = self.verify(); assets[next(iter(assets))] += b'changed'
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(BASELINE.Refused): BASELINE.stage(Path(tmp), self.pins, assets, counts, 'a' * 40)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_symlink_output_is_refused(self):
        assets, counts = self.verify()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'target'; target.mkdir()
            link = Path(tmp) / 'link'
            try: link.symlink_to(target, target_is_directory=True)
            except (OSError, NotImplementedError): self.skipTest('Symbolic links unavailable in this synthetic environment')
            with self.assertRaises(BASELINE.Refused): BASELINE.stage(link, self.pins, assets, counts, 'a' * 40)
            self.assertEqual(list(target.iterdir()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
