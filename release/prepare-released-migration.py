#!/usr/bin/env python3
"""Stage the exact installed RC11 predecessor and reviewed RC12 candidate.

Only hash-pinned Actions artifacts from this repository are read. The files are
written outside the checkout for disposable Windows migration tests; installers
are never executed by this staging script.
"""
import hashlib
import io
import json
import os
import re
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import zipfile

REPOSITORY = 'coachedai/tailscale-repair-clean'
REPOSITORY_ID = 1398720044

PREDECESSOR_ARTIFACT_ID = 11103704932
PREDECESSOR_ARTIFACT_RUN = 36728388868
PREDECESSOR_SOURCE = 'dfef25f200effea2aecf5552b1715c3590dfeca2'
PREDECESSOR_ARTIFACT_HASH = 'db57f55956018e06f4adfced007c307391989b03e2ceb0d6b564091df057a5d3'
PREDECESSOR_ARTIFACT_SIZE = 642550
PREDECESSOR_NAME = 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.11.zip'
PREDECESSOR_HASH = 'bdd905f8bd9dc771a3a8fd0ec5093157f30a7d0c2a8ac6d578b5ff6fd74626ce'
PREDECESSOR_SIZE = 205119

CANDIDATE_ARTIFACT_ID = 11107315062
CANDIDATE_ARTIFACT_RUN = 36732992428
CANDIDATE_SOURCE = '36bd301fdff27737c2a0e3ad2375ce277ffc955c'
CANDIDATE_ARTIFACT_HASH = '0528443d13d45927fc2a5fc45ee051b258ecd7127b6d0bd9358eb2ff150def97'
CANDIDATE_ARTIFACT_SIZE = 645055
CANDIDATE_NAME = 'TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe'
CANDIDATE_HASH = 'ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17'
CANDIDATE_SIZE = 291328
PAYLOAD_NAME = 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.12.zip'
PAYLOAD_HASH = 'f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6'
PAYLOAD_SIZE = 206052


class Refused(RuntimeError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused('duplicate_json_key')
        result[key] = value
    return result


def decode_json(raw):
    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_object)


def verify_bytes(data, size, expected):
    if len(data) != size or hashlib.sha256(data).hexdigest() != expected:
        raise Refused('fixture_integrity_mismatch')
    return data


def artifact_endpoint(artifact_id, archive=False):
    suffix = '/zip' if archive else ''
    return 'repos/' + REPOSITORY + '/actions/artifacts/' + str(artifact_id) + suffix


def api(path, *, binary=False, limit=2 * 1024 * 1024):
    allowed = {
        'repos/' + REPOSITORY,
        artifact_endpoint(PREDECESSOR_ARTIFACT_ID),
        artifact_endpoint(PREDECESSOR_ARTIFACT_ID, True),
        artifact_endpoint(CANDIDATE_ARTIFACT_ID),
        artifact_endpoint(CANDIDATE_ARTIFACT_ID, True),
    }
    if path not in allowed:
        raise Refused('repository_boundary')
    binary_allowed = {
        artifact_endpoint(PREDECESSOR_ARTIFACT_ID, True),
        artifact_endpoint(CANDIDATE_ARTIFACT_ID, True),
    }
    if binary and path not in binary_allowed:
        raise Refused('binary_endpoint_not_pinned')
    command = ['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path,
               '--header', 'Accept: application/vnd.github+json']
    completed = subprocess.run(command, capture_output=True, timeout=90)
    if completed.returncode != 0:
        status = re.search(rb'\(HTTP ([1-5][0-9]{2})\)', completed.stderr)
        if status:
            raise Refused('fixture_api_http_' + status.group(1).decode('ascii'))
        raise Refused('fixture_api_request_failed')
    if len(completed.stdout) > limit:
        raise Refused('fixture_api_size_limit')
    return completed.stdout if binary else decode_json(completed.stdout)


def verify_artifact_metadata(data, *, artifact_id, run_id, source, size, digest):
    run = data.get('workflow_run', {}) if isinstance(data, dict) else {}
    if (data.get('id') != artifact_id or data.get('name') != 'private-candidate-packages' or
            data.get('expired') is not False or data.get('size_in_bytes') != size or
            data.get('digest') != 'sha256:' + digest or run.get('id') != run_id or
            run.get('repository_id') != REPOSITORY_ID or run.get('head_repository_id') != REPOSITORY_ID or
            run.get('head_sha') != source or run.get('head_branch') != 'work/3.0'):
        raise Refused('candidate_artifact_metadata_mismatch')


