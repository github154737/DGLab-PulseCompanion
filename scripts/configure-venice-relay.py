"""Create private local test configuration; never print credentials."""
import argparse
import base64
import datetime as dt
import ipaddress
import json
from pathlib import Path
import secrets
from relay_location import resolve_relay_home
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--key-file', required=True)
args = parser.parse_args()
ip = ipaddress.ip_address(args.host)
if not ip.is_private or ip.is_loopback:
    raise SystemExit('A private LAN address is required')
if not Path(args.key_file).is_file():
    raise SystemExit('Supplier key file is missing')
folder = resolve_relay_home(allow_missing=True)
folder.mkdir(parents=True, exist_ok=True)
config_path = folder / 'config.json'
if config_path.exists():
    config = json.loads(config_path.read_text(encoding='utf-8'))
    if config['host'] != args.host:
        raise SystemExit('LAN address changed; deliberately renew certificate and rebuild APK before reuse')
    # The resolver already verified the certificate/token against the APK
    # defines. Re-running setup must not rewrite or rotate this identity.
    print(f'Existing relay configuration verified at https://{args.host}:{config["port"]}; pairing unchanged.')
    raise SystemExit(0)
else:
    if any((folder / name).exists() for name in ('server.pem', 'server-key.pem', 'android-defines.json')):
        raise SystemExit('Incomplete existing relay files found. Restore the original bundle instead of replacing phone credentials.')
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'AI Haptics local relay')])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(private.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5)).not_valid_after(now + dt.timedelta(days=30))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(private, hashes.SHA256()))
    (folder / 'server.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (folder / 'server-key.pem').write_bytes(private.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    (folder / 'supplier-key.txt').write_bytes(Path(args.key_file).read_bytes())
    config = dict(host=args.host, port=9443, token=secrets.token_urlsafe(32),
        keyFile=str(folder / 'supplier-key.txt'), certificate=str(folder / 'server.pem'),
        privateKey=str(folder / 'server-key.pem'))
defines = dict(VENICE_RELAY_URL=f'https://{args.host}:9443/api/v1',
    VENICE_RELAY_TOKEN=config['token'],
    VENICE_RELAY_CERT=base64.b64encode((folder / 'server.pem').read_bytes()).decode())
(folder / 'android-defines.json').write_text(json.dumps(defines), encoding='utf-8')
# Publish config only after all companion files exist, then create recovery.
pending = folder / 'config.json.tmp'
pending.write_text(json.dumps(config), encoding='utf-8')
pending.replace(config_path)
resolve_relay_home()
print(f'Relay configured at https://{args.host}:9443; private files stay outside the repository.')
