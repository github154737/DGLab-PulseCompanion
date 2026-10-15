"""Neutral, bounded live checks. Never prints credentials or model prose."""
import argparse
import json
import os
from pathlib import Path
import ssl
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', action='store_true')
    parser.add_argument('--proxy')
    parser.add_argument('--paid', action='store_true')
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.server:
        config = json.loads(Path('/etc/aihaptics-relay/config.json').read_text())
        token, cert = config['token'], config['certificate']
    else:
        home = Path.home() / '.aihaptics/venice-cloud-relay'
        token = json.loads((home / 'identity.json').read_text())['token']
        cert = str(home / 'server.pem')
    context = ssl.create_default_context(cafile=cert)
    op = urllib.request.build_opener(urllib.request.ProxyHandler({'https': args.proxy} if args.proxy else {}),
                                   urllib.request.HTTPSHandler(context=context))
    base = os.environ.get('AIHAPTICS_RELAY_URL') or (config.get('publicUrl') if args.server else json.loads((home / 'android-defines.json').read_text())['VENICE_RELAY_URL'])
    if not base: raise RuntimeError('Set AIHAPTICS_RELAY_URL for this server probe')
    base = base.rstrip('/')
    rows = []

    def request(path, data=None, auth=True, content_type='application/json'):
        headers = {'Content-Type': content_type}
        if auth: headers['Authorization'] = 'Bearer ' + token
        return urllib.request.Request(base + path, data=data, headers=headers)

    def check(name, path, data=None, expected=200, auth=True, kind='json', content_type='application/json'):
        started = time.monotonic()
        row = {'test': name}
        try:
            with op.open(request(path, data, auth, content_type), timeout=75) as r:
                row['status'] = r.status
                first = r.read(1)
                row['first_byte_ms'] = round((time.monotonic()-started)*1000)
                body = first + r.read()
                row['total_ms'] = round((time.monotonic()-started)*1000)
                row['bytes'] = len(body)
                row['ok'] = r.status == expected
                if kind == 'json':
                    value = json.loads(body)
                    if 'choices' in value: row['reply_nonempty'] = bool(value['choices'][0]['message']['content'].strip())
                    if 'text' in value:
                        row['fixture_recognized'] = 'hello' in value['text'].lower()
                        row['ok'] &= row['fixture_recognized']
                    return value, row
                if kind == 'sse':
                    text = body.decode()
                    row['sse_events'] = text.count('data:')
                    row['done'] = 'data: [DONE]' in text
                    row['ok'] &= row['done'] and row['sse_events'] > 2
                elif kind == 'mp3':
                    row['mp3_signature'] = body[:3] == b'ID3' or (len(body)>2 and body[0] == 255 and body[1]&224 == 224)
                    row['ok'] &= row['mp3_signature'] and len(body) > 1000
                return body, row
        except urllib.error.HTTPError as e:
            row.update(status=e.code, ok=e.code == expected)
            return None, row
        except Exception as e:
            row.update(ok=False, error_type=type(e).__name__)
            return None, row
        finally:
            rows.append(row)
            print(json.dumps(row), flush=True)

    def payload(messages, stream=False, **extra):
        return json.dumps(dict(model='venice-uncensored-1-2', messages=messages, max_tokens=180,
                               temperature=.2, stream=stream, **extra)).encode()

    check('health', '/health')
    check('unauthenticated_denied', '/health', expected=401, auth=False)
    check('unknown_route_denied', '/not-allowed', expected=404)
    check('unsupported_model_denied', '/chat/completions', b'{"model":"not-allowed"}', expected=422)
    check('oversized_body_denied', '/chat/completions', b'x'*140000, expected=413)
    if args.paid:
        check('models', '/models')
        check('chat', '/chat/completions', payload([{'role':'user','content':'Reply briefly in Chinese: connection test successful.'}]))
        check('chat_stream', '/chat/completions', payload([{'role':'user','content':'请用中文写五句中性的天气介绍，每句十五个字左右。'}], True), kind='sse')
        assert args.fixtures
        prompt = (args.fixtures / 'control-prompt.txt').read_text(encoding='utf-8')
        state = dict(authorized=True, remaining_ms=None, mode='simulation', a=2,b=2,cap=20,
                     max_increase_per_turn=5,manual_step=1,selected='builtin.smooth',
                     waveforms=[{'id':'builtin.smooth','name':'缓升缓降'},{'id':'builtin.pulse','name':'间歇脉冲'}])
        for name, text, expected in [('control_hold','你好，今天过得怎么样？','hold'),
                                     ('control_set','请把 A 通道调到 3，B 通道保持 2。','set'),
                                     ('control_stop','停止','stop')]:
            result,row = check(name, '/chat/completions', payload([
                {'role':'system','content':prompt+'\nLocal state: '+json.dumps(state,ensure_ascii=False)},
                {'role':'user','content':text}],response_format={'type':'json_object'}))
            if result:
                try:
                    command = json.loads(result['choices'][0]['message']['content'])
                    row['action'] = command.get('action');row['ok'] &= row['action']==expected
                    if expected=='set': row['ok'] &= command.get('a')==3 and command.get('b')==2 and command.get('waveform_id') in [w['id'] for w in state['waveforms']]
                except Exception: row['ok']=False
        for filename in ['relay-test-speech.wav','relay-test-speech-60s.wav']:
            boundary='cloud-'+uuid.uuid4().hex
            body=(f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nstt-xai-v1\r\n'
                  f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
                  f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()+(args.fixtures/filename).read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
            check('stt_'+filename,'/audio/transcriptions',body,content_type='multipart/form-data; boundary='+boundary)
        for streaming in [False,True]:
            data=json.dumps(dict(model='tts-xai-v1',input='你好，云端语音测试成功。现在可以继续聊天了。',voice='eve',language='zh',response_format='mp3',speed=1.0,streaming=streaming)).encode()
            check('tts_stream' if streaming else 'tts','/audio/speech',data,kind='mp3')
        # Cancel a stream without replaying the paid call, then check liveness.
        started=time.monotonic()
        try:
            with op.open(request('/chat/completions',payload([{'role':'user','content':'请用中文写二十句话描述森林。'}],True)),timeout=35) as r:
                r.read(1)
            rows.append({'test':'cancel_stream','ok':True,'ms':round((time.monotonic()-started)*1000)})
        except Exception as e: rows.append({'test':'cancel_stream','ok':False,'error_type':type(e).__name__})
        check('health_after_cancel','/health')
    report={'location':'server' if args.server else 'Windows', 'proxy_used':bool(args.proxy),
            'phone_verified':False,'physical_device_verified':False,'rows':rows,'ok':all(r['ok'] for r in rows)}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2),encoding='utf-8')
    if not report['ok']:raise SystemExit(1)


if __name__ == '__main__':main()
