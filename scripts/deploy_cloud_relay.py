"""Deploy the dedicated pilot relay without modifying LAN credentials or prompts.

Requires bootstrap to have completed. Secrets remain outside the repository and
are transferred only over host-key-verified SSH. No APK build is performed.
"""
import base64
import argparse
import json
from pathlib import Path
import re
import secrets
import shlex
from cloud_configuration import private_root, certificate_san
import subprocess

from cloud_relay_ssh import connect, run, HOST

ROOT = Path(__file__).resolve().parent.parent
PRIVATE = private_root()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key-file', type=Path, help='External supplier key file; avoids requiring a prior LAN setup')
    args = parser.parse_args()
    PRIVATE.mkdir(parents=True, exist_ok=True)
    raw_identity = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'])
    account = '*' + re.search(rb'S-1-5-21-[0-9-]+', raw_identity).group().decode('ascii')
    subprocess.run(['icacls', str(PRIVATE), '/inheritance:r', '/grant:r',
                    f'{account}:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F',
                    '*S-1-5-32-544:(OI)(CI)F'], check=True, capture_output=True)
    identity = PRIVATE / 'identity.json'
    if not identity.exists():
        identity.write_text(json.dumps({'host': HOST, 'token': secrets.token_urlsafe(48)}), encoding='utf-8')
    local = json.loads(identity.read_text(encoding='utf-8'))
    assert local['host'] == HOST and len(local['token']) >= 40
    keyfile = args.key_file
    if keyfile is None:
        lan = Path.home() / '.aihaptics/venice-relay'
        cfg = json.loads((lan / 'config.json').read_text(encoding='utf-8-sig'))
        keyfile = lan / Path(cfg['keyFile']).name
        if not keyfile.exists(): keyfile = Path(cfg['keyFile'])
    matches = re.findall(r'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}', keyfile.read_text(encoding='utf-8-sig'))
    if len(matches) != 1: raise RuntimeError('Expected one existing supplier key')
    server = {'publicUrl': f'https://{HOST}/api/v1', 'host': '127.0.0.1', 'port': 9443, 'token': local['token'],
              'keyFile': '/etc/aihaptics-relay/supplier-key.txt',
              'certificate': '/etc/aihaptics-relay/server.pem',
              'privateKey': '/etc/aihaptics-relay/server-key.pem'}
    client = connect()
    try:
        with client.open_sftp() as sftp:
            try:
                with sftp.open('/etc/aihaptics-relay/config.json') as f: previous = json.loads(f.read())
                if previous['token'] != local['token']: raise RuntimeError('Existing cloud identity mismatch; do not overwrite')
            except FileNotFoundError: pass
            def protected_write(path, value):
                # Private parent directory prevents access while creating file.
                with sftp.open(path, 'w') as f:
                    f.chmod(0o600)
                    f.write(value)
            protected_write(server['keyFile'], matches[0])
            protected_write('/etc/aihaptics-relay/config.json', json.dumps(server))
            for directory in ['/opt/aihaptics-relay/tool', '/opt/aihaptics-relay/lib']:
                try: sftp.mkdir(directory)
                except OSError: sftp.stat(directory)
            sftp.put(str(ROOT / 'app/tool/venice_relay.dart'), '/opt/aihaptics-relay/tool/venice_relay.dart')
            sftp.put(str(ROOT / 'app/lib/http_connection_pool.dart'), '/opt/aihaptics-relay/lib/http_connection_pool.dart')
            # Normalize Windows checkout line endings before running under bash.
            activation = (ROOT / 'scripts/cloud-relay-activate.sh').read_text(encoding='utf-8-sig')
            with sftp.open('/root/aihaptics-deploy/activate.sh', 'w') as script:
                script.write(activation.replace('\r\n', '\n').replace('\r', '\n'))
        activation_command = 'RELAY_SAN=' + shlex.quote(certificate_san(HOST)) + ' bash /root/aihaptics-deploy/activate.sh'
        if run(client, activation_command, timeout=180):
            raise RuntimeError('Activation failed; inspect sanitized service diagnostics')
        with client.open_sftp() as sftp:
            sftp.get('/etc/aihaptics-relay/server.pem', str(PRIVATE / 'server.pem'))
        defines = {'VENICE_RELAY_KIND': 'cloud',
                   'VENICE_RELAY_URL': f'https://{HOST}/api/v1',
                   'VENICE_RELAY_TOKEN': local['token'],
                   'VENICE_RELAY_CERT': base64.b64encode((PRIVATE / 'server.pem').read_bytes()).decode()}
        (PRIVATE / 'android-defines.json').write_text(json.dumps(defines, indent=2), encoding='utf-8')
        print('Cloud deployed; private Android configuration prepared. No APK built.')
    finally:
        client.close()


if __name__ == '__main__': main()
