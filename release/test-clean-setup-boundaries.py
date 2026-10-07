#!/usr/bin/env python3
"""Synthetic staged-input regressions and native acceptance wiring checks."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('staged', ROOT / 'release/verify-clean-baseline-inputs.py')
staged = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staged)


class InputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = '1' * 40
        version = '3.0.0-rc.12'
        self.assets = ['TailscaleQuickRepair-' + version + '.zip',
                       'TailscaleQuickRepair-SetupPackage-' + version + '.zip',
                       'TailscaleQuickRepair-Standalone-' + version + '.exe']
        files = {}
        for name in self.assets:
            data = ('synthetic-baseline:' + name).encode('ascii')
            checksum = hashlib.sha256(data).hexdigest()
            (self.root / name).write_bytes(data)
            (self.root / (name + '.sha256')).write_text(checksum, encoding='ascii')
            files[name] = {'size': len(data), 'sha256': checksum}
        self.pins = {'schema': 1, 'repository': staged.REPOSITORY,
                     'repositoryId': staged.REPOSITORY_ID, 'source': '2' * 40, 'tree': '3' * 40,
                     'runId': 42, 'version': version, 'versionCode': 30001012,
                     'artifacts': {'packages': {'id': 11}, 'evidence': {'id': 12}}, 'files': files}
        self.receipt = {'schema': 1, 'role': 'upgrade-test-predecessor',
                        'repository': staged.REPOSITORY, 'repositoryId': staged.REPOSITORY_ID,
                        'baselineSource': self.pins['source'], 'baselineRun': self.pins['runId'],
                        'testSource': self.source, 'version': version, 'versionCode': self.pins['versionCode'],
                        'artifacts': copy.deepcopy(self.pins['artifacts']), 'files': copy.deepcopy(files),
                        'assertionCounts': {name: 1 for name in staged.REPORTS}, 'passed': True,
                        'installerExecuted': False, 'upgradeExecuted': False,
                        'desktopConsentTested': False, 'publicFeedVerified': False, 'publicationAllowed': False}
        self.save()

    def save(self):
        (self.root / 'baseline-receipt.json').write_text(json.dumps(self.receipt), encoding='utf-8')

    def verify(self):
        return staged.verify(self.root, self.pins, self.source)

    def test_valid_fixed_input(self):
        self.assertIs(self.verify()['passed'], True)

    def test_wrong_source(self):
        self.receipt['testSource'] = '4' * 40
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_changed_source_pin(self):
        self.pins['source'] = '5' * 40
        with self.assertRaises(staged.Refused): self.verify()

    def test_wrong_repository(self):
        self.pins['repository'] = 'example/fixture'
        with self.assertRaises(staged.Refused): self.verify()

    def test_wrong_numeric_repository(self):
        self.pins['repositoryId'] = 1
        with self.assertRaises(staged.Refused): self.verify()

    def test_bool_does_not_satisfy_integer_identity(self):
        self.receipt['schema'] = True
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_altered_asset(self):
        with (self.root / self.assets[2]).open('ab') as handle: handle.write(b'x')
        with self.assertRaises(staged.Refused): self.verify()

    def test_altered_checksum(self):
        (self.root / (self.assets[0] + '.sha256')).write_text('0' * 64)
        with self.assertRaises(staged.Refused): self.verify()

    def test_extra_file(self):
        (self.root / 'unexpected.txt').write_text('synthetic')
        with self.assertRaises(staged.Refused): self.verify()

    def test_missing_file(self):
        (self.root / self.assets[0]).unlink()
        with self.assertRaises(staged.Refused): self.verify()

    def test_linked_asset(self):
        target = self.root / self.assets[0]
        target.unlink()
        try: target.symlink_to(self.root / self.assets[1])
        except OSError: self.skipTest('Local symbolic links unavailable')
        with self.assertRaises(staged.Refused): self.verify()

    def test_linked_parent(self):
        with tempfile.TemporaryDirectory() as parent:
            alias = Path(parent) / 'alias'
            try: alias.symlink_to(self.root, target_is_directory=True)
            except OSError: self.skipTest('Local symbolic links unavailable')
            with self.assertRaises(staged.Refused): staged.verify(alias, self.pins, self.source)

    def test_lexical_parent_traversal_is_rejected(self):
        with self.assertRaises(staged.Refused): staged.no_links(self.root / '..' / self.root.name)

    def test_scope_cannot_claim_execution(self):
        for name in ('installerExecuted', 'upgradeExecuted', 'desktopConsentTested',
                     'publicFeedVerified', 'publicationAllowed'):
            with self.subTest(name=name):
                self.receipt[name] = True
                self.save()
                with self.assertRaises(staged.Refused): self.verify()
                self.receipt[name] = False

    def test_missing_scope_flag(self):
        del self.receipt['upgradeExecuted']
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_extra_receipt_field(self):
        self.receipt['unexpected'] = 'synthetic'
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_evidence_count_is_strict_positive_integer(self):
        name = next(iter(staged.REPORTS))
        for value in (True, False, 0, -1, '1', None):
            with self.subTest(value=value):
                self.receipt['assertionCounts'][name] = value
                self.save()
                with self.assertRaises(staged.Refused): self.verify()

    def test_missing_report(self):
        self.receipt['assertionCounts'].pop(next(iter(staged.REPORTS)))
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_changed_artifact_identity(self):
        self.receipt['artifacts']['packages']['id'] = 99
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_changed_file_receipt(self):
        self.receipt['files'][self.assets[0]]['sha256'] = 'a' * 64
        self.save()
        with self.assertRaises(staged.Refused): self.verify()

    def test_path_injected_version(self):
        self.pins['version'] = '../fixture'
        with self.assertRaises(staged.Refused): self.verify()

    def test_oversized_receipt(self):
        (self.root / 'baseline-receipt.json').write_bytes(b' ' * 65537)
        with self.assertRaises(staged.Refused): self.verify()

    def test_duplicate_keys_and_nonfinite_numbers(self):
        for data in (b'{"passed":true,"passed":false}', b'{"x":NaN}', b'{"x":Infinity}'):
            with self.assertRaises(staged.Refused): staged.decode(data)

    def test_refusal_does_not_echo_file_contents(self):
        (self.root / self.assets[1]).write_bytes(b'synthetic-sensitive-fixture')
        try: self.verify()
        except staged.Refused as error:
            self.assertNotIn('synthetic-sensitive-fixture', str(error))
        else: self.fail('Tampering accepted')


class NativeWiringTests(unittest.TestCase):
    def setUp(self):
        self.native = (ROOT / 'release/test-clean-setup-entry.ps1').read_text('utf-8-sig')
        self.workflow = yaml.safe_load((ROOT / '.github/workflows/preflight.yml').read_text('utf-8-sig'))
        self.job = self.workflow['jobs']['clean-setup-entry']

    def test_disposable_guard_precedes_native_loading(self):
        for guard in ('GITHUB_ACTIONS', 'github-hosted', 'RUNNER_ARCH', 'GITHUB_REPOSITORY_ID',
                      'TQR_NATIVE_LAB_RUN', 'PSEdition', 'Require-EmptyProductState',
                      'verify-clean-baseline-inputs.py', 'Repository remote mismatch.', 'Checkout identity mismatch.'):
            self.assertLess(self.native.index(guard), self.native.index('Add-Type -Path'))
        self.assertIn('if($LASTEXITCODE -ne 0)', self.native)

    def test_servicing_is_real_process_not_reflected_install(self):
        section = self.native.split("$stage='same_version_servicing'", 1)[1].split("$stage='installed_relaunch'", 1)[0]
        self.assertIn('$setup=Launch-Setup', section)
        self.assertIn('[IO.File]::WriteAllText($damaged', section)
        self.assertIn('Assert-Files $plan', section)
        self.assertNotIn("Native $type 'ApplyFiles'", section)
        self.assertNotIn('--self-test', self.native)

    def test_no_live_repair_or_network_authority(self):
        for forbidden in ('Start-Service', 'Restart-Service', 'Restart-NetAdapter', 'netsh ',
                          'tailscale up', 'Set-DnsClientServerAddress', 'Stop-Process -Name'):
            self.assertNotIn(forbidden, self.native)
        self.assertIn('if(Get-Service Tailscale', self.native)
        self.assertIn('if($passed -and $owned)', self.native)
        self.assertIn('StartTime.ToUniversalTime().Ticks -ne $entry.started', self.native)

    def test_evidence_is_scoped_without_raw_identity(self):
        evidence = self.native.split('[pscustomobject]@{')[-1]
        for field in ('versionUpgradeTested=$false', 'desktopElevationTested=$false', 'publicFeedVerified=$false'):
            self.assertIn(field, evidence)
        for forbidden in ('$identity.User', '$env:USERNAME', '$env:COMPUTERNAME', '$configHash', '.Message'):
            self.assertNotIn(forbidden, evidence)
        self.assertIn('Existing evidence must not be overwritten.', self.native)

    def test_native_job_waits_for_same_run_prerequisites(self):
        self.assertEqual(self.job['needs'], ['preflight', 'clean-baseline', 'startup-windows'])
        self.assertEqual(self.job['runs-on'], 'windows-latest')
        self.assertEqual(self.job['defaults']['run']['shell'], 'powershell')
        self.assertEqual(self.job['permissions'], {'contents': 'read', 'actions': 'read'})
        self.assertIn("github.repository_id == '1398720044'", self.job['if'])
        self.assertEqual(self.job['steps'][0]['with']['ref'], '${{ github.sha }}')
        self.assertIs(self.job['steps'][0]['with']['persist-credentials'], False)

    def test_transfer_cannot_select_another_run(self):
        step = next(s for s in self.job['steps'] if s.get('uses', '').startswith('actions/download-artifact@'))
        self.assertEqual(set(step['with']), {'name', 'path'})
        self.assertEqual(step['with']['name'], 'clean-upgrade-baseline')

    def test_upload_is_exact_typed_allowlist(self):
        step = next(s for s in self.job['steps'] if s.get('uses', '').startswith('actions/upload-artifact@'))
        paths = step['with']['path'].splitlines()
        self.assertEqual(len(paths), 2)
        self.assertTrue(all(p.endswith('.json') and '*' not in p for p in paths))
        commands = '\n'.join(s.get('run', '') for s in self.job['steps'])
        for field in ('versionUpgradeTested', 'desktopElevationTested', 'publicFeedVerified', 'sameVersionServicingExecuted'):
            self.assertIn(field, commands)
        self.assertIn('git diff --exit-code', commands)


if __name__ == '__main__':
    unittest.main(verbosity=2)
