"""Server-local abuse-boundary checks; makes no paid upstream requests."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import ssl
import urllib.error
import urllib.request

public_url = os.environ.get('AIHAPTICS_RELAY_URL') or json.loads(Path('/etc/aihaptics-relay/config.json').read_text()).get('publicUrl')
if not public_url: raise RuntimeError('Set AIHAPTICS_RELAY_URL for this server probe')
base = public_url.rstrip('/') + '/health'
context = ssl.create_default_context(cafile='/etc/aihaptics-relay/server.pem')


def unauthenticated(_):
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    try:
        with op.open(base, timeout=10) as r:return r.status
    except urllib.error.HTTPError as e:return e.code


with ThreadPoolExecutor(max_workers=12) as pool:
    statuses = list(pool.map(unauthenticated, range(40)))
untrusted_rejected = False
try:
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with op.open(base, timeout=10):pass
except urllib.error.URLError as e:
    untrusted_rejected = isinstance(e.reason, ssl.SSLCertVerificationError)
result = {'unauthenticated_status_counts': {str(s):statuses.count(s) for s in set(statuses)},
          'rate_limit_observed':429 in statuses,
          'untrusted_certificate_rejected':untrusted_rejected,
          'ok':all(s in (401,429) for s in statuses) and 429 in statuses and untrusted_rejected}
Path('/root/aihaptics-deploy/boundary.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
if not result['ok']:raise SystemExit(1)
