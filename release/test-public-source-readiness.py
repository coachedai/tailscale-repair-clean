#!/usr/bin/env python3
"""Fail-closed checks for making the source repository public.

This does not publish binaries or enable update feeds. It verifies only source,
history/workflow wiring and public-facing repository policy.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github' / 'workflows'


def load_json(name):
    return json.loads((ROOT / name).read_text('utf-8-sig'))


class PublicSourceReadiness(unittest.TestCase):
    def test_policy_explicitly_separates_public_source_from_release_publication(self):
        p = load_json('repository-policy.json')
        self.assertEqual(p['repository'], 'coachedai/tailscale-repair-clean')
        self.assertEqual(p['repositoryId'], 1398720044)
        self.assertIs(p['allowOtherRepositories'], False)
        self.assertEqual(p['targetVisibility'], 'public')
        self.assertIs(p['publicSourceAllowed'], True)
        self.assertIs(p['publicationAllowed'], False)
        self.assertEqual(p['publicHistoryMode'], 'retained')
        self.assertIs(p['releaseBaselineAccepted'], False)

    def test_main_branch_matches_history_policy(self):
        policy = load_json('repository-policy.json')
        if (
                policy['publicHistoryMode'] == 'single-root' and
                os.environ.get('GITHUB_ACTIONS') == 'true' and
                os.environ.get('GITHUB_REF_NAME') == 'main'
        ):
            count = subprocess.check_output(['git','rev-list','--count','HEAD'], cwd=ROOT).decode().strip()
            parents = subprocess.check_output(['git','rev-list','--parents','-n','1','HEAD'], cwd=ROOT).decode().strip().split()
            self.assertEqual(count, '1')
            self.assertEqual(len(parents), 1)

    def test_release_and_update_publication_remain_disarmed(self):
        self.assertIs(load_json('release/publish.json')['publish'], False)
        self.assertIs(load_json('release/preview-publish.json')['publish'], False)
        self.assertIs(load_json('updates/latest.json')['published'], False)
        self.assertIs(load_json('updates/preview.json')['published'], False)

    def test_public_landing_copy_is_current_and_evergreen(self):
        readme = (ROOT / 'README.md').read_text('utf-8-sig')
        install = (ROOT / 'docs' / 'INSTALL.md').read_text('utf-8-sig')
        self.assertIn('source repository and the installer/update channel are separate release boundaries', readme)
        self.assertIn('not an official Tailscale product', readme)
        self.assertIn('does not by itself publish or authorize an installer', install)
        for stale in ('current private source candidate','private CI artifacts','RC6','RC7','RC8','RC9'):
            self.assertNotIn(stale, readme)
            self.assertNotIn(stale, install)

    def test_root_has_only_expected_public_source_surfaces(self):
        expected = {
            '.gitattributes','.github','.gitignore','CONTRIBUTING.md','README.md','docs',
            'release','repository-policy.json','requirements-dev.txt','src','updates','version.json'
        }
        actual = {p.name for p in ROOT.iterdir() if p.name not in {'.git','__pycache__'}}
        self.assertEqual(actual, expected)

    def test_public_workflow_surface_is_intentional(self):
        expected = {
            'auto-repair-development.yml',
            'field-pack.yml',
            'history-privacy-audit.yml',
            'permission-lab.yml',
            'preflight.yml',
            'release.yml',
        }
        self.assertEqual({p.name for p in WORKFLOWS.glob('*.yml')}, expected)
        field = (WORKFLOWS / 'field-pack.yml').read_text('utf-8-sig')
        self.assertIn("github.ref_name == 'main'", field)
        self.assertIn('RC11-to-RC12 migration acceptance', field)
        self.assertNotIn('RC12-to-RC12', field)
        preflight = (WORKFLOWS / 'preflight.yml').read_text('utf-8-sig')
        self.assertIn('branches: [main, work/public]', preflight)
        self.assertNotIn('work/3.0', preflight)

    def test_current_public_source_and_commit_messages_have_no_internal_provenance_markers(self):
        blocked = {
            '60965168ce762e949600281ba6d01fee136e5b6e8257b1f216f9025ed324474c',
            '7d3194f79e645c42e4396dda38be04766810ec6a00d00aced3ffc2a0a1f1a9ef',
            '57de4cf40144bdf7d00010f2f5557a7d642c2b9705309bfade167dd313e2ca93',
            '487b91042c7cf27a19e23ea8699f5f354b1a0c3af9e418138dc6150d830f970d',
            '053ea4804ef1bb33d4a3d6fb024a614b6d257cebc2bc7cd915da9c9522f37ffc',
        }
        text_suffixes = {
            '.ps1','.psm1','.psd1','.cs','.vbs','.py','.json','.yml','.yaml',
            '.md','.txt','.xml','.config','.ini','.cfg','.conf','.toml',
            '.properties','.csv',
        }
        for path in ROOT.rglob('*'):
            if not path.is_file() or '.git' in path.relative_to(ROOT).parts:
                continue
            if path.suffix.lower() not in text_suffixes and path.name not in {'.gitignore','.gitattributes'}:
                continue
            source = path.read_text('utf-8-sig').lower()
            words = re.findall(r'[a-z][a-z0-9]{2,}', source)
            self.assertFalse(
                any(hashlib.sha256(word.encode()).hexdigest() in blocked for word in words),
                path.relative_to(ROOT).as_posix(),
            )

        log = subprocess.check_output(
            ['git','log','HEAD','--format=%B%x00%an%x00%ae%x00%cn%x00%ce%x1e'],
            cwd=ROOT,
        ).decode('utf-8','replace').lower()
        words = re.findall(r'[a-z][a-z0-9]{2,}', log)
        self.assertFalse(any(hashlib.sha256(word.encode()).hexdigest() in blocked for word in words))

    def test_no_untrusted_pull_request_execution_or_repository_dispatch(self):
        automatic = []
        for path in sorted(WORKFLOWS.glob('*.yml')):
            source = path.read_text('utf-8-sig')
            workflow = yaml.safe_load(source)
            event = workflow.get('on', workflow.get(True, {}))
            if isinstance(event, str):
                event = {event: None}
            elif isinstance(event, list):
                event = {name: None for name in event}
            event = event or {}
            self.assertNotIn('pull_request_target', event, path.name)
            self.assertNotIn('pull_request', event, path.name)
            self.assertNotIn('repository_dispatch', event, path.name)
            if 'push' in event:
                automatic.append(path.name)
        self.assertEqual(automatic, ['preflight.yml'])

    def test_write_capable_jobs_remain_disabled(self):
        for path in sorted(WORKFLOWS.glob('*.yml')):
            workflow = yaml.safe_load(path.read_text('utf-8-sig'))
            workflow_permissions = workflow.get('permissions', {}) or {}
            for name, job in (workflow.get('jobs', {}) or {}).items():
                permissions = job.get('permissions', workflow_permissions) or {}
                if any(value == 'write' for value in permissions.values()):
                    condition = job.get('if')
                    self.assertTrue(condition is False or str(condition).startswith('false &&'),
                                    (path.name, name))

    def test_public_issue_forms_are_privacy_bounded(self):
        issue_dir = ROOT / '.github' / 'ISSUE_TEMPLATE'
        config = yaml.safe_load((issue_dir / 'config.yml').read_text('utf-8-sig'))
        self.assertIs(config['blank_issues_enabled'], False)
        for name in ('bug_report.yml', 'feature_request.yml'):
            form = yaml.safe_load((issue_dir / name).read_text('utf-8-sig'))
            self.assertEqual(form['name'].strip(), form['name'])
            self.assertTrue(form.get('description'))
            source = (issue_dir / name).read_text('utf-8-sig')
            for required in ('screenshots', 'raw logs', 'IP addresses', 'device names', 'account details', 'credentials'):
                self.assertIn(required, source)
            self.assertNotIn('upload your', source.lower())
            confirmations = [item for item in form.get('body', [])
                             if item.get('type') == 'checkboxes' and item.get('id') == 'privacy']
            self.assertEqual(len(confirmations), 1)
            options = confirmations[0].get('attributes', {}).get('options', [])
            self.assertTrue(options and all(option.get('required') is True for option in options))

    def test_automatic_gate_includes_current_source_and_reachable_history_privacy(self):
        source = (WORKFLOWS / 'preflight.yml').read_text('utf-8-sig')
        for required in (
            'release/check-repository.py --ci',
            'release/audit-git-history.py',
            'fetch-depth: 0',
            'fetch-tags: true',
            'test-public-source-readiness.py',
        ):
            self.assertIn(required, source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
