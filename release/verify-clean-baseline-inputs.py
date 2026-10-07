#!/usr/bin/env python3
"""Recheck fixed staged baseline bytes before native installation acceptance."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

REPOSITORY = 'coachedai/tailscale-repair-clean'
REPOSITORY_ID = 1398720044
MAX_FILE = 2 * 1024 * 1024
REPORTS = {'native-windows-results.json', 'native-permission-results.json',
           'protected-migration-results.json', 'standalone-setup-results.json',
           'local-control-center-results.json', 'vpn-awareness-results.json'}


class Refused(RuntimeError):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def decode(raw):
    try:
        return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused('json_constant')))
    except (ValueError, UnicodeError):
        raise Refused('invalid_json') from None


def same(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return set(left) == set(right) and all(same(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    return left == right


def no_links(path):
    path = Path(path).absolute()
    require('..' not in path.parts, 'input_traversal')
    for item in (path, *path.parents):
        info = item.lstat()
        require(not stat.S_ISLNK(info.st_mode) and not
                (getattr(info, 'st_file_attributes', 0) & 1024), 'redirected_input')
    return path


def read(path, maximum=MAX_FILE):
    path = no_links(path)
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= maximum, 'input_size_or_type')
    with path.open('rb') as handle:
        data = handle.read(maximum + 1)
    require(len(data) == info.st_size and len(data) <= maximum, 'input_changed')
    return data


def verify(root, pins, source):
    require(isinstance(pins, dict) and pins.get('repository') == REPOSITORY
            and type(pins.get('repositoryId')) is int and pins['repositoryId'] == REPOSITORY_ID,
            'repository_boundary')
    require(isinstance(source, str) and re.fullmatch('[0-9a-f]{40}', source), 'source_identity')
    version = pins.get('version')
    require(isinstance(version, str) and re.fullmatch(r'3\.0\.0-rc\.[1-9][0-9]*', version), 'version_identity')
    assets = {'TailscaleQuickRepair-' + version + '.zip',
              'TailscaleQuickRepair-SetupPackage-' + version + '.zip',
              'TailscaleQuickRepair-Standalone-' + version + '.exe'}
    require(isinstance(pins.get('files'), dict) and set(pins['files']) == assets, 'asset_allowlist')
    root = no_links(root)
    require(root.is_dir(), 'input_directory')
    require({p.name for p in root.iterdir()} == assets | {n + '.sha256' for n in assets}
            | {'baseline-receipt.json'}, 'staged_allowlist')
    receipt = decode(read(root / 'baseline-receipt.json', 65536))
    require(isinstance(receipt, dict), 'receipt_schema')
    expected = {'schema': 1, 'role': 'upgrade-test-predecessor', 'repository': REPOSITORY,
                'repositoryId': REPOSITORY_ID, 'baselineSource': pins['source'],
                'baselineRun': pins['runId'], 'testSource': source, 'version': version,
                'versionCode': pins['versionCode'], 'artifacts': pins['artifacts'], 'files': pins['files'],
                'passed': True, 'installerExecuted': False, 'upgradeExecuted': False,
                'desktopConsentTested': False, 'publicFeedVerified': False, 'publicationAllowed': False}
    require(set(receipt) == set(expected) | {'assertionCounts'}, 'receipt_schema')
    for key, value in expected.items():
        require(same(receipt[key], value), 'receipt_identity_or_scope')
    counts = receipt['assertionCounts']
    require(isinstance(counts, dict) and set(counts) == REPORTS and
            all(type(n) is int and 0 < n <= 10000 for n in counts.values()), 'receipt_evidence')
    for name in sorted(assets):
        pin = pins['files'][name]
        require(isinstance(pin, dict) and set(pin) == {'size', 'sha256'}
                and type(pin['size']) is int and 0 < pin['size'] <= MAX_FILE
                and isinstance(pin['sha256'], str) and re.fullmatch('[0-9a-f]{64}', pin['sha256']), 'asset_pin')
        data = read(root / name)
        require(len(data) == pin['size'] and hashlib.sha256(data).hexdigest() == pin['sha256'], 'asset_integrity')
        require(read(root / (name + '.sha256'), 256).decode('ascii').strip() == pin['sha256'], 'checksum_integrity')
    return receipt


def main():
    require(len(sys.argv) == 2, 'arguments')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and
            os.environ.get('GITHUB_REPOSITORY_ID') == str(REPOSITORY_ID), 'environment_boundary')
    directory = no_links(sys.argv[1])
    temporary = no_links(os.environ['RUNNER_TEMP'])
    require(directory != temporary and temporary in directory.parents, 'temporary_boundary')
    root = Path(__file__).resolve().parents[1]
    require(directory != root and root not in directory.parents, 'checkout_boundary')
    pins = decode(read(root / 'release' / 'clean-baseline.json', 65536))
    verify(directory, pins, os.environ.get('GITHUB_SHA', ''))
    print('Staged clean baseline verified: three fixed distribution files; no installer executed.')


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, KeyError, TypeError, UnicodeError):
        print('Staged baseline refused; no installer authorized. Values withheld.', file=sys.stderr)
        sys.exit(1)
