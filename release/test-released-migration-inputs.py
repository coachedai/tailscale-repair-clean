#!/usr/bin/env python3
"""Synthetic-only tests for exact RC11-to-RC12 migration input staging."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('migration_inputs', ROOT / 'prepare-released-migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def metadata(artifact_id, run_id, source, size, digest):
    return {
        'id': artifact_id, 'name': 'private-candidate-packages', 'expired': False,
        'size_in_bytes': size, 'digest': 'sha256:' + digest,
        'workflow_run': {'id': run_id, 'repository_id': m.REPOSITORY_ID,
                         'head_repository_id': m.REPOSITORY_ID,
                         'head_branch': 'work/3.0', 'head_sha': source},
    }


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as z:
        for name, data in entries.items():
            z.writestr(name, data)
    return output.getvalue()


class MigrationInputTests(unittest.TestCase):
    def test_exact_predecessor_and_candidate_identities_are_fixed(self):
        self.assertEqual(m.PREDECESSOR_ARTIFACT_ID, 11103704932)
        self.assertEqual(m.PREDECESSOR_SOURCE, 'dfef25f200effea2aecf5552b1715c3590dfeca2')
        self.assertEqual(m.PREDECESSOR_NAME, 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.11.zip')
        self.assertEqual(m.PREDECESSOR_HASH, 'bdd905f8bd9dc771a3a8fd0ec5093157f30a7d0c2a8ac6d578b5ff6fd74626ce')
        self.assertEqual(m.CANDIDATE_ARTIFACT_ID, 11107315062)
        self.assertEqual(m.CANDIDATE_SOURCE, '36bd301fdff27737c2a0e3ad2375ce277ffc955c')
        self.assertEqual(m.CANDIDATE_NAME, 'TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe')
        self.assertEqual(m.CANDIDATE_HASH, 'ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17')
        self.assertEqual(m.PAYLOAD_HASH, 'f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6')

    def test_both_artifact_metadata_records_are_exact(self):
        for args in [
            (m.PREDECESSOR_ARTIFACT_ID, m.PREDECESSOR_ARTIFACT_RUN, m.PREDECESSOR_SOURCE,
             m.PREDECESSOR_ARTIFACT_SIZE, m.PREDECESSOR_ARTIFACT_HASH),
            (m.CANDIDATE_ARTIFACT_ID, m.CANDIDATE_ARTIFACT_RUN, m.CANDIDATE_SOURCE,
             m.CANDIDATE_ARTIFACT_SIZE, m.CANDIDATE_ARTIFACT_HASH),
        ]:
            data = metadata(*args)
            m.verify_artifact_metadata(data, artifact_id=args[0], run_id=args[1], source=args[2], size=args[3], digest=args[4])

    def test_different_artifact_source_repository_or_digest_is_refused(self):
        args = (m.CANDIDATE_ARTIFACT_ID, m.CANDIDATE_ARTIFACT_RUN, m.CANDIDATE_SOURCE,
                m.CANDIDATE_ARTIFACT_SIZE, m.CANDIDATE_ARTIFACT_HASH)
        for field, value in [('id', 1), ('digest', 'sha256:' + '0'*64), ('expired', True)]:
            data = metadata(*args); data[field] = value
            with self.assertRaises(m.Refused):
                m.verify_artifact_metadata(data, artifact_id=args[0], run_id=args[1], source=args[2], size=args[3], digest=args[4])
        for field, value in [('head_sha', '0'*40), ('repository_id', 1), ('head_repository_id', 1), ('head_branch', 'main')]:
            data = metadata(*args); data['workflow_run'][field] = value
            with self.assertRaises(m.Refused):
                m.verify_artifact_metadata(data, artifact_id=args[0], run_id=args[1], source=args[2], size=args[3], digest=args[4])

    def test_exact_files_are_extracted_from_a_safe_archive(self):
        predecessor = b'rc11-package-fixture'
        data = archive({m.PREDECESSOR_NAME: predecessor})
        with patch.object(m, 'PREDECESSOR_ARTIFACT_SIZE', len(data)), patch.object(m, 'PREDECESSOR_ARTIFACT_HASH', hashlib.sha256(data).hexdigest()), patch.object(m, 'PREDECESSOR_SIZE', len(predecessor)), patch.object(m, 'PREDECESSOR_HASH', hashlib.sha256(predecessor).hexdigest()):
            selected = m.read_archive(data, artifact_size=m.PREDECESSOR_ARTIFACT_SIZE, artifact_hash=m.PREDECESSOR_ARTIFACT_HASH, wanted={m.PREDECESSOR_NAME:(m.PREDECESSOR_SIZE,m.PREDECESSOR_HASH)})
            self.assertEqual(selected[m.PREDECESSOR_NAME], predecessor)

    def test_missing_or_modified_selected_file_is_refused(self):
        wanted = {'fixture.bin': (4, hashlib.sha256(b'good').hexdigest())}
        for entries in ({'other.bin': b'good'}, {'fixture.bin': b'evil'}):
            data = archive(entries)
            with self.assertRaises(m.Refused):
                m.read_archive(data, artifact_size=len(data), artifact_hash=hashlib.sha256(data).hexdigest(), wanted=wanted)

    def test_unsafe_archives_are_refused(self):
        for name in ['../outside', '/absolute', 'directory/../outside', 'directory\\outside', 'drive:stream']:
            data = archive({name: b'synthetic fixture'})
            with self.assertRaisesRegex(m.Refused, 'unsafe_archive_entry'):
                m.read_archive(data, artifact_size=len(data), artifact_hash=hashlib.sha256(data).hexdigest(), wanted={name:(len(b'synthetic fixture'),hashlib.sha256(b'synthetic fixture').hexdigest())})

    def test_remote_boundary_precedes_network(self):
        with patch.object(m.subprocess, 'run') as run:
            with self.assertRaisesRegex(m.Refused, 'repository_boundary'):
                m.api('repos/example/unrelated/actions/artifacts/1')
            run.assert_not_called()

    def test_binary_downloads_are_limited_to_two_pinned_artifacts(self):
        for artifact_id in (m.PREDECESSOR_ARTIFACT_ID, m.CANDIDATE_ARTIFACT_ID):
            endpoint = m.artifact_endpoint(artifact_id, True)
            with patch.object(m.subprocess, 'run') as run:
                run.return_value.returncode = 0; run.return_value.stdout = b'PK\x03\x04fixture'
                self.assertEqual(m.api(endpoint, binary=True), b'PK\x03\x04fixture')
                command = run.call_args.args[0]
                self.assertEqual(command[command.index('--method') + 1], 'GET')
                self.assertIn('Accept: application/vnd.github+json', command)
        with patch.object(m.subprocess, 'run') as run:
            with self.assertRaises(m.Refused): m.api(m.artifact_endpoint(1, True), binary=True)
            run.assert_not_called()

    def test_failed_api_request_does_not_echo_untrusted_content(self):
        with patch.object(m.subprocess, 'run') as run:
            run.return_value.returncode = 1; run.return_value.stderr = b'untrusted details (HTTP 403)'
            with self.assertRaisesRegex(m.Refused, '^fixture_api_http_403$'):
                m.api(m.artifact_endpoint(m.CANDIDATE_ARTIFACT_ID))

    def test_existing_fixture_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fixture.dat'
            m.write_new(path, b'first')
            with self.assertRaises(FileExistsError): m.write_new(path, b'second')
            self.assertEqual(path.read_bytes(), b'first')

    def test_native_migration_script_has_no_network_or_candidate_entry_call(self):
        source = (ROOT / 'test-released-setup-migration.ps1').read_text()
        for forbidden in ['Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process $CandidateInstaller']:
            self.assertNotIn(forbidden, source)
        for required in ['ApplyFilesCore', 'Assert-InstalledFiles $oldFiles', 'PendingRestartVersionCode', '3.0.0-rc.11', '3.0.0-rc.12']:
            self.assertIn(required, source)

    def test_staging_script_does_not_execute_distribution_files(self):
        source = (ROOT / 'prepare-released-migration.py').read_text()
        self.assertNotIn('Start-Process', source)
        self.assertNotIn('subprocess.Popen', source)
        self.assertNotIn('shell=True', source)
        self.assertIn("'--method', 'GET'", source)


if __name__ == '__main__':
    unittest.main(verbosity=2)