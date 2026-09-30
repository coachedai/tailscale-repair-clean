#!/usr/bin/env python3
"""Fail-closed repository binding and text-source privacy preflight.

--source-only is a local pre-import scan, not repository or release acceptance.
Normal use verifies the bound repository through the signed-in GitHub CLI.
--ci checks the immutable GitHub Actions repository ID and exact checkout SHA.
Matched values, paths and credentials are never printed.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
CANONICAL = 'coachedai/tailscale-repair-clean'
HTTPS = 'https://github.com/' + CANONICAL + '.git'
REMOTES = {HTTPS, HTTPS[:-4], ('git' + '@' + 'github.com:') + CANONICAL + '.git'}
OBSOLETE_NAME = 'tailscale-' + 'quick-repair'
spec = importlib.util.spec_from_file_location('privacy_patterns', ROOT / 'release/audit-git-history.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

class Refusal(RuntimeError):
    pass

def load_policy(root, unbound=False):
    p = json.loads((root / 'repository-policy.json').read_text('utf-8'))
    if (p.get('schema') != 1 or p.get('repository') != CANONICAL or
            p.get('owner') != 'coachedai' or p.get('allowOtherRepositories') is not False or
            p.get('publicationAllowed') is not False):
        raise Refusal('repository_policy_mismatch')
    expected_data_policy = {
        'allowPersonalData': False,
        'allowDeviceData': False,
        'allowNetworkIdentifiers': False,
        'allowSecrets': False,
        'allowCrossProjectContent': False,
        'allowInternalDevelopmentArtifacts': False,
        'allowInternalDevelopmentProvenance': False,
        'allowMachineEvidence': False,
    }
    if p.get('publicDataPolicy') != expected_data_policy:
        raise Refusal('public_data_policy_mismatch')
    expected_commit_policy = {
        'directMainDevelopment': False,
        'squashFeatureChanges': True,
        'avoidIntermediatePublicCommits': True,
        'oneReviewedCommitPerChangeSet': True,
    }
    if p.get('publicCommitPolicy') != expected_commit_policy:
        raise Refusal('public_commit_policy_mismatch')
    expected_docs_policy = {
        'allowInternalNotes': False,
        'allowedMarkdown': ['README.md','CONTRIBUTING.md','docs/INSTALL.md','docs/PRIVACY.md'],
    }
    if p.get('publicDocumentationPolicy') != expected_docs_policy:
        raise Refusal('public_documentation_policy_mismatch')
    if type(p.get('releaseBaselineAccepted')) is not bool:
        raise Refusal('release_baseline_policy_mismatch')
    identity = p.get('repositoryId')
    if not (type(identity) is int and identity > 0):
        if not (unbound and identity is None):
            raise Refusal('repository_id_not_bound')
    return p

def check_remote(value):
    if value not in REMOTES:
        raise Refusal('remote_not_authorized')

def scan_source(root):
    findings = set()
    count = 0
    sensitive = {'.env', '.env.local', 'config.json', 'secrets.json',
                 'credentials.json', 'id_rsa', 'id_ed25519'}
    internal_path_hashes = audit.INTERNAL_PATH_HASHES
    mac = re.compile(r'(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])')
    sid = re.compile(r'\bS-1-5-21-(?:\d+-){2}\d+\b')
    unix_home = re.compile(r'(?i)(?<![A-Za-z0-9_])/(?:home|Users)/([^/\s]+)')
    for current, directories, files in os.walk(root, followlinks=False):
        parent = Path(current)
        for name in list(directories):
            path = parent / name
            if path.is_symlink():
                findings.add(('symlink_directory', hashlib.sha256(str(path.relative_to(root)).encode()).hexdigest()))
                directories.remove(name)
            elif name in {'.git', '__pycache__'}:
                directories.remove(name)
        for name in files:
            path = parent / name
            relative = path.relative_to(root).as_posix()
            key = hashlib.sha256(relative.encode()).hexdigest()
            if any(
                    hashlib.sha256(part.lower().encode()).hexdigest() in internal_path_hashes
                    for part in Path(relative).parts
            ):
                findings.add(('internal_artifact_path', key))
            if path.is_symlink():
                findings.add(('symlink_file', key)); continue
            if name in sensitive or name.startswith('.env.') or path.suffix.lower() in {'.pem', '.pfx', '.p12', '.key'}:
                findings.add(('private_configuration', key)); continue
            if path.suffix.lower() not in audit.TEXT_EXTENSIONS and name not in audit.TEXT_LEAFS:
                findings.add(('unreviewed_file_type', key)); continue
            data = path.read_bytes()
            if len(data) > 5 * 1024 * 1024:
                findings.add(('oversize_source', key)); continue
            try:
                text = data.decode('utf-8-sig', 'strict')
            except UnicodeDecodeError:
                findings.add(('undecodable_source', key)); continue
            if '\0' in text:
                findings.add(('binary_text', key))
            if OBSOLETE_NAME in text or re.search(r'(?i)coachedai[/:]' + re.escape(OBSOLETE_NAME), text):
                findings.add(('obsolete_repository_reference', key))
            if mac.search(text):
                findings.add(('mac_address', key))
            if sid.search(text):
                findings.add(('windows_sid', key))
            for match in unix_home.finditer(text):
                if match.group(1) not in {'runner','<user>','USERNAME'}:
                    findings.add(('personal_home_path', key))
            audit.scan_text(text, lambda kind, obj, reason: findings.add((reason, key)), key, 'source')
            count += 1
    if findings:
        # Hashes and generic reason codes only. No offending filename or text.
        raise Refusal('source_scan_failed_' + str(len(findings)))
    return count

def run(args, root, optional=False):
    p = subprocess.run(args, cwd=root, capture_output=True, text=True, timeout=60)
    if p.returncode and not optional:
        raise Refusal('identity_command_failed')
    return p

def check_git(root, ci=False):
    git = lambda *args, optional=False: run(['git', '-C', str(root), *args], root, optional)
    top = Path(git('rev-parse', '--show-toplevel').stdout.strip()).resolve()
    if top != root.resolve():
        raise Refusal('wrong_working_repository')
    if git('remote').stdout.split() != ['origin']:
        raise Refusal('unexpected_remote_count')
    for key in ('remote.origin.url', 'remote.origin.pushurl'):
        values = git('config', '--get-all', key, optional=True).stdout.splitlines()
        if key.endswith('.url') and len(values) != 1:
            raise Refusal('invalid_origin')
        if len(values) > 1:
            raise Refusal('multiple_push_destinations')
        for value in values:
            check_remote(value)
    rewrites = git('config', '--get-regexp', r'^url\..*\.(insteadof|pushinsteadof)$', optional=True).stdout.splitlines()
    for line in rewrites:
        prefix = line.split(None, 1)[-1]
        if any(remote.startswith(prefix) for remote in REMOTES):
            raise Refusal('repository_url_rewrite')
    if ci:
        if os.environ.get('GITHUB_REPOSITORY') != CANONICAL:
            raise Refusal('ci_repository_mismatch')
        if git('rev-parse', 'HEAD').stdout.strip() != os.environ.get('GITHUB_SHA'):
            raise Refusal('ci_checkout_mismatch')

def verify_online(policy, ci=False):
    if ci:
        if os.environ.get('GITHUB_REPOSITORY_ID') != str(policy['repositoryId']):
            raise Refusal('ci_repository_id_mismatch')
        return
    if not shutil.which('gh'):
        raise Refusal('github_cli_required_for_online_identity')
    p = run(['gh', 'api', '--hostname', 'github.com', 'repos/' + CANONICAL], ROOT)
    metadata = json.loads(p.stdout)
    if (metadata.get('full_name') != CANONICAL or
            metadata.get('id') != policy['repositoryId'] or metadata.get('fork') is not False):
        raise Refusal('remote_repository_id_mismatch')

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    group = ap.add_mutually_exclusive_group()
    group.add_argument('--source-only', action='store_true')
    group.add_argument('--ci', action='store_true')
    args = ap.parse_args()
    policy = load_policy(ROOT, unbound=args.source_only)
    if args.source_only:
        if (ROOT / '.git').exists() or os.environ.get('GITHUB_ACTIONS') == 'true':
            raise Refusal('preimport_mode_not_allowed_here')
    else:
        check_git(ROOT, args.ci)
        verify_online(policy, args.ci)
    count = scan_source(ROOT)
    for name in ('publish.json', 'preview-publish.json'):
        if json.loads((ROOT / 'release' / name).read_text('utf-8-sig')).get('publish') is not False:
            raise Refusal('publication_must_remain_off')
    for name in ('latest.json', 'preview.json'):
        if json.loads((ROOT / 'updates' / name).read_text()).get('published') is not False:
            raise Refusal('migration_feed_must_be_unpublished')
    print(('Pre-import source scan' if args.source_only else 'Bound repository and source preflight') + ': passed (' + str(count) + ' text files). Not release acceptance.')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        reason = str(error) if isinstance(error, Refusal) else type(error).__name__
        if not re.fullmatch('[A-Za-z0-9_]+', reason): reason = 'preflight_failed'
        print('Preflight stopped: ' + reason + '. Matched content is withheld.', file=sys.stderr)
        sys.exit(1)
