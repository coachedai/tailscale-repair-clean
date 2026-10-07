#!/usr/bin/env python3
"""Read-only acceptance of complete, identity-bound native upgrade results."""
import json
import os
from pathlib import Path
import re
import stat
import sys

REPOSITORY = 'coachedai/tailscale-repair-clean'
REPOSITORY_ID = '1398720044'
MAX_REPORT = 128 * 1024
POINTS = 11
TRUE_FIELDS = ('passed', 'cleanupPassed', 'versionUpgradeExecuted', 'downgradeRefused',
               'competingOperationRefused', 'controlledFileRollbackTested', 'processFileRecoveryTested')
FALSE_FIELDS = ('desktopElevationTested', 'publicFeedVerified', 'interruptedUpgradeTested')
COUNT_FIELDS = ('controlledRollbackPoints', 'processRecoveryPoints')
IDENTITY_FIELDS = ('testSource', 'predecessorSource', 'candidateSource', 'predecessorVersion',
                   'candidateVersion', 'predecessorSha256', 'candidateSha256', 'payloadSha256')
SCOPE = ('Pinned RC12 seeded by its native installer methods; unchanged RC13 standalone process '
         'performs the version transition on an already elevated disposable Windows runner. '
         'Includes controlled exception rollback after each candidate file replacement, settings '
         'preservation, lease refusal, installed tray activation and real RC12 downgrade refusal. '
         'File-transaction host termination and fresh-process recovery are tested at all replacement '
         'points. Full installer/integration termination, power loss, secure-desktop consent and '
         'public delivery are not tested.')
SEED_CASES = (
    'Candidate Setup displays its real initial dialog',
    'Candidate cancellation targets only its owned window',
    'Candidate cancellation exits normally',
    'Candidate cancellation leaves installation state absent',
    'Both actual native manifests verify their complete file plans',
    'Both installers resolve only the guarded empty product roots',
    'Predecessor seed obtains the real installation lease',
    'Predecessor installation matches its fixed manifest',
    'Installed predecessor has the strictly older pinned version',
    'Controlled rollback owns the actual Setup lease',
    'Rollback exercises genuinely different predecessor and candidate bytes',
)
ROLLBACK_CASES = (
    'starts with the exact predecessor',
    'has no previous recovery journal',
    'injects only after a verified candidate replacement',
    'restores every exact predecessor file',
    'preserves all configuration bytes',
    'completes native recovery without manual cleanup',
)
PROCESS_CASES = (
    'begins with exact predecessor files',
    'has no earlier recovery evidence',
    'reaches its actual replacement callback',
    'observes durable recovery metadata and candidate bytes',
    'identifies only its owned transaction process',
    'confirms forced process termination',
    'retains interrupted state without exception rollback',
    'preserves settings at termination',
    'reacquires the native lease in a fresh process',
    'finishes the actual native recovery entry',
    'restores every exact predecessor file',
    'preserves complete settings after recovery',
    'lets native recovery finish its own cleanup',
)
UPGRADE_CASES = (
    'Fixture owns a real competing operation lease',
    'Candidate refuses a real competing operation',
    'Operation refusal is acknowledged only on the owned window',
    'Blocked upgrade returns the expected refusal code',
    'Blocked upgrade preserves every predecessor file',
    'Blocked upgrade preserves exact configuration bytes',
    'Unmodified candidate entry reports a successful version upgrade',
    'Real version upgrade installs all exact candidate files',
    'Upgrade completion uses the real Setup dialog',
    'Actual standalone version upgrade exits successfully',
    'Installed metadata records the genuinely newer candidate',
    'Version transition preserves the entire configuration byte-for-byte',
    'Target and startup preferences survive the version transition',
    'Candidate Setup itself launches the installed application',
    'The upgraded WPF application loads and responds',
    'Upgraded application clears its restart acknowledgement',
    'Close targets only the upgraded owned window',
    'The upgraded application remains resident after window close',
    'Second candidate launch activates the existing instance',
    'The same upgraded window restores and responds',
    'Only one upgraded resident instance remains',
    'The genuine predecessor installer refuses the newer installation',
    'Downgrade refusal targets only its owned window',
    'Older installer returns its expected refusal code',
    'Downgrade refusal leaves all candidate files unchanged',
    'Upgrade, activation and downgrade refusal preserve complete configuration bytes',
    'Candidate version remains installed after downgrade refusal',
    'Downgrade refusal does not disturb the upgraded application',
)


class Refused(ValueError):
    pass


def require(value):
    if not value:
        raise Refused('Native evidence refused; values withheld.')


def expected_cases():
    names = list(SEED_CASES)
    for point in range(1, POINTS + 1):
        names.extend('Rollback point %d %s' % (point, suffix) for suffix in ROLLBACK_CASES)
    names.extend(('All fixed candidate replacement points pass controlled rollback',
                  'Controlled rollback preserves target and startup preferences'))
    for point in range(1, POINTS + 1):
        names.extend('Process point %d %s' % (point, suffix) for suffix in PROCESS_CASES)
    names.extend(('All candidate file boundaries pass fresh-process recovery',
                  'All forced-termination file recovery points completed'))
    names.extend(UPGRADE_CASES)
    return names


