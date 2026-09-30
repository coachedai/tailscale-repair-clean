#!/usr/bin/env python3
"""Offline contracts for development builds and standalone Setup resources."""
import json
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

def text(name):
    return (ROOT / name).read_text('utf-8-sig')

class BuildProfileTests(unittest.TestCase):
    def test_public_validation_is_default(self):
        for name in ('release/build.ps1', 'release/build-public.ps1', 'release/test-build-validation.ps1'):
            self.assertIn("$ValidationProfile='PublicRelease'", text(name))
        self.assertIn("-ValidationProfile $ValidationProfile", text('release/build-public.ps1'))

    def test_public_pipelines_never_select_development_validation_profile(self):
        for name in ('.github/workflows/release.yml', '.github/workflows/auto-repair-development.yml'):
            self.assertNotIn('-ValidationProfile Development', text(name))
        for name in ('release/publish.json', 'release/preview-publish.json'):
            self.assertIs(json.loads(text(name))['publish'], False)

    def test_packaging_transforms_accept_public_development_profile(self):
        routing = text('release/add-native-setup-routing.ps1')
        clarity = text('release/add-status-clarity.ps1')
        clarity_test = text('release/test-status-clarity.ps1')
        self.assertIn("@('PublicRelease','Development','PrivateDevelopment')", routing)
        self.assertIn("[ValidateSet('PublicRelease','Development','PrivateDevelopment')]", clarity)
        self.assertIn("[ValidateSet('PublicRelease','Development','PrivateDevelopment')]", clarity_test)

    def test_development_profile_is_bound_and_not_public_acceptance(self):
        source = text('release/test-build-validation.ps1')
        for value in ('GITHUB_REPOSITORY_ID', '1398720044', 'GITHUB_EVENT_PATH', '$event.repository.private -eq $false', '$event.repository.full_name', '$p.publish', '$publicFeedVerified=$false', 'publishable=($passed -and $publicFeedVerified)'):
            self.assertIn(value, source)
        self.assertIn("if($ValidationProfile -eq 'Development')", source)
        self.assertIn("if($ValidationProfile -eq 'PublicRelease')", source)
        self.assertIn('--network-self-test --channel ', source)
        self.assertNotIn('TQR_UPDATER_SELFTEST_TOKEN', source)

    def test_no_response_is_not_public_success(self):
        source = text('src/native/UpdaterEntry.cs')
        self.assertNotIn('return endpointWasReachable ? lastFailure : 0;', source)
        self.assertIn('return lastFailure;', source)

    def test_bundle_has_no_external_input_or_credentials(self):
        source = text('src/native/EmbeddedSetupPackage.cs')
        for value in ('GetManifestResourceStream("Tqr.SetupPayload")', 'FileMode.CreateNew', 'SHA256.Create()', 'RefuseDowngrade', 'HasExistingInstallation'):
            self.assertIn(value, source)
        for value in ('WebRequest', 'DownloadFile', 'GetEnvironmentVariable', 'Authorization', 'Process.Start'):
            self.assertNotIn(value, source)

    def test_bundle_keeps_protected_setup_path(self):
        source = text('release/build-standalone-setup.ps1')
        for value in ('PublicSetupHost.cs', 'PublicSetupEntry.cs', 'OperationGate.cs', 'VerifyPackage(extracted, package)', 'embedded.CopyTo(zip)', 'PreserveOrWriteConfig(peer, upgradeOnly)', '--self-test-installer', '--verify-bundle'):
            self.assertIn(value, source)
        for value in ('RegisterRepairTask();', 'ApplyFiles(files, work);', 'RequireRequesterIdentity(requesterSid);'):
            self.assertNotIn(value, source)

    def test_native_pipeline_keeps_package_tests(self):
        source = text('.github/workflows/preflight.yml')
        workflow = yaml.safe_load(source)
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        for name in ('test-packaged-runtime.ps1', 'test-passive-startup-health.ps1', 'test-passive-startup-work.ps1', 'test-local-control-center.ps1', 'test-vpn-awareness.ps1', 'test-update-channels.ps1', 'test-standalone-setup.ps1', 'test-build-profile.py'):
            self.assertIn(name, source)
        self.assertIn('if: success()', source)
        self.assertNotIn('continue-on-error', source)

    def test_candidate_version_is_monotonic_and_unpublished(self):
        version = json.loads(text('version.json'))
        publish = json.loads(text('release/publish.json'))
        self.assertEqual(version['version'], '3.0.0-rc.12')
        self.assertEqual(version['versionCode'], 30001012)
        self.assertEqual((version['version'], version['versionCode']), (publish['version'], publish['versionCode']))
        for name in ('updates/latest.json', 'updates/preview.json'):
            self.assertIs(json.loads(text(name))['published'], False)

if __name__ == '__main__':
    unittest.main(verbosity=2)