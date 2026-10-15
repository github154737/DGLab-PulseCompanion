"""Two bounded neutral API probes; log metadata, never speech/key/response bodies."""
import io
from cloud_configuration import relay_base, private_root
import json
from pathlib import Path
import ssl
import time
import urllib.request
import urllib.error
import uuid
import wave

root = Path(__file__).resolve().parent.parent
private = private_root()
token = json.loads((private / 'identity.json').read_text())['token']
context = ssl.create_default_context(cafile=str(private / 'server.pem'))
op = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=context))
rows = []

def probe(name, path, data=None, mime='application/json'):
    request_id = 'voicecheck-' + uuid.uuid4().hex
    request = urllib.request.Request(relay_base() + '/' + path,
        data=data, headers={'Authorization': 'Bearer ' + token,
                            'Content-Type': mime, 'X-AIHaptics-Request-Id': request_id})
    start = time.monotonic()
    row = {'name': name, 'request_id': request_id}
    try:
        with op.open(request, timeout=35) as response:
            row['status'] = response.status
            row['relay_version'] = response.headers.get('X-AIHaptics-Relay-Version')
            first = response.read(32)
            row['first_bytes_ms'] = round((time.monotonic()-start)*1000)
            body = first + response.read(2*1024*1024)
            row['bytes'] = len(body)
            if path.endswith('transcriptions'):
                value = json.loads(body)
                text = value.get('text')
                row['text_field_valid'] = isinstance(text, str)
                row['empty_transcript'] = isinstance(text, str) and not text.strip()
                row['text_length'] = len(text) if isinstance(text, str) else None
            elif path.endswith('speech'):
                row['mp3_signature'] = body[:3] == b'ID3' or (len(body)>2 and body[0] == 255 and body[1]&224 == 224)
            else:
                row['ready'] = json.loads(body).get('ready') is True
    except urllib.error.HTTPError as error:
        row['status'] = error.code
    except Exception as error:
        row['error_type'] = type(error).__name__
    row['total_ms'] = round((time.monotonic()-start)*1000)
    rows.append(row)
    print(json.dumps(row), flush=True)

probe('health', 'health')
buffer = io.BytesIO()
with wave.open(buffer, 'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
    wav.writeframes(bytes(32000))
boundary = 'voicecheck-' + uuid.uuid4().hex
body = bytearray()
for name, value in [('model', 'stt-xai-v1'), ('response_format', 'json'), ('timestamps', 'false')]:
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="silence.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
body.extend(buffer.getvalue())
body.extend(f'\r\n--{boundary}--\r\n'.encode())
probe('one_second_silence', 'audio/transcriptions', bytes(body), 'multipart/form-data; boundary='+boundary)
probe('neutral_tts', 'audio/speech', json.dumps(dict(model='tts-xai-v1',
    input='你好，这是语音测试。', voice='eve', language='zh', response_format='mp3',
    streaming=True, speed=1)).encode())
(root/'reports/voice-recovery-cloud-live.json').write_text(json.dumps({
    'location': 'Windows direct HTTPS (system VPN routing may apply)', 'phone_verified': False,
    'audio_listened': False, 'rows': rows}, indent=2), encoding='utf-8')
if any(row.get('status') != 200 for row in rows): raise SystemExit(1)
