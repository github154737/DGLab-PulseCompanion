"""Bounded cloud relay acceptance probes; no physical output or private dialogue."""
import json
import os
from pathlib import Path
import re
import ssl
import time
import urllib.error
import urllib.request


def server():
    config = json.loads(Path('/etc/aihaptics-relay/config.json').read_text())
    base = os.environ.get('AIHAPTICS_RELAY_URL') or config.get('publicUrl')
    if not base: raise RuntimeError('Set AIHAPTICS_RELAY_URL for this server probe')
    fixtures = json.loads(Path('/root/aihaptics-model-benchmark/glm-deploy-fixtures.json').read_text())
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(
        context=ssl.create_default_context(cafile=config['certificate'])))
    rows = []

    def probe(name, path, payload=None, expected=200, token=None):
        req = urllib.request.Request(base.rstrip('/')+'/'+path,
            data=json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None,
            headers={'Authorization': 'Bearer '+(token or config['token']), 'Content-Type': 'application/json'})
        start = time.monotonic()
        row = {'name': name}
        value = None
        try:
            with op.open(req, timeout=35) as response:
                row['status'] = response.status
                row['version'] = response.headers.get('X-AIHaptics-Relay-Version')
                value = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            row['status'] = exc.code
        except Exception as exc:
            row['error_type'] = type(exc).__name__
        row['ms'] = round((time.monotonic()-start)*1000)
        row['passed'] = row.get('status') == expected
        rows.append(row)
        return value, row

    health, row = probe('health', 'health')
    row['passed'] &= health == {'ready': True, 'version': '0.12.3'}
    probe('auth_denied', 'health', token='invalid-fixture', expected=401)
    base = {'model': fixtures['model'], 'max_tokens': fixtures['max_tokens'],
            'temperature': .2, 'stream': False, 'response_format': {'type': 'json_object'}}
    for case in fixtures['cases']:
        body = {**base, 'messages': [
            {'role': 'system', 'content': fixtures['prompt']+'\nLocal state: '+json.dumps(case['state'], ensure_ascii=False, separators=(',', ':'))},
            {'role': 'user', 'content': case['text']}]}
        value, row = probe(case['id'], 'chat/completions', body)
        if value:
            choice = value['choices'][0]
            try:
                cmd = json.loads(choice['message']['content'])
                row['command'] = cmd
                row['passed'] &= choice['finish_reason'] == 'stop' and cmd == case['expected']
                row['response_model'] = value.get('model')
                row['passed'] &= row['response_model'] == fixtures['model']
            except (KeyError, ValueError, TypeError):
                row['passed'] = False
    chat = {'model': 'venice-uncensored-1-2', 'max_tokens': 40, 'stream': False,
            'messages': [{'role': 'user', 'content': 'Reply with OK.'}]}
    value, row = probe('existing_chat_model', 'chat/completions', chat)
    row['passed'] &= bool(value and value.get('choices'))
    probe('unknown_model_denied', 'chat/completions', {**chat, 'model': 'unapproved-model'}, expected=422)
    Path('/root/aihaptics-model-benchmark/glm-deploy-result.json').write_text(json.dumps({
        'path': 'cloud server -> authenticated HTTPS relay -> Venice',
        'physical_output': False, 'phone_verified': False, 'rows': rows,
        'passed': all(r['passed'] for r in rows)}, ensure_ascii=False, indent=2))
    print(json.dumps(rows, ensure_ascii=False))
    if not all(r['passed'] for r in rows): raise SystemExit(1)


def local():
    from cloud_relay_ssh import connect, run
    from cloud_configuration import relay_base
    import shlex
    root = Path(__file__).resolve().parent.parent
    prompt = re.search(r"static const plannerPrompt\s*=\s*'''(.*?)''';",
                       (root/'app/lib/venice_wave_session.dart').read_text(encoding='utf-8'), re.S).group(1)
    source = (root/'app/lib/venice_control_provider.dart').read_text()
    model = re.search(r"veniceControlModel = '([^']+)'", source).group(1)
    budget = int(re.search(r'veniceControlMaxTokens = (\d+)', source).group(1))
    state = dict(authorized=True, remaining_ms=None, mode='simulation', a=5, b=1,
                 cap=50, max_increase_per_turn=12, manual_step=1, selected='builtin.smooth',
                 waveforms=[{'id': 'builtin.smooth', 'name': '缓升缓降'}])
    cases = [dict(id='glm_hold', text='保持现在这样。', state=state, expected={'action': 'hold'}),
             dict(id='glm_target', text='把A调到10，B保持1。', state=state,
                  expected=dict(action='set', a=10, b=1, waveform_id='builtin.smooth')),
             dict(id='glm_stop', text='立即停止。', state=state, expected={'action': 'stop'})]
    client = connect()
    try:
        with client.open_sftp() as sftp:
            sftp.put(str(Path(__file__).resolve()), '/root/aihaptics-model-benchmark/verify-glm-cloud.py')
            with sftp.open('/root/aihaptics-model-benchmark/glm-deploy-fixtures.json', 'w') as f:
                f.write(json.dumps(dict(prompt=prompt, model=model, max_tokens=budget, cases=cases), ensure_ascii=False))
        command = 'AIHAPTICS_RELAY_URL=' + shlex.quote(relay_base()) + ' python3 /root/aihaptics-model-benchmark/verify-glm-cloud.py --server'
        code = run(client, command, timeout=180)
        with client.open_sftp() as sftp:
            sftp.get('/root/aihaptics-model-benchmark/glm-deploy-result.json', str(root/'reports/glm-cloud-acceptance.json'))
        if code: raise SystemExit(code)
    finally:
        client.close()


if __name__ == '__main__':
    import sys
    if '--server' in sys.argv: server()
    else: local()