def sha(value, length):
    return type(value) is str and re.fullmatch('[0-9a-f]{%d}' % length, value) is not None


def identities(old, new, source):
    require(type(old) is dict and type(new) is dict and sha(source, 40))
    for pin, version, code in ((old, '3.0.0-rc.12', 30001012), (new, '3.0.0-rc.13', 30001013)):
        require(pin.get('repository') == REPOSITORY and type(pin.get('repositoryId')) is int
                and pin['repositoryId'] == int(REPOSITORY_ID))
        require(pin.get('version') == version and type(pin.get('versionCode')) is int
                and pin['versionCode'] == code and sha(pin.get('source'), 40))
    require(old['source'] != new['source'])
    def digest(pin, prefix, suffix):
        records = pin.get('files')
        require(type(records) is dict)
        record = records.get(prefix + pin['version'] + suffix)
        require(type(record) is dict)
        value = record.get('sha256')
        require(sha(value, 64))
        return value
    return {
        'testSource': source, 'predecessorSource': old['source'], 'candidateSource': new['source'],
        'predecessorVersion': old['version'], 'candidateVersion': new['version'],
        'predecessorSha256': digest(old, 'TailscaleQuickRepair-Standalone-', '.exe'),
        'candidateSha256': digest(new, 'TailscaleQuickRepair-Standalone-', '.exe'),
        'payloadSha256': digest(new, 'TailscaleQuickRepair-SetupPackage-', '.zip'),
    }


def validate(report, old, new, source):
    expected = identities(old, new, source)
    fields = set(TRUE_FIELDS + FALSE_FIELDS + COUNT_FIELDS + IDENTITY_FIELDS)
    fields |= {'schema', 'cases', 'failureType', 'failureReason', 'stage', 'scope'}
    require(type(report) is dict and set(report) == fields)
    require(type(report['schema']) is int and report['schema'] == 1)
    for key in TRUE_FIELDS:
        require(report[key] is True)
    for key in FALSE_FIELDS:
        require(report[key] is False)
    for key in COUNT_FIELDS:
        require(type(report[key]) is int and report[key] == POINTS)
    for key, value in expected.items():
        require(type(report[key]) is str and report[key] == value)
    require(report['failureType'] == '' and report['failureReason'] == ''
            and report['stage'] == 'downgrade_refusal' and report['scope'] == SCOPE)
    names = expected_cases()
    cases = report['cases']
    require(type(cases) is list and len(cases) == len(names))
    for case, name in zip(cases, names):
        require(type(case) is dict and set(case) == {'name', 'passed'}
                and type(case['name']) is str and case['name'] == name and case['passed'] is True)
    return len(cases)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def decode(raw):
    require(type(raw) is bytes and 0 < len(raw) <= MAX_REPORT)
    try:
        text = raw.decode('utf-8-sig')
        depth = 0
        quoted = escaped = False
        for char in text:
            if quoted:
                if escaped: escaped = False
                elif char == '\\': escaped = True
                elif char == '"': quoted = False
            elif char == '"': quoted = True
            elif char in '{[':
                depth += 1
                require(depth <= 12)
            elif char in '}]': depth -= 1
        return json.loads(text, object_pairs_hook=unique_object,
                          parse_constant=lambda _: require(False))
    except (ValueError, UnicodeError, RecursionError):
        raise Refused('Native evidence refused; values withheld.') from None


def unlinked(path):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        info = part.lstat()
        require(not stat.S_ISLNK(info.st_mode) and not (getattr(info, 'st_file_attributes', 0) & 0x400))
    return path


def read_json(path):
    path = unlinked(path)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_REPORT)
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(path, flags), 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_REPORT
                and (info.st_dev, info.st_ino, info.st_size) == (before.st_dev, before.st_ino, before.st_size))
        raw = stream.read(MAX_REPORT + 1)
        require(len(raw) == info.st_size)
        return decode(raw)


def main():
    require(len(sys.argv) == 2)
    expected_env = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                    'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_REPOSITORY_ID': REPOSITORY_ID,
                    'RUNNER_OS': 'Windows', 'RUNNER_ARCH': 'X64'}
    require(all(os.environ.get(k) == v for k, v in expected_env.items()))
    require(os.environ.get('GITHUB_REF_NAME') in ('main', 'work/public'))
    here = Path(__file__).resolve().parent
    workspace = unlinked(os.environ['GITHUB_WORKSPACE'])
    temporary = unlinked(os.environ['RUNNER_TEMP'])
    report_path = unlinked(sys.argv[1])
    require(workspace == here.parent and temporary != workspace and workspace not in temporary.parents
            and temporary not in workspace.parents and temporary in report_path.parents
            and report_path.name == 'clean-version-upgrade-results.json')
    count = validate(read_json(report_path), read_json(here / 'clean-baseline.json'),
                     read_json(here / 'clean-upgrade.json'), os.environ['GITHUB_SHA'])
    print('Complete native upgrade evidence accepted: %d assertions. Publication remains separate.' % count)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Native evidence refused; values withheld.', file=sys.stderr)
        sys.exit(1)
