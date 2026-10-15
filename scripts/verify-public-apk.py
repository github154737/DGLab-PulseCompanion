"""Offline public APK release check. Does not install, upload or contact a service."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('source_audit', ROOT/'scripts/check-source-release.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def inspect_archive(path, markers):
    findings = []
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        abis = sorted({name.split('/')[1] for name in names if name.startswith('lib/')})
        if abis != ['arm64-v8a', 'x86_64']: findings.append('unexpected_abis')
        for abi in abis:
            for lib in ['libapp.so', 'libflutter.so', 'libhaptics_core.so']:
                if f'lib/{abi}/{lib}' not in names: findings.append('missing_native_library')
        for entry in archive.infolist():
            if entry.is_dir(): continue
            if entry.file_size > 200_000_000: raise ValueError('Oversized APK entry')
            data = archive.read(entry)
            if audit.inspect(data, markers): findings.append('sensitive_content:' + entry.filename)
            if any(marker.decode('utf-8').encode('utf-16-le') in data for marker in markers):
                findings.append('sensitive_utf16_content:' + entry.filename)
        resource = 'assets/flutter_assets/assets/user-waveforms.zip'
        if resource not in names:
            findings.append('missing_public_wave_bundle')
        else:
            with zipfile.ZipFile(io.BytesIO(archive.read(resource))) as waves:
                if waves.namelist() != ['README.txt']: findings.append('private_wave_bundle')
        if 'assets/flutter_assets/assets/rust-third-party-notices.txt' not in names:
            findings.append('missing_rust_notices')
    return sorted(set(findings))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--expected-signer', required=True, help='Trusted release certificate SHA-256, not a private key')
    parser.add_argument('--build-tools', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    expected = args.expected_signer.replace(':', '').lower()
    if not re.fullmatch('[0-9a-f]{64}', expected): raise ValueError('Invalid expected signer digest')
    sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home()/'AppData/Local/Android/Sdk')))
    tools = args.build_tools or sdk/'build-tools/36.0.0'
    java = Path(os.environ['JAVA_HOME'])/'bin/java.exe'
    result = subprocess.check_output([str(java), '-jar', str(tools/'lib/apksigner.jar'),
        'verify', '--verbose', '--print-certs', str(args.apk)], stderr=subprocess.STDOUT)
    signers = re.findall(rb'Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)', result)
    if signers != [expected.encode()]: raise ValueError('APK signing certificate differs from expected release identity')
    if b'CN=Android Debug' in result: raise ValueError('Debug signing is forbidden for public release')
    badging = subprocess.check_output([str(tools/'aapt.exe'), 'dump', 'badging', str(args.apk)]).decode(errors='replace')
    if "name='dev.aihaptics.haptics_lab.community'" not in badging or 'application-debuggable' in badging:
        raise ValueError('Unexpected package or debuggable release')
    findings = inspect_archive(args.apk, audit.load_private_markers())
    report = dict(ok=not findings, artifact=args.apk.name, sha256=hashlib.sha256(args.apk.read_bytes()).hexdigest(),
                  signer=expected, findings=findings, device_tested=False,
                  scope='Signature, package, native libraries, resource bundle and known credential patterns; not a proof of all secrets absent')
    if args.report: args.report.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile):
        raise SystemExit('Public APK check failed. Verify tools, signing identity and release inputs. No credential data printed.')
