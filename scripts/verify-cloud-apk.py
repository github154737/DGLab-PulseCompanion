"""Inspect the pilot APK without printing embedded credentials."""
import hashlib
from cloud_configuration import relay_base, private_root
import json
from pathlib import Path
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
version, build = re.search(r'^version:\s*([^+\s]+)\+(\d+)', (root/'app/pubspec.yaml').read_text(), re.M).groups()
apk = root / f'artifacts/AIHapticsLab-{version}-venice-cloud-relay-android.apk'
old = root / 'artifacts/AIHapticsLab-0.13.0-venice-cloud-relay-android.apk'
tools = Path.home() / 'AppData/Local/Android/Sdk/build-tools/36.0.0'
java = Path('C:/software/AndroidStudio/jbr/bin/java.exe')

def signer(path):
    result = subprocess.run([str(java), '-jar', str(tools/'lib/apksigner.jar'),
                             'verify', '--verbose', '--print-certs', str(path)],
                            capture_output=True, check=True)
    match = re.search(rb'Signer #1 certificate SHA-256 digest: ([0-9a-f]+)', result.stdout)
    assert match, 'Signer digest missing'
    return match.group(1).decode()

defines = json.loads((private_root()/'android-defines.json').read_text())
assert defines['VENICE_RELAY_KIND'] == 'cloud'
assert defines['VENICE_RELAY_URL'].rstrip('/') == relay_base()
lan = Path.home()/'.aihaptics/venice-relay'
config = json.loads((lan/'config.json').read_text(encoding='utf-8-sig'))
keyfile = lan/Path(config['keyFile']).name
if not keyfile.exists(): keyfile = Path(config['keyFile'])
key = re.search(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}',keyfile.read_text(encoding='utf-8-sig')).group()
with zipfile.ZipFile(apk) as z:
    abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
    assert abis == ['arm64-v8a','x86_64']
    for abi in abis:
        for lib in ['libapp.so','libflutter.so','libhaptics_core.so']:
            assert f'lib/{abi}/{lib}' in z.namelist()
        compiled = z.read(f'lib/{abi}/libapp.so')
        assert defines['VENICE_RELAY_TOKEN'].encode() in compiled, 'Cloud token absent'
        assert defines['VENICE_RELAY_URL'].encode() in compiled, 'Cloud URL absent'
    for n in z.namelist():
        if not n.endswith('/'):
            data = z.read(n)
            assert key.encode() not in data and key.encode('utf-16-le') not in data, 'Supplier key detected'
badging = subprocess.check_output([str(tools/'aapt.exe'),'dump','badging',apk.name],cwd=apk.parent).decode('utf-8',errors='replace')
package = next(line for line in badging.splitlines() if line.startswith('package:'))
assert f"versionCode='{build}'" in package and f"versionName='{version}'" in package
current_signer, previous_signer = signer(apk), signer(old)
assert current_signer == previous_signer, 'Signer differs from previous APK'
report = {'artifact':apk.name,'bytes':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),
          'package':package,'abis':abis,'signature_verified':True,'same_signer_as_previous':True,
          'cloud_url_and_token_present_in_both_abis':True,'supplier_key_absent':True,
          'phone_verified':False}
(root/f'reports/cloud-apk-{version}-verification.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2))
