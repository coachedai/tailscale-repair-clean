#!/usr/bin/env python3
"""Offline synthetic regression tests; never uses a real user's repository."""
from pathlib import Path
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

AUDIT = Path(__file__).with_name('audit-git-history.py').resolve()
SPEC = importlib.util.spec_from_file_location('tqr_audit', AUDIT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tqr-synthetic-audit-')
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        # Isolate fixtures from any developer Git settings or credential helper.
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_COMMITTER_NAME='Fixture',
                        GIT_AUTHOR_EMAIL='fixture@users.noreply.github.com',
                        GIT_COMMITTER_EMAIL='fixture@users.noreply.github.com')
        for key in list(self.env):
            if key.startswith('GIT_CONFIG_KEY_') or key.startswith('GIT_CONFIG_VALUE_'):
                del self.env[key]
        self.env.pop('GIT_CONFIG_COUNT', None)
        self.git('init', '-q')
        # Detached Git maintenance can outlive a commit and race fixture cleanup.
        # Limit these settings to the disposable repository; keep cleanup strict.
        self.git('config', '--local', 'maintenance.auto', 'false')
        self.git('config', '--local', 'maintenance.autoDetach', 'false')
        self.git('config', '--local', 'gc.auto', '0')
        self.git('config', '--local', 'gc.autoDetach', 'false')
        self.write('README.md', 'Synthetic fixture.\n')
        self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env,
                              check=True, capture_output=True, timeout=10).stdout.decode().strip()

    def write(self, name, contents):
        p = self.repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(contents if isinstance(contents, bytes) else contents.encode('utf-8'))

    def commit(self, message='Synthetic revision'):
        self.git('add', '--all')
        self.git('commit', '-qm', message)

    def audit(self, known=None):
        output = self.root / 'result.json'
        if known is None:
            command = [sys.executable, str(AUDIT), '--result', str(output)]
        else:
            driver = self.root / 'driver.py'
            driver.write_text(
                'import importlib.util,sys\n'
                f's=importlib.util.spec_from_file_location("a",{str(AUDIT)!r})\n'
                'a=importlib.util.module_from_spec(s);s.loader.exec_module(a)\n'
                f'a.KNOWN_LEGACY_FINDINGS={known!r}\n'
                'sys.exit(a.main())\n')
            command = [sys.executable, str(driver), '--result', str(output)]
        before = self.git('rev-parse', 'HEAD')
        p = subprocess.run(command, cwd=self.repo, env=self.env,
                           capture_output=True, text=True, timeout=25)
        self.assertEqual(before, self.git('rev-parse', 'HEAD'))
        self.assertEqual('', self.git('status', '--porcelain'))
        result = json.loads(output.read_text())
        self.assertEqual(result['passed'], p.returncode == 0)
        return result, p.stdout + p.stderr

    @staticmethod
    def address(separator='.'):
        # Documentation-only network, composed so no literal is stored in source.
        return separator.join(map(str, (192, 0, 2, 45)))

    def reasons(self, result):
        return {x['reason'] for x in result['legacy_findings'] + result['unexpected_findings']}

    def test_fixture_maintenance_is_disabled_locally(self):
        expected = {
            'maintenance.auto': 'false',
            'maintenance.autoDetach': 'false',
            'gc.auto': '0',
            'gc.autoDetach': 'false',
        }
        for key, value in expected.items():
            with self.subTest(setting=key):
                self.assertEqual(value, self.git('config', '--local', '--get', key))

    def test_clean(self):
        result, _ = self.audit()
        self.assertTrue(result['passed'])

    def test_deleted_encoded_address(self):
        sensitive = self.address('\\.')
        self.write('fixture.ps1', sensitive)
        self.commit()
        self.write('fixture.ps1', '# removed\n')
        self.commit()
        result, log = self.audit()
        self.assertIn('escaped_literal_ipv4', self.reasons(result))
        self.assertNotIn(sensitive, log + json.dumps(result))

    def test_acknowledged_debt_still_fails(self):
        self.write('fixture.txt', self.address('\\.'))
        self.commit()
        blob = self.git('rev-parse', 'HEAD:fixture.txt')
        result, _ = self.audit({('blob', blob, 'escaped_literal_ipv4')})
        self.assertEqual(result['legacy_finding_count'], 1)
        self.assertEqual(result['unexpected_finding_count'], 0)
        self.assertFalse(result['passed'])

    def test_same_blob_under_forbidden_alias(self):
        self.write('safe.txt', 'The same content.\n')
        self.commit()
        self.git('mv', 'safe.txt', 'copy.bin')
        self.commit()
        result, _ = self.audit()
        self.assertIn('forbidden_evidence_or_opaque_file_type', self.reasons(result))

    def test_tag_message(self):
        self.git('tag', '-a', 'fixture-tag', '-m', self.address('\\.'))
        result, _ = self.audit()
        self.assertTrue(any(f['kind'] == 'tag' for f in result['unexpected_findings']))

    def test_ref_name(self):
        self.git('branch', 'fixture-' + self.address())
        result, _ = self.audit()
        self.assertTrue(any(f['kind'] == 'ref' for f in result['unexpected_findings']))

    def test_non_utf8_text(self):
        self.write('fixture.txt', bytes([255, 254, 255]))
        self.commit()
        result, _ = self.audit()
        self.assertIn('non_utf8_text_blob', self.reasons(result))

    def test_binary_in_text(self):
        self.write('fixture.txt', b'fixture\0data')
        self.commit()
        result, _ = self.audit()
        self.assertIn('binary_content_in_text_blob', self.reasons(result))

    def test_oversize_fails(self):
        self.write('fixture.txt', b'x' * (5 * 1024 * 1024 + 1))
        self.commit()
        result, _ = self.audit()
        self.assertIn('historical_text_blob_over_5mb', self.reasons(result))

    def test_symlink_not_followed(self):
        # Store a real mode-120000 Git entry without requiring operating-system
        # symlink privileges. core.symlinks=false keeps the disposable worktree
        # portable while the audit still inspects the actual symbolic-link tree.
        self.git('config', '--local', 'core.symlinks', 'false')
        self.write('link.txt', 'README.md')
        blob = self.git('hash-object', '-w', 'link.txt')
        self.git('update-index', '--add', '--cacheinfo', '120000', blob, 'link.txt')
        self.git('commit', '-qm', 'Synthetic symbolic link')
        result, _ = self.audit()
        self.assertIn('historical_symbolic_link', self.reasons(result))

    def test_cross_project_is_blocked(self):
        self.write('fixture.txt', MODULE.OTHER_PROJECT)
        self.commit()
        result, log = self.audit()
        self.assertIn('cross_project_content', self.reasons(result))
        self.assertNotIn(MODULE.OTHER_PROJECT, log + json.dumps(result))

    def test_internal_development_provenance_is_current_source_only(self):
        value = ''.join(chr(x) for x in (99,104,97,116,103,112,116))
        direct = []
        MODULE.scan_text(value, lambda kind, obj, reason: direct.append(reason), 'fixture', 'source')
        self.assertIn('internal_development_provenance', direct)

        self.write('fixture.txt', value)
        self.commit()
        result, log = self.audit()
        self.assertNotIn('internal_development_provenance', self.reasons(result))
        self.assertNotIn(value, log + json.dumps(result))

    def test_internal_development_path_is_blocked(self):
        folder = ''.join(chr(x) for x in (99,111,110,118,101,114,115,97,116,105,111,110))
        self.write(folder + '/fixture.txt', 'Synthetic fixture.\n')
        self.commit()
        result, _ = self.audit()
        self.assertIn('internal_development_path', self.reasons(result))

    def test_personal_path_not_echoed(self):
        value = 'C:' + '\\' + 'Users' + '\\' + 'SyntheticAccount' + '\\' + 'fixture'
        self.write('fixture.txt', value)
        self.commit()
        result, log = self.audit()
        self.assertIn('personal_windows_user_path', self.reasons(result))
        self.assertNotIn('SyntheticAccount', log + json.dumps(result))

    def test_email_not_echoed(self):
        value = 'fixture-person' + '@' + 'example.invalid'
        self.write('fixture.txt', value)
        self.commit()
        result, log = self.audit()
        self.assertIn('email_address', self.reasons(result))
        self.assertNotIn(value, log + json.dumps(result))

    def test_bracketed_address(self):
        self.write('fixture.txt', self.address('[.]'))
        self.commit()
        result, _ = self.audit()
        self.assertIn('bracket_encoded_literal_ipv4', self.reasons(result))

    def test_fake_token_is_not_logged(self):
        value = 'gh' + 'p_' + 'x' * 36
        self.write('fixture.txt', value)
        self.commit()
        result, log = self.audit()
        self.assertIn('github_token', self.reasons(result))
        self.assertNotIn(value, log + json.dumps(result))

    def test_large_batch_finishes(self):
        for i in range(2000):
            self.write(f'fixtures/{i}.txt', f'Unique synthetic fixture {i}.\n')
        self.commit()
        result, _ = self.audit()
        self.assertTrue(result['passed'])
        self.assertEqual(result['counts']['blobs'], 2001)

if __name__ == '__main__':
    unittest.main(verbosity=2)