def read_archive(data, *, artifact_size, artifact_hash, wanted):
    verify_bytes(data, artifact_size, artifact_hash)
    selected = {}
    seen = set()
    total = 0
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if len(archive.infolist()) > 32:
            raise Refused('archive_entry_limit')
        for entry in archive.infolist():
            name = entry.filename
            parts = PurePosixPath(name).parts
            if ('\\' in name or ':' in name or name.startswith('/') or '..' in parts or
                    '.' in name.split('/') or '//' in name or name.lower() in seen or
                    entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1):
                raise Refused('unsafe_archive_entry')
            seen.add(name.lower())
            total += entry.file_size
            if entry.file_size > 2 * 1024 * 1024 or total > 8 * 1024 * 1024:
                raise Refused('archive_size_limit')
            if name in wanted:
                selected[name] = archive.read(entry)
    if set(selected) != set(wanted):
        raise Refused('candidate_files_missing')
    for name, spec in wanted.items():
        verify_bytes(selected[name], spec[0], spec[1])
    return selected


def write_new(path, data):
    with path.open('xb') as stream:
        stream.write(data)


def main():
    required = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': REPOSITORY,
                'GITHUB_REPOSITORY_ID': str(REPOSITORY_ID),
                'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'Windows'}
    if any(os.environ.get(k) != v for k, v in required.items()) or os.environ.get('GITHUB_REF_NAME') not in {'main','work/public'}:
        raise Refused('disposable_repository_environment_required')
    base = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    root = base / 'tqr-released-migration-inputs'
    root.mkdir(exist_ok=False)
    receipt = {
        'schema': 2, 'passed': False, 'testSource': os.environ['GITHUB_SHA'],
        'predecessorSource': PREDECESSOR_SOURCE, 'candidateSource': CANDIDATE_SOURCE,
        'predecessorSha256': PREDECESSOR_HASH, 'candidateSha256': CANDIDATE_HASH,
        'payloadSha256': PAYLOAD_HASH, 'predecessorArtifactId': PREDECESSOR_ARTIFACT_ID,
        'candidateArtifactId': CANDIDATE_ARTIFACT_ID, 'windowsMigrationExecuted': False,
        'publicFeedVerified': False,
    }
    try:
        repo = api('repos/' + REPOSITORY)
        if (repo.get('id') != REPOSITORY_ID or repo.get('full_name') != REPOSITORY or
                repo.get('private') is not False or repo.get('fork') is not False):
            raise Refused('public_repository_identity_mismatch')

        receipt['stage'] = 'predecessor_metadata'
        verify_artifact_metadata(
            api(artifact_endpoint(PREDECESSOR_ARTIFACT_ID)), artifact_id=PREDECESSOR_ARTIFACT_ID,
            run_id=PREDECESSOR_ARTIFACT_RUN, source=PREDECESSOR_SOURCE,
            size=PREDECESSOR_ARTIFACT_SIZE, digest=PREDECESSOR_ARTIFACT_HASH)
        receipt['stage'] = 'predecessor_bytes'
        predecessor_archive = api(artifact_endpoint(PREDECESSOR_ARTIFACT_ID, True), binary=True)
        predecessor = read_archive(
            predecessor_archive, artifact_size=PREDECESSOR_ARTIFACT_SIZE,
            artifact_hash=PREDECESSOR_ARTIFACT_HASH,
            wanted={PREDECESSOR_NAME: (PREDECESSOR_SIZE, PREDECESSOR_HASH)})

        receipt['stage'] = 'candidate_metadata'
        verify_artifact_metadata(
            api(artifact_endpoint(CANDIDATE_ARTIFACT_ID)), artifact_id=CANDIDATE_ARTIFACT_ID,
            run_id=CANDIDATE_ARTIFACT_RUN, source=CANDIDATE_SOURCE,
            size=CANDIDATE_ARTIFACT_SIZE, digest=CANDIDATE_ARTIFACT_HASH)
        receipt['stage'] = 'candidate_bytes'
        candidate_archive = api(artifact_endpoint(CANDIDATE_ARTIFACT_ID, True), binary=True)
        candidate = read_archive(
            candidate_archive, artifact_size=CANDIDATE_ARTIFACT_SIZE,
            artifact_hash=CANDIDATE_ARTIFACT_HASH,
            wanted={CANDIDATE_NAME: (CANDIDATE_SIZE, CANDIDATE_HASH),
                    PAYLOAD_NAME: (PAYLOAD_SIZE, PAYLOAD_HASH)})

        receipt['stage'] = 'write_verified_inputs'
        for name, data in {**predecessor, **candidate}.items():
            write_new(root / name, data)
        receipt['stage'] = 'complete'
        receipt['passed'] = True
    except Refused as error:
        receipt['reason'] = str(error)
        print('Migration input stage: ' + receipt.get('stage', 'repository_identity'), file=sys.stderr)
        raise
    finally:
        write_new(root / 'input-receipt.json', (json.dumps(receipt, indent=2) + '\n').encode())
    print('Exact RC11 predecessor and RC12 candidate fixtures staged. Native migration acceptance is separate.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        reason = str(error) if isinstance(error, Refused) else type(error).__name__
        print('Migration inputs blocked: ' + reason + '. No matched file content is logged.', file=sys.stderr)
        sys.exit(1)