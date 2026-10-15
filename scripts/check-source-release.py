"""Offline candidate-source audit. Reports paths/rules only, never secret values.

This is not a complete license audit, image OCR or APK audit.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile
import io


def candidate_files(root):
    output = subprocess.check_output(['git', '-c', 'core.quotepath=false', 'ls-files',
        '--cached', '--others', '--exclude-standard', '-z'], cwd=root)
    return sorted(set(output.decode('utf-8').split('\0')) - {''})


def load_private_markers():
    # Optional local comparison; a fresh checkout also works without these files.
    paths = [Path.home()/'.aihaptics/pilot-access/login-defines.json',
             Path.home()/'.aihaptics/venice-cloud-relay/android-defines.json',
             Path.home()/'.aihaptics/venice-cloud-relay/deployment.json']
    markers = []
    for path in paths:
        if not path.exists(): continue
        config = json.loads(path.read_text(encoding='utf-8-sig'))
        for field in ('PILOT_ADMIN_HASH', 'PILOT_USER_HASHES', 'VENICE_RELAY_TOKEN',
                      'VENICE_LOCAL_TEST_KEY', 'host'):
            value = config.get(field)
            if isinstance(value, str) and value:
                markers.extend(value.split(',') if field == 'PILOT_USER_HASHES' else [value])
    return [value.encode() for value in markers]


def inspect(data, markers):
    reasons = []
    if any(value in data for value in markers): reasons.append('private_configuration_value')
    text = data.decode('utf-8', errors='ignore')
    if re.search(r'-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----', text):
        reasons.append('private_key')
    if re.search(r'(?i)C:[/\\]+Users[/\\]+(?!Public\b|Default\b)[^/\\\s"<>]+', text):
        reasons.append('personal_absolute_path')
    if re.search(r'chatgpt\.com/share/[a-zA-Z0-9-]+', text): reasons.append('private_chat_link')
    # Synthetic fixtures are explicitly named, not real credentials.
    for token in re.findall(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}', text):
        if not re.search(r'(?i)synthetic|fixture|test_only|example|placeholder', token):
            reasons.append('credential_pattern'); break
    return sorted(set(reasons))


def inspect_content(data, markers, *, archive=False):
    """Apply the same bounded archive inspection to files and Git blobs."""
    rules = inspect(data, markers)
    if archive or data.startswith(b'PK\x03\x04'):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as contents:
                if sum(entry.file_size for entry in contents.infolist()) > 20_000_000:
                    rules.append('archive_requires_review')
                else:
                    for entry in contents.infolist():
                        if not entry.is_dir():
                            rules.extend(inspect(contents.read(entry), markers))
        except (zipfile.BadZipFile, RuntimeError, NotImplementedError):
            rules.append('unreadable_archive')
    return sorted(set(rules))


def audit(root):
    paths = candidate_files(root)
    markers = load_private_markers()
    findings = []
    for name in paths:
        path = root/name
        if not path.is_file(): continue
        if path.stat().st_size > 20_000_000:
            findings.append({'file': name, 'rules': ['large_file_requires_review']}); continue
        data = path.read_bytes()
        rules = inspect_content(data, markers, archive=name.endswith('.zip'))
        if rules: findings.append({'file': name, 'rules': sorted(set(rules))})
    ignored_tracked = subprocess.check_output(['git','ls-files','--cached','--ignored','--exclude-standard','-z'],cwd=root).decode().split('\0')
    for name in filter(None, ignored_tracked): findings.append({'file':name,'rules':['ignored_but_already_staged_or_tracked']})
    return {'candidate_files':len(paths), 'private_markers_compared':len(markers),
            'findings':findings, 'ok':not findings,
            'scope':'Current candidate source and small ZIP contents; no images OCR, Git history, APK or license certification'}


def audit_git_objects(root, *, history=False):
    """Inspect actual index/history blobs, independently of working-tree content."""
    markers = load_private_markers()
    if history:
        rows = subprocess.check_output(['git', 'rev-list', '--objects', '--all'], cwd=root).decode('utf-8').splitlines()
        objects = [(row.split(' ', 1)[0], row.split(' ', 1)[-1]) for row in rows]
    else:
        rows = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).decode('utf-8').split('\0')
        objects = [(row.split('\t', 1)[0].split()[1], row.split('\t', 1)[1]) for row in rows if row]
    findings, checked = [], 0
    seen = set()
    for oid, name in objects:
        if oid in seen: continue
        seen.add(oid)
        kind = subprocess.check_output(['git', 'cat-file', '-t', oid], cwd=root).strip()
        if kind != b'blob': continue
        checked += 1
        size = int(subprocess.check_output(['git', 'cat-file', '-s', oid], cwd=root))
        rules = ['large_blob_requires_review'] if size > 20_000_000 else inspect_content(
            subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=root), markers,
            archive=name.endswith('.zip'))
        if rules: findings.append({'file': name, 'object': oid, 'rules': rules})
    return {'blobs_checked': checked, 'findings': findings, 'ok': not findings}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--report',type=Path)
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--history', action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    result=audit(root)
    for enabled, name, history in [(args.staged, 'index', False), (args.history, 'history', True)]:
        if enabled:
            result[name]=audit_git_objects(root, history=history)
            result['ok'] = result['ok'] and result[name]['ok']
    result['scope'] = 'Candidate files and requested Git blobs; no image OCR, APK or license certification. History covers locally available refs only.'
    text=json.dumps(result,ensure_ascii=False,indent=2)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(text+'\n',encoding='utf-8')
    print(text)
    return 0 if result['ok'] else 1


if __name__ == '__main__': raise SystemExit(main())
