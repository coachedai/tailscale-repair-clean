#!/usr/bin/env python3
"""Stage and revalidate two pinned versions for disposable upgrade acceptance."""
import importlib.util
import json
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


baseline = module('upgrade_baseline', 'prepare-clean-baseline.py')
inputs = module('upgrade_inputs', 'verify-clean-baseline-inputs.py')
require = baseline.require
Refused = baseline.Refused
RECEIPT = 'upgrade-input-receipt.json'


def validate_pair(old, new):
    baseline.validate_pins(old)
    baseline.validate_pins(new)
    require((old['version'], old['versionCode']) == ('3.0.0-rc.12', 30001012)
            and (new['version'], new['versionCode']) == ('3.0.0-rc.13', 30001013), 'version_pair')
    require(new['versionCode'] > old['versionCode'] and old['source'] != new['source']
            and old['tree'] != new['tree'] and old['runId'] != new['runId'], 'distinct_version_sources')
    ids = [p['artifacts'][key]['id'] for p in (old, new) for key in ('packages', 'evidence')]
    require(len(set(ids)) == 4, 'distinct_artifacts')
    return old, new


def download(pins):
    root = 'repos/' + baseline.REPOSITORY
    meta = baseline.api(root, pins)
    require(meta.get('id') == baseline.REPOSITORY_ID and
            meta.get('full_name') == baseline.REPOSITORY, 'repository_boundary')
    baseline.verify_run(baseline.api(root + '/actions/runs/' + str(pins['runId']), pins), pins)
    payloads = {}
    for key, pin in pins['artifacts'].items():
        path = root + '/actions/artifacts/' + str(pin['id'])
        baseline.verify_artifact(baseline.api(path, pins), pin, pins)
        payloads[key] = baseline.api(path + '/zip', pins, binary=True)
    return baseline.verify_payloads(payloads['packages'], payloads['evidence'], pins)


def names(old, new):
    return set(baseline.asset_names(old)) | set(baseline.asset_names(new))


def verify_files(files, old, new):
    validate_pair(old, new)
    require(set(files) == names(old, new), 'distribution_allowlist')
    for pin in (old, new):
        update, setup, exe = baseline.asset_names(pin)
        for name in (update, setup, exe):
            baseline.verify_bytes(files[name], pin['files'][name])
        require(baseline.verify_package(files[update], pin, False) ==
                baseline.verify_package(files[setup], pin, True), 'package_ui_mismatch')
        require(files[exe].startswith(b'MZ') and files[exe].count(files[setup]) == 1,
                'embedded_payload_mismatch')


def receipt(old, new, source, counts):
    validate_pair(old, new)
    require(baseline.sha(source, 40), 'source_identity')
    require(isinstance(counts, dict) and set(counts) == {'predecessor', 'candidate'}, 'evidence_roles')
    for item in counts.values():
        require(isinstance(item, dict) and set(item) == set(baseline.REPORTS) and
                all(baseline.integer(value, 10000) for value in item.values()), 'evidence_counts')
    return {'schema': 1, 'role': 'version-upgrade-test-inputs',
            'repository': baseline.REPOSITORY, 'repositoryId': baseline.REPOSITORY_ID,
            'testSource': source, 'predecessor': old, 'candidate': new,
            'assertionCounts': counts, 'passed': True, 'installerExecuted': False,
            'upgradeExecuted': False, 'desktopConsentTested': False,
            'publicFeedVerified': False, 'publicationAllowed': False}


def stage(root, old, new, files, counts, source):
    root = inputs.no_links(root)
    require(root.is_dir(), 'output_root')
    verify_files(files, old, new)
    record = receipt(old, new, source, counts)
    destination = root / 'tqr-clean-upgrade'
    require(not destination.exists() and not destination.is_symlink(), 'existing_output')
    destination.mkdir(mode=0o700)
    for name, data in sorted(files.items()):
        with (destination / name).open('xb') as handle:
            handle.write(data)
        with (destination / (name + '.sha256')).open('x', encoding='ascii') as handle:
            handle.write(baseline.digest(data))
    with (destination / RECEIPT).open('x', encoding='utf-8') as handle:
        json.dump(record, handle, indent=2)
        handle.write('\n')
    return destination


def verify(directory, old, new, source):
    validate_pair(old, new)
    directory = inputs.no_links(directory)
    require(directory.is_dir(), 'input_directory')
    wanted = names(old, new)
    require({p.name for p in directory.iterdir()} == wanted |
            {n + '.sha256' for n in wanted} | {RECEIPT}, 'staged_allowlist')
    record = inputs.decode(inputs.read(directory / RECEIPT, 65536))
    require(isinstance(record, dict), 'receipt_schema')
    expected = receipt(old, new, source, record.get('assertionCounts'))
    require(inputs.same(record, expected), 'receipt_identity_or_scope')
    files = {}
    for pin in (old, new):
        for name in baseline.asset_names(pin):
            files[name] = inputs.read(directory / name)
            require(inputs.read(directory / (name + '.sha256'), 256).decode('ascii').strip()
                    == pin['files'][name]['sha256'], 'checksum_integrity')
    verify_files(files, old, new)
    return record


def main():
    require(sys.argv[1:] == ['stage'] or
            (len(sys.argv) == 3 and sys.argv[1] == 'verify'), 'arguments')
    repo = HERE.parent
    temporary = inputs.no_links(baseline.environment(repo))
    old = baseline.decode(inputs.read(HERE / 'clean-baseline.json', 65536))
    new = baseline.decode(inputs.read(HERE / 'clean-upgrade.json', 65536))
    validate_pair(old, new)
    source = os.environ['GITHUB_SHA']
    if sys.argv[1] == 'stage':
        old_files, old_counts = download(old)
        new_files, new_counts = download(new)
        stage(temporary, old, new, dict(old_files, **new_files),
              {'predecessor': old_counts, 'candidate': new_counts}, source)
    else:
        directory = inputs.no_links(sys.argv[2])
        require(directory != temporary and temporary in directory.parents and
                directory != repo and repo not in directory.parents, 'temporary_boundary')
        verify(directory, old, new, source)
    print('Fixed version-upgrade inputs verified. No installer executed by this verifier.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Version-upgrade inputs refused; values withheld.', file=sys.stderr)
        sys.exit(1)
