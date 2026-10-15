"""Export a private connection file for the public app, without printing secrets."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit


def connection(config):
    url = config.get('VENICE_RELAY_URL', '')
    token = config.get('VENICE_RELAY_TOKEN', '')
    cert = config.get('VENICE_RELAY_CERT', '')
    if not all(isinstance(v, str) for v in (url, token, cert)):
        raise ValueError('Invalid connection field types')
    uri = urlsplit(url)
    if (uri.scheme != 'https' or not uri.hostname or uri.username or uri.password
            or uri.query or uri.fragment or not token.strip()
            or '\r' in token or '\n' in token or token.startswith('VENICE_INFERENCE_KEY_')):
        raise ValueError('Expected an HTTPS relay and relay token')
    data = dict(format='aihaptics-connection', version=1, url=url, token=token, certificate=cert)
    if len(json.dumps(data).encode()) > 32768:
        raise ValueError('Connection file exceeds app size limit')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home()/'.aihaptics/venice-cloud-relay/android-defines.json')
    parser.add_argument('--output', type=Path, default=Path.home()/'.aihaptics/connections/relay.connection.private.json')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.expanduser().resolve()
    if output.is_relative_to(root):
        raise ValueError('Connection files must be outside the repository')
    data = connection(json.loads(args.config.read_text(encoding='utf-8-sig')))
    output.parent.mkdir(parents=True, exist_ok=True)
    # Never overwrite a previously issued connection file silently.
    with output.open('x', encoding='utf-8') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    print('Private connection file exported. Contains relay access credentials; share only with intended testers.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError):
        raise SystemExit('Export failed: check external configuration, destination and existing files. No credentials printed.')
