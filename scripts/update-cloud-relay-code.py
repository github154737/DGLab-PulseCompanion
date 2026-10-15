"""Update relay code only; retain existing credentials, certificate and service.

Compile before replacing the binary. Keep a rollback binary/source; restore on
service restart failure. Uses the existing host-key-verified SSH connection.
"""
from pathlib import Path
from cloud_relay_ssh import connect, run

root = Path(__file__).resolve().parent.parent
activation = r'''set -eu
cd /opt/aihaptics-relay
/opt/dart-sdk/bin/dart compile exe tool/venice_relay.next.dart -o relay.next
chmod 755 relay.next
cp -p relay relay.previous
cp -p tool/venice_relay.dart tool/venice_relay.previous.dart
mv tool/venice_relay.next.dart tool/venice_relay.dart
mv relay.next relay
if ! systemctl restart aihaptics-relay || ! systemctl is-active --quiet aihaptics-relay; then
  cp -p relay.previous relay
  cp -p tool/venice_relay.previous.dart tool/venice_relay.dart
  systemctl restart aihaptics-relay
  exit 1
fi
systemctl is-active aihaptics-relay
'''

if __name__ == '__main__':
    client = connect()
    try:
        with client.open_sftp() as sftp:
            source = (root / 'app/tool/venice_relay.dart').read_text(encoding='utf-8')
            with sftp.open('/opt/aihaptics-relay/tool/venice_relay.next.dart', 'w') as f:
                f.write(source)
            with sftp.open('/root/aihaptics-deploy/update-code.sh', 'w') as f:
                f.chmod(0o700)
                f.write(activation)
        if run(client, 'bash /root/aihaptics-deploy/update-code.sh', timeout=180):
            raise SystemExit('Relay code update failed; inspect service state.')
        print('Relay code updated. Credentials and certificate unchanged.')
    finally:
        client.close()
