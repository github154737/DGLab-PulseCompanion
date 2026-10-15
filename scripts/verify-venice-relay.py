"""One paid chat and one synthetic-speech request through the LAN HTTPS relay."""
import base64
import io
import json
import os
from pathlib import Path
import ssl
import sys
import time
import urllib.request
import urllib.error
import uuid
import wave
from relay_location import resolve_relay_home

config = json.loads((resolve_relay_home() / 'config.json').read_text(encoding='utf-8'))
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=config['certificate'])))
base = f"https://{config['host']}:{config['port']}/api/v1"
result = {'path': 'PC LAN HTTPS relay -> Venice', 'phone_verified': False}
def call(name, path, data=None, content_type='application/json'):
    start = time.monotonic()
    try:
        req = urllib.request.Request(base + path, data=data, headers={
            'Authorization': 'Bearer ' + config['token'], 'Content-Type': content_type})
        with opener.open(req, timeout=100) as response:
            value = json.load(response)
        result[name] = dict(ok=True, ms=round((time.monotonic()-start)*1000))
        if name == 'chat': result[name]['characters'] = len(value['choices'][0]['message']['content'])
        if name == 'stt':
            result[name]['characters'] = len(value['text'])
            result[name]['fixture_recognized'] = 'hello' in value['text'].lower()
    except urllib.error.HTTPError as error:
        result[name] = dict(ok=False, status=error.code)
    except Exception as error:
        result[name] = dict(ok=False, error_type=type(error).__name__)
    print(json.dumps({name: result[name]}), flush=True)
call('models', '/models')
call('chat', '/chat/completions', json.dumps(dict(model='venice-uncensored-1-2',
    messages=[dict(role='user', content='Please reply only: connection successful.')],
    max_tokens=40, stream=False, temperature=0.2)).encode())
pcm = base64.b64decode(sys.stdin.read().strip())
wav = io.BytesIO()
with wave.open(wav, 'wb') as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000); out.writeframes(pcm)
boundary = 'relay-probe-' + uuid.uuid4().hex
body = (f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nstt-xai-v1\r\n'
    f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
    f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode() + wav.getvalue() + f'\r\n--{boundary}--\r\n'.encode()
call('stt', '/audio/transcriptions', body, 'multipart/form-data; boundary=' + boundary)
Path('reports/venice-relay-live-check.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
