#!/usr/bin/env python3
"""Verify and stage a fixed clean-repository baseline; never execute it."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import threading
import zipfile

REPOSITORY = 'coachedai/tailscale-repair-clean'
REPOSITORY_ID = 1398720044
MAX_ARCHIVE = 2 * 1024 * 1024
MAX_EXPANDED = 16 * 1024 * 1024
REPORTS = ('native-windows-results.json', 'native-permission-results.json',
           'protected-migration-results.json', 'standalone-setup-results.json',
           'local-control-center-results.json', 'vpn-awareness-results.json')


class Refused(RuntimeError):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def decode(raw):
    try:
        return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused('json_constant')))
    except (ValueError, UnicodeError):
        raise Refused('invalid_json') from None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def integer(value, maximum):
    return type(value) is int and 0 < value <= maximum


def sha(value, length=64):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{%d}' % length, value) is not None


def asset_names(pins):
    version = pins['version']
    return ('TailscaleQuickRepair-' + version + '.zip',
            'TailscaleQuickRepair-SetupPackage-' + version + '.zip',
            'TailscaleQuickRepair-Standalone-' + version + '.exe')


def validate_pins(pins):
    keys = {'schema', 'repository', 'repositoryId', 'source', 'tree', 'runId',
            'version', 'versionCode', 'artifacts', 'files'}
    require(isinstance(pins, dict) and set(pins) == keys, 'baseline_schema')
    require(type(pins['schema']) is int and pins['schema'] == 1, 'baseline_schema')
    require(pins['repository'] == REPOSITORY and type(pins['repositoryId']) is int
            and pins['repositoryId'] == REPOSITORY_ID, 'repository_boundary')
    require(sha(pins['source'], 40) and sha(pins['tree'], 40)
            and integer(pins['runId'], 2**63 - 1), 'baseline_identity')
    require(isinstance(pins['version'], str) and re.fullmatch(r'3\.0\.0-rc\.[1-9][0-9]*', pins['version'])
            and integer(pins['versionCode'], 2**63 - 1), 'baseline_version')
    require(isinstance(pins['artifacts'], dict) and set(pins['artifacts']) == {'packages', 'evidence'}, 'baseline_artifacts')
    for key, name in [('packages', 'candidate-validation-packages'), ('evidence', 'startup-tests')]:
        item = pins['artifacts'][key]
        require(isinstance(item, dict) and set(item) == {'id', 'name', 'size', 'sha256'}
                and integer(item['id'], 2**63 - 1) and item['name'] == name
                and integer(item['size'], MAX_ARCHIVE) and sha(item['sha256']), 'artifact_pin')
    require(pins['artifacts']['packages']['id'] != pins['artifacts']['evidence']['id'], 'artifact_pin')
    require(isinstance(pins['files'], dict) and set(pins['files']) == set(asset_names(pins)), 'asset_allowlist')
    for item in pins['files'].values():
        require(isinstance(item, dict) and set(item) == {'size', 'sha256'}
                and integer(item['size'], MAX_ARCHIVE) and sha(item['sha256']), 'asset_pin')
    return pins


def verify_bytes(data, pin):
    require(len(data) == pin['size'] and digest(data) == pin['sha256'], 'integrity_mismatch')
    return data


def canonical(name, windows=False):
    require(isinstance(name, str) and name and '\x00' not in name, 'archive_path')
    if windows:
        name = name.replace('\\', '/')
    require('\\' not in name and not any(ord(c) < 32 or ord(c) > 126 for c in name)
            and not any(c in name for c in ':<>"|?*'), 'archive_path')
    parts = name.split('/')
    require(all(p not in ('', '.', '..') and not p.endswith((' ', '.')) for p in parts), 'archive_path')
    reserved = {'con', 'prn', 'aux', 'nul'} | {'com' + str(i) for i in range(1, 10)} | {'lpt' + str(i) for i in range(1, 10)}
    require(not any(p.split('.')[0].casefold() in reserved for p in parts), 'archive_path')
    require(str(PurePosixPath(name)) == name and not name.startswith('/'), 'archive_path')
    return name


def archive(data, windows=False):
    require(len(data) <= MAX_ARCHIVE, 'archive_size')
    result = {}
    seen = set()
    total = 0
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as handle:
            entries = handle.infolist()
            require(0 < len(entries) <= 100, 'archive_count')
            for entry in entries:
                # Validate the stored name before accepting zipfile's host-specific
                # separator normalization. NUL truncation and path aliases still fail.
                name = canonical(entry.orig_filename, windows)
                require(canonical(entry.filename, windows) == name, 'archive_path')
                mode = stat.S_IFMT(entry.external_attr >> 16)
                require(mode in (0, stat.S_IFREG) and not entry.is_dir(), 'archive_file_type')
                require(not (entry.flag_bits & 1) and entry.compress_type in
                        (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'archive_encoding')
                require(name.casefold() not in seen, 'archive_duplicate')
                seen.add(name.casefold())
                total += entry.file_size
                require(0 <= entry.file_size <= 4 * 1024 * 1024 and total <= MAX_EXPANDED, 'archive_expansion')
                with handle.open(entry) as stream:
                    content = stream.read(entry.file_size + 1)
                require(len(content) == entry.file_size, 'archive_length')
                result[name] = content
    except (zipfile.BadZipFile, NotImplementedError, RuntimeError, ValueError, OSError) as error:
        if isinstance(error, Refused):
            raise
        raise Refused('invalid_archive') from None
    return result


def verify_run(run, pins):
    require(isinstance(run, dict), 'baseline_run')
    for key in ('repository', 'head_repository'):
        repo = run.get(key, {})
        require(isinstance(repo, dict) and repo.get('id') == REPOSITORY_ID
                and repo.get('full_name') == REPOSITORY, 'run_repository')
    require(run.get('id') == pins['runId'] and run.get('head_sha') == pins['source']
            and run.get('head_branch') == 'main' and run.get('event') == 'push'
            and run.get('path') == '.github/workflows/preflight.yml'
            and run.get('status') == 'completed' and run.get('conclusion') == 'success'
            and type(run.get('run_attempt')) is int and run['run_attempt'] == 1
            and run.get('head_commit', {}).get('tree_id') == pins['tree'], 'baseline_run')


def verify_artifact(meta, pin, pins):
    require(isinstance(meta, dict), 'artifact_metadata')
    run = meta.get('workflow_run', {})
    require(isinstance(run, dict) and run.get('id') == pins['runId']
            and run.get('repository_id') == REPOSITORY_ID and run.get('head_repository_id') == REPOSITORY_ID
            and run.get('head_sha') == pins['source'] and run.get('head_branch') == 'main'
            and meta.get('id') == pin['id'] and meta.get('name') == pin['name']
            and meta.get('expired') is False and meta.get('size_in_bytes') == pin['size']
            and meta.get('digest') == 'sha256:' + pin['sha256'], 'artifact_metadata')


def verify_package(data, pins, setup):
    files = archive(data, windows=True)
    expected = {'app/Advanced-Diagnostics.ps1', 'app/integrity-manifest.json',
                'app/Tailscale-Repair-UI.ps1', 'app/TailscaleQuickRepair.Operations.dll',
                'app/TailscaleQuickRepairSetup.exe', 'app/TailscaleQuickRepairUpdater.exe', 'version.json'}
    expected |= ({'app/TailscaleQuickRepair.exe', 'program/Auto-Repair-Monitor.ps1',
                  'program/Repair-Backend.ps1', 'program/TailscaleQuickRepair.Operations.dll'}
                 if setup else {'app/protected-update.json'})
    require(set(files) == expected | {'package-manifest.json'}, 'package_allowlist')
    version = decode(files['version.json'])
    require(version.get('product') == 'Tailscale Quick Repair' and version.get('version') == pins['version']
            and type(version.get('versionCode')) is int and version['versionCode'] == pins['versionCode']
            and version.get('channel') == 'preview', 'package_version')
    for name, targets, prefix, profile in [
            ('package-manifest.json', expected, '', None),
            ('app/integrity-manifest.json', {n for n in expected if n.startswith('app/')
                and n not in ('app/integrity-manifest.json', 'app/protected-update.json')}, 'app/', 'setup' if setup else 'update')]:
        manifest = decode(files[name])
        require(type(manifest.get('schema')) is int and manifest['schema'] == 1 and manifest.get('product') == 'Tailscale Quick Repair'
                and manifest.get('version') == pins['version'] and type(manifest.get('versionCode')) is int and manifest['versionCode'] == pins['versionCode'], 'manifest_identity')
        if profile:
            require(manifest.get('profile') == profile and manifest.get('algorithm') == 'SHA256', 'manifest_profile')
        records = manifest.get('files')
        require(isinstance(records, list) and len(records) == len(targets), 'manifest_files')
        listed = set()
        for item in records:
            require(isinstance(item, dict) and set(item) == {'path', 'size', 'sha256'}, 'manifest_record')
            path = canonical(prefix + item['path'])
            require(path in targets and path not in listed and type(item['size']) is int
                    and item['size'] >= 0 and sha(item['sha256']), 'manifest_record')
            listed.add(path)
            verify_bytes(files[path], item)
        require(listed == targets, 'manifest_files')
    if setup:
        require(files['app/TailscaleQuickRepair.Operations.dll'] == files['program/TailscaleQuickRepair.Operations.dll'], 'protected_library_mismatch')
    return files['app/Tailscale-Repair-UI.ps1']


def passed_report(data, source):
    require(isinstance(data, dict) and data.get('source') == source and data.get('passed') is True, 'evidence_result')
    cases = data.get('cases')
    require(isinstance(cases, list) and cases and all(isinstance(c, dict) and c.get('passed') is True for c in cases), 'evidence_cases')
    return len(cases)


def verify_payloads(packages, evidence, pins):
    package_files = archive(verify_bytes(packages, pins['artifacts']['packages']))
    evidence_files = archive(verify_bytes(evidence, pins['artifacts']['evidence']))
    names = asset_names(pins)
    other_assets = ('TailscaleQuickRepair-Bootstrap-' + pins['version'] + '.exe',
                    'TailscaleQuickRepair-Setup-' + pins['version'] + '.exe')
    assets = names + other_assets
    require(set(package_files) == {'build-validation.json'} | set(assets) |
            {n + '.sha256' for n in assets}, 'distribution_allowlist')
    for name in assets:
        try:
            checksum = package_files[name + '.sha256'].decode('ascii').strip()
        except UnicodeError:
            raise Refused('checksum_encoding') from None
        require(sha(checksum) and checksum == digest(package_files[name]), 'checksum_mismatch')
    for name in names:
        verify_bytes(package_files[name], pins['files'][name])
    update_ui = verify_package(package_files[names[0]], pins, False)
    setup_ui = verify_package(package_files[names[1]], pins, True)
    require(update_ui == setup_ui, 'package_ui_mismatch')
    require(package_files[names[2]].startswith(b'MZ') and
            package_files[names[2]].count(package_files[names[1]]) == 1, 'embedded_payload_mismatch')
    counts = {}
    for name in REPORTS:
        key = 'tqr-startup-evidence/' + name
        require(key in evidence_files, 'evidence_missing')
        counts[name] = passed_report(decode(evidence_files[key]), pins['source'])
    key = 'tqr-startup-evidence/native-recurrence-trace.json'
    require(key in evidence_files, 'evidence_missing')
    trace = decode(evidence_files[key])
    require(trace.get('source') == pins['source'] and trace.get('channelRestored') is True
            and type(trace.get('eventReadError')) is int and trace['eventReadError'] == 0, 'recurrence_evidence')
    key = 'tqr-startup-dist/build-validation.json'
    require(key in evidence_files and evidence_files[key] == package_files['build-validation.json'], 'build_receipt_mismatch')
    build = decode(package_files['build-validation.json'])
    passed_report(build, pins['source'])
    require(build.get('profile') == 'Development' and build.get('publishable') is False
            and build.get('publicFeedVerified') is False, 'publication_boundary')
    return {name: package_files[name] for name in names}, counts


def endpoints(pins):
    root = 'repos/' + REPOSITORY
    result = {root, root + '/actions/runs/' + str(pins['runId'])}
    for pin in pins['artifacts'].values():
        result.add(root + '/actions/artifacts/' + str(pin['id']))
        result.add(root + '/actions/artifacts/' + str(pin['id']) + '/zip')
    return result


def api(path, pins, binary=False):
    require(path in endpoints(pins) and binary == path.endswith('/zip'), 'api_boundary')
    command = ['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path,
               '--header', 'Accept: application/vnd.github+json']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    chunks = []
    overflow = threading.Event()
    def collect():
        size = 0
        try:
            while True:
                block = process.stdout.read(65536)
                if not block:
                    break
                size += len(block)
                if size > MAX_ARCHIVE:
                    overflow.set()
                    process.kill()
                    break
                chunks.append(block)
        except OSError:
            overflow.set()
    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    try:
        process.wait(timeout=60)
        worker.join(timeout=5)
        require(not worker.is_alive() and not overflow.is_set(), 'api_size_limit')
        require(process.returncode == 0, 'api_request_failed')
        data = b''.join(chunks)
        return data if binary else decode(data)
    except subprocess.TimeoutExpired:
        raise Refused('api_timeout') from None
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        worker.join(timeout=5)
        process.stdout.close()


def no_links(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            info = part.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not
                    (getattr(info, 'st_file_attributes', 0) & 1024), 'redirected_output')
    return path


def stage(root, pins, files, counts, source):
    require(sha(source, 40), 'source_identity')
    root = no_links(root)
    require(root.is_dir(), 'output_root')
    destination = root / 'tqr-clean-baseline'
    require(not destination.exists() and not destination.is_symlink(), 'existing_output')
    require(set(files) == set(asset_names(pins)), 'asset_allowlist')
    require(set(counts) == set(REPORTS) and all(integer(n, 10000) for n in counts.values()), 'evidence_counts')
    for name, data in files.items():
        verify_bytes(data, pins['files'][name])
    receipt = {'schema': 1, 'role': 'upgrade-test-predecessor', 'repository': REPOSITORY,
               'repositoryId': REPOSITORY_ID, 'baselineSource': pins['source'],
               'baselineRun': pins['runId'], 'testSource': source,
               'version': pins['version'], 'versionCode': pins['versionCode'],
               'artifacts': pins['artifacts'], 'files': pins['files'], 'assertionCounts': counts,
               'passed': True, 'installerExecuted': False, 'upgradeExecuted': False,
               'desktopConsentTested': False, 'publicFeedVerified': False, 'publicationAllowed': False}
    destination.mkdir(mode=0o700)
    for name, data in files.items():
        with (destination / name).open('xb') as stream:
            stream.write(data)
        with (destination / (name + '.sha256')).open('x', encoding='ascii') as stream:
            stream.write(digest(data))
    with (destination / 'baseline-receipt.json').open('x', encoding='utf-8') as stream:
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    return destination


def environment(repo):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted' and
            os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and
            os.environ.get('GITHUB_REPOSITORY_ID') == str(REPOSITORY_ID) and
            os.environ.get('GITHUB_REF_NAME') in ('main', 'work/public') and
            re.fullmatch('[1-9][0-9]*', os.environ.get('GITHUB_RUN_ID', '')) is not None and
            sha(os.environ.get('GITHUB_SHA'), 40), 'ci_boundary')
    def git(*args):
        result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, timeout=10)
        require(result.returncode == 0, 'checkout_identity')
        return result.stdout.decode('utf-8').strip()
    require(git('remote', 'get-url', 'origin') in
            ('https://github.com/' + REPOSITORY, 'https://github.com/' + REPOSITORY + '.git')
            and git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA']
            and not git('status', '--porcelain', '--untracked-files=normal'), 'checkout_identity')
    policy = decode((repo / 'repository-policy.json').read_bytes())
    require(policy.get('repository') == REPOSITORY and policy.get('repositoryId') == REPOSITORY_ID
            and policy.get('publicationAllowed') is False and policy.get('releaseBaselineAccepted') is False, 'publication_boundary')
    for file in ('release/publish.json', 'release/preview-publish.json'):
        require(decode((repo / file).read_bytes()).get('publish') is False, 'publication_boundary')
    for file in ('updates/latest.json', 'updates/preview.json'):
        require(decode((repo / file).read_bytes()).get('published') is False, 'publication_boundary')
    root = Path(os.environ.get('RUNNER_TEMP', ''))
    require(root.is_absolute(), 'output_root')
    return root


def main():
    try:
        require(len(sys.argv) == 1, 'unsupported_arguments')
        repo = Path(__file__).resolve().parents[1]
        root = environment(repo)
        pins = validate_pins(decode((repo / 'release/clean-baseline.json').read_bytes()))
        meta = api('repos/' + REPOSITORY, pins)
        require(meta.get('id') == REPOSITORY_ID and meta.get('full_name') == REPOSITORY, 'repository_boundary')
        verify_run(api('repos/' + REPOSITORY + '/actions/runs/' + str(pins['runId']), pins), pins)
        payloads = {}
        for key, pin in pins['artifacts'].items():
            path = 'repos/' + REPOSITORY + '/actions/artifacts/' + str(pin['id'])
            verify_artifact(api(path, pins), pin, pins)
            payloads[key] = api(path + '/zip', pins, binary=True)
        files, counts = verify_payloads(payloads['packages'], payloads['evidence'], pins)
        stage(root, pins, files, counts, os.environ['GITHUB_SHA'])
        print('Clean baseline verified and staged. No installer executed; not release acceptance.')
        return 0
    except Refused as error:
        print('Clean baseline refused: ' + str(error), file=sys.stderr)
        return 1
    except Exception:
        print('Clean baseline refused: verification_error', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
