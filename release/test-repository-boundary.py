#!/usr/bin/env python3
"""Synthetic/offline tests for the fresh repository boundary. No remote writes."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('boundary', ROOT / 'release/check-repository.py')
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)

class BoundaryTests(unittest.TestCase):
    def policy(self):
        p = json.loads((ROOT / 'repository-policy.json').read_text())
        p['repositoryId'] = 123456
        return p

    def test_public_data_policy_is_fail_closed(self):
        p=self.policy()
        self.assertFalse(any(p['publicDataPolicy'].values()))
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);bad=dict(p);bad['publicDataPolicy']=dict(p['publicDataPolicy']);bad['publicDataPolicy']['allowPersonalData']=True
            (root/'repository-policy.json').write_text(json.dumps(bad))
            with self.assertRaises(boundary.Refusal):boundary.load_policy(root)

    def test_internal_artifact_paths_are_blocked(self):
        with tempfile.TemporaryDirectory() as t:
            blocked=''.join(chr(x) for x in (112,114,111,109,112,116,115))
            root=Path(t);(root/blocked).mkdir();(root/blocked/'fixture.md').write_text('synthetic')
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_machine_identifiers_are_blocked(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'fixture.md').write_text('mac '+'00'+':11:22:33:44:55')
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'fixture.md').write_text('sid '+'S-1-5-21-'+'123-456-789')
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_only_exact_remotes(self):
        for remote in boundary.REMOTES: boundary.check_remote(remote)
        for remote in ('https://github.com/coachedai/unrelated-project.git',
                       boundary.HTTPS + '/extra', boundary.HTTPS + '?redirect=other',
                       boundary.HTTPS.replace('https:', 'http:'),
                       boundary.HTTPS.replace('github.com', 'github.com.example.invalid')):
            with self.assertRaises(boundary.Refusal): boundary.check_remote(remote)

    def test_unbound_policy_is_not_repository_acceptance(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);p=self.policy();p['repositoryId']=None
            (root/'repository-policy.json').write_text(json.dumps(p))
            with self.assertRaises(boundary.Refusal):boundary.load_policy(root)
            self.assertIsNone(boundary.load_policy(root,unbound=True)['repositoryId'])

    def test_wrong_policy_cannot_be_unbound(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);p=self.policy();p['repository']='coachedai/unrelated-project'
            (root/'repository-policy.json').write_text(json.dumps(p))
            with self.assertRaises(boundary.Refusal):boundary.load_policy(root,unbound=True)

    def test_ci_id_must_match(self):
        with patch.dict(os.environ,{'GITHUB_REPOSITORY_ID':'987654'}):
            with self.assertRaises(boundary.Refusal):boundary.verify_online(self.policy(),ci=True)
        with patch.dict(os.environ,{'GITHUB_REPOSITORY_ID':'123456'}):
            boundary.verify_online(self.policy(),ci=True)

    def test_private_config_blocked(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'config.json').write_text('{}')
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_previous_repository_reference_blocked(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'fixture.md').write_text('https://github.com/coachedai/'+boundary.OBSOLETE_NAME)
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_opaque_file_blocked(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'fixture.png').write_bytes(b'not an image')
            with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'safe.md').write_text('Synthetic text')
            link=root/'link.md'
            if os.name == 'nt':
                # Unit-test the refusal path without asking a Windows user for
                # elevation to create a filesystem link. Not native acceptance.
                link.write_text('Synthetic link fixture')
                actual=Path.is_symlink
                with patch.object(Path,'is_symlink',lambda path: path==link or actual(path)):
                    with self.assertRaises(boundary.Refusal):boundary.scan_source(root)
            else:
                link.symlink_to(root/'safe.md')
                with self.assertRaises(boundary.Refusal):boundary.scan_source(root)

    def test_plain_source_passes(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);(root/'README.md').write_text('Synthetic project source')
            self.assertEqual(boundary.scan_source(root),1)

    def test_migration_feeds_have_no_fake_assets(self):
        for f in ('latest.json','preview.json'):
            m=json.loads((ROOT/'updates'/f).read_text())
            self.assertIs(m['published'],False)
            self.assertNotIn('package',m)
            self.assertEqual(m['versionCode'],30001003)

    def test_only_one_automatic_workflow(self):
        automatic=[]
        for f in (ROOT/'.github/workflows').glob('*.yml'):
            data=yaml.safe_load(f.read_text())
            event=data.get('on',data.get(True,{}))
            if 'push' in event:automatic.append(f.name)
        self.assertEqual(automatic,['preflight.yml'])

    def test_remote_write_jobs_cannot_run(self):
        for f in (ROOT/'.github/workflows').glob('*.yml'):
            data=yaml.safe_load(f.read_text())
            for name,job in data['jobs'].items():
                perms=job.get('permissions',data.get('permissions',{}))
                if f.name == 'preflight.yml' and name == 'migration-inputs':
                    self.assert_migration_input_job(job)
                    continue
                if 'write' in perms.values() or name in ('publish','preview-publish','scrub'):
                    condition=job.get('if')
                    self.assertTrue(condition is False or str(condition).startswith('false &&'),(f.name,name))

    def test_new_preflight_runs_both_existing_suites(self):
        text=(ROOT/'.github/workflows/preflight.yml').read_text()
        for s in ('test-development-guardrails.py','test-git-history-audit.py','test-repository-boundary.py','audit-git-history.py'):
            self.assertIn(s,text)
        workflow=yaml.safe_load(text)
        self.assertEqual(workflow['permissions'],{'contents':'read'})
        self.assert_migration_input_job(workflow['jobs']['migration-inputs'])
        self.assertNotIn('actions: write',text)
        self.assertIn('check-repository.py --ci',text)

    def test_every_workflow_job_with_checkout_has_identity_check(self):
        for f in (ROOT/'.github/workflows').glob('*.yml'):
            for name,job in yaml.safe_load(f.read_text())['jobs'].items():
                steps=job.get('steps',[])
                if any(str(x.get('uses','')).startswith('actions/checkout@') for x in steps):
                    self.assertTrue(any('check-repository.py --ci' in x.get('run','') for x in steps),(f.name,name))


    def assert_migration_input_job(self, job):
        self.assertEqual(job['permissions'], {'contents':'read','actions':'read'})
        self.assertEqual(job['needs'], 'preflight')
        self.assertEqual(job['runs-on'], 'windows-latest')
        self.assertEqual(job['timeout-minutes'], 5)
        self.assertEqual(job['if'], "false && github.repository == 'coachedai/tailscale-repair-clean' && github.repository_id == '1398720044' && (github.ref_name == 'main' || github.ref_name == 'work/public')")
        self.assertNotIn('env', job)
        steps=job['steps']
        self.assertEqual(len(steps),4)
        self.assertEqual(steps[0]['uses'],'actions/checkout@11d5960a326750d5838078e36cf38b85af677262')
        self.assertEqual(steps[0]['with'],{'ref':'${{ github.sha }}','persist-credentials':False,'submodules':False})
        self.assertEqual(steps[1]['run'],'python -B release/check-repository.py --ci')
        self.assertNotIn('env',steps[1])
        self.assertEqual(steps[2]['env'],{'GH_TOKEN':'${{ github.token }}'})
        expected = """$expected='1bffdac4e147bb97f79807235a260cc154f4bfebedac5d94ae65944c9065cc2b'
$actual=(Get-FileHash -LiteralPath 'release/prepare-released-migration.py' -Algorithm SHA256).Hash.ToLowerInvariant()
if($actual -cne $expected){throw 'The reviewed GET-only staging script changed.'}
python -B release/prepare-released-migration.py
if($LASTEXITCODE -ne 0){throw 'Verified migration inputs are unavailable.'}
"""
        self.assertEqual(steps[2]['run'],expected)
        self.assertEqual(hashlib.sha256((ROOT/'release/prepare-released-migration.py').read_bytes()).hexdigest(),'1bffdac4e147bb97f79807235a260cc154f4bfebedac5d94ae65944c9065cc2b')
        self.assertEqual(steps[3]['uses'],'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')
        self.assertEqual(steps[3]['with']['name'],'released-migration-inputs')
        self.assertEqual(steps[3]['with']['if-no-files-found'],'error')
        self.assertEqual(steps[3]['with']['retention-days'],30)
        self.assertNotIn('if',steps[3])
        names=('TailscaleQuickRepair-SetupPackage-3.0.0-rc.11.zip',
               'TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe',
               'TailscaleQuickRepair-SetupPackage-3.0.0-rc.12.zip','input-receipt.json')
        self.assertEqual(steps[3]['with']['path'].splitlines(),['${{ runner.temp }}/tqr-released-migration-inputs/'+name for name in names])

    def test_migration_input_job_is_narrowly_bound(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/preflight.yml').read_text())
        self.assert_migration_input_job(workflow['jobs']['migration-inputs'])

    def test_migration_installer_has_no_write_capable_token(self):
        job=yaml.safe_load((ROOT/'.github/workflows/preflight.yml').read_text())['jobs']['released-migration']
        self.assertEqual(job['permissions'],{'contents':'read','actions':'read'})
        self.assertEqual(set(job['needs']),{'preflight','migration-inputs'})
        self.assertNotIn('env',job)
        for step in job['steps']:
            self.assertNotIn('GH_TOKEN',step.get('env',{}))
            self.assertNotIn('GITHUB_TOKEN',step.get('env',{}))
        downloads=[step for step in job['steps'] if str(step.get('uses','')).startswith('actions/download-artifact@')]
        self.assertEqual(len(downloads),1)
        self.assertEqual(downloads[0]['with'],{'name':'released-migration-inputs','path':'${{ runner.temp }}/tqr-released-migration-inputs'})

    def test_migration_input_job_rejects_extra_steps_or_permissions(self):
        import copy
        job=yaml.safe_load((ROOT/'.github/workflows/preflight.yml').read_text())['jobs']['migration-inputs']
        for change in ('permission','step','command','scope'):
            altered=copy.deepcopy(job)
            if change=='permission': altered['permissions']['issues']='write'
            if change=='step': altered['steps'].append({'run':'unexpected'})
            if change=='command': altered['steps'][2]['run']+='unexpected\n'
            if change=='scope': altered['if']='true'
            with self.assertRaises(AssertionError): self.assert_migration_input_job(altered)

    def test_http_status_diagnostics_exclude_response_content(self):
        spec=importlib.util.spec_from_file_location('staging_diagnostics',ROOT/'release/prepare-released-migration.py')
        staging=importlib.util.module_from_spec(spec);spec.loader.exec_module(staging)
        for status in (401,403,404,429,502):
            with patch.object(staging.subprocess,'run') as request:
                request.return_value.returncode=1
                request.return_value.stderr=('Untrusted fixture details (HTTP '+str(status)+')').encode()
                with self.assertRaisesRegex(staging.Refused,'^fixture_api_http_'+str(status)+'$'):
                    staging.api(staging.artifact_endpoint(staging.CANDIDATE_ARTIFACT_ID))

    def test_download_headers_match_the_pinned_endpoint(self):
        spec=importlib.util.spec_from_file_location('staging_headers',ROOT/'release/prepare-released-migration.py')
        staging=importlib.util.module_from_spec(spec);spec.loader.exec_module(staging)
        cases=[
            (staging.artifact_endpoint(staging.PREDECESSOR_ARTIFACT_ID,True), 'application/vnd.github+json'),
            (staging.artifact_endpoint(staging.CANDIDATE_ARTIFACT_ID,True), 'application/vnd.github+json'),
        ]
        for endpoint,accept in cases:
            with patch.object(staging.subprocess,'run') as request:
                request.return_value.returncode=0
                request.return_value.stdout=b'PK\x03\x04synthetic archive'
                result=staging.api(endpoint,binary=True)
                self.assertEqual(result,b'PK\x03\x04synthetic archive')
                self.assertIn('Accept: '+accept,request.call_args.args[0])
                self.assertEqual(request.call_args.args[0][5],'GET')
        with patch.object(staging.subprocess,'run') as request:
            with self.assertRaisesRegex(staging.Refused,'repository_boundary'):
                staging.api(staging.artifact_endpoint(1,True),binary=True)
            request.assert_not_called()

if __name__=='__main__':unittest.main(verbosity=2)