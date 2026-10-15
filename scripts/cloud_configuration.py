"""Private deployment metadata stays outside the checkout. Never prints secrets."""
import ipaddress
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


def private_root():
    return Path(os.environ.get('AIHAPTICS_CLOUD_HOME', str(Path.home() / '.aihaptics/venice-cloud-relay'))).expanduser()


def deployment():
    path = Path(os.environ.get('AIHAPTICS_DEPLOYMENT_CONFIG', str(private_root() / 'deployment.json')))
    value = json.loads(path.read_text(encoding='utf-8-sig'))
    host = value.get('host', '')
    if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host):
        raise ValueError('Invalid deployment host; use a hostname or IPv4 address')
    for field in ('ssh_port', 'proxy_port'):
        port = value.get(field, 22 if field == 'ssh_port' else 0)
        if type(port) is not int or not (0 <= port <= 65535) or (field == 'ssh_port' and not port):
            raise ValueError('Invalid deployment port')
        value[field] = port
    if not value.get('ssh_key') or not value.get('ssh_user'):
        raise ValueError('SSH user and key path must be configured')
    return value


def relay_base():
    override = os.environ.get('AIHAPTICS_RELAY_URL')
    if override:
        url = override
    else:
        url = json.loads((private_root() / 'android-defines.json').read_text(encoding='utf-8-sig'))['VENICE_RELAY_URL']
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Invalid relay HTTPS URL')
    return url.rstrip('/')


def certificate_san(host):
    try:
        ipaddress.ip_address(host)
        prefix = 'IP:'
    except ValueError:
        prefix = 'DNS:'
    return prefix + host + ',IP:127.0.0.1,DNS:relay.internal'
