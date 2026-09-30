#!/usr/bin/env python3
"""Check the published documentation set and local Markdown links."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = {
    'README.md', 'CONTRIBUTING.md', 'docs/INSTALL.md', 'docs/PRIVACY.md',
}


class DocumentationTests(unittest.TestCase):
    def test_document_set(self):
        actual = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*')
                  if p.is_file() and p.suffix.lower() == '.md'
                  and '.git' not in p.relative_to(ROOT).parts}
        self.assertTrue(actual == DOCUMENTS, 'Unexpected documentation set')

    def test_local_links_resolve(self):
        for name in sorted(DOCUMENTS):
            source = ROOT / name
            for target in re.findall(r'(?<!!)\[[^\]]*\]\(([^)]+)\)', source.read_text('utf-8-sig')):
                if '://' in target or target.startswith(('#', 'mailto:')):
                    continue
                target = target.split('#', 1)[0]
                resolved = (source.parent / target).resolve()
                self.assertTrue(resolved.is_relative_to(ROOT), 'Link escapes repository')
                self.assertTrue(resolved.is_file(), 'Missing documentation target')

    def test_field_pack_uses_current_pinned_candidate(self):
        source = (ROOT / '.github/workflows/field-pack.yml').read_text('utf-8-sig')
        self.assertIn('Assemble current RC physical acceptance pack', source)
        self.assertNotIn('push:', source)
        self.assertIn("Join-Path $env:RUNNER_TEMP 'tqr-field-pack'", source)
        self.assertIn('release/prepare-released-migration.py', source)
        self.assertIn('candidateArtifactId -ne 11107315062', source)
        self.assertIn('ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17', source)
        self.assertIn('f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6', source)
        self.assertIn(r"Copy-Item .\release\field-verify.ps1 (Join-Path $pack 'VERIFY-RC12-AFTER-INSTALL.ps1')", source)
        self.assertIn(r"Copy-Item .\release\field-transition-verify.ps1 (Join-Path $pack 'VERIFY-RC12-TRANSITIONS.ps1')", source)
        self.assertIn("'VERIFY-RC12-AFTER-INSTALL.ps1'", source)
        self.assertIn("'VERIFY-RC12-TRANSITIONS.ps1'", source)
        self.assertNotIn('.md', source.lower())
        self.assertIn('RC11-to-RC12 migration acceptance', source)
        self.assertIn('RC12 physical post-Setup verification passed', source)
        self.assertNotIn('RC11-to-RC11', source)
        self.assertIn('privacy-scan.ps1 -Root $support -SkipRepositoryIdentity', source)
        self.assertNotIn('privacy-scan.ps1 -Root $pack -SkipRepositoryIdentity', source)
        self.assertNotIn('migration-accepted-receipt.json', source)
        self.assertNotIn('v3.0.0-rc.1', source)
        self.assertNotIn('field-preview.ps1', source)
        self.assertNotIn('START-RC1-FIELD-BRIDGE', source)
        self.assertNotIn('phase6.4-field-acceptance.md', source)


    def test_field_verifier_is_read_only_and_privacy_bounded(self):
        source = (ROOT / 'release/field-verify.ps1').read_text('utf-8-sig')
        self.assertIn('TqrFieldProcessProbe', source)
        self.assertIn('PROCESS_QUERY_LIMITED_INFORMATION', source)
        self.assertIn('ElevationState', source)
        self.assertIn("GetProcessesByName('TailscaleQuickRepair')", source)
        self.assertIn('containsDeviceData=$false', source)
        self.assertIn('containsNetworkData=$false', source)
        self.assertIn("'Verifier is running without elevation'", source)
        self.assertIn("'Resident Quick Repair process is not elevated after Setup'", source)
        self.assertNotIn('Get-Content -LiteralPath $configPath', source)
        self.assertNotIn('ReadAllText($configPath', source)
        self.assertNotIn('Exception.Message', source)
        self.assertNotIn('.MainModule', source)
        self.assertNotIn('Invoke-AutoRepair', source)
        self.assertNotIn('Repair-Backend', source)
        self.assertNotIn('tailscale ping', source)

    def test_documentation_check_runs_in_preflight(self):
        source = (ROOT / '.github/workflows/preflight.yml').read_text('utf-8-sig')
        self.assertIn('python3 -B release/test-documentation.py', source)
        self.assertIn('python3 -B release/test-field-transition-boundaries.py', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)