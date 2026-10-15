const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {test}=require('node:test');
const source=fs.readFileSync(`${__dirname}/probe.js`,'utf8');
async function page(){
  const elements=new Map(),requests=[],listeners={};let ws,resolveMic;
  const element=id=>{
    if(!elements.has(id))elements.set(id,{value:id==='style'?'playful':'',textContent:'',disabled:false,children:[],
      getContext:()=>({clearRect(){},beginPath(){},lineTo(){},moveTo(){},stroke(){}})});
    return elements.get(id);
  };
  const document={hidden:false,getElementById:element,addEventListener:(name,fn)=>{listeners[name]=fn;}};
  class Socket {static OPEN=1;constructor(){ws=this;this.readyState=1;this.sent=[];this.bufferedAmount=0;}send(data){this.sent.push(data);}close(){this.readyState=3;}}
  class Audio {constructor(){this.state='running';this.currentTime=0;this.audioWorklet={addModule:async()=>{}};}async resume(){}async close(){this.state='closed';}createMediaStreamSource(){return{connect(){},disconnect(){}};}}
  const context={document,location:{host:'127.0.0.1:8787'},WebSocket:Socket,AudioContext:Audio,
    AudioWorkletNode:class{constructor(){this.port={}}connect(){}disconnect(){}},
    navigator:{mediaDevices:{getUserMedia:()=>new Promise(resolve=>{resolveMic=resolve})}},
    fetch:async(path,options)=>{
      if(!options)return{json:async()=>({token:'fixture-token',credentials_ready:false})};
      requests.push({path,body:JSON.parse(options.body)});
      return{ok:true,json:async()=>({ok:true,credentials_ready:path!=='/forget'})};
    },setInterval(){},window:{addEventListener(){}},console};
  await vm.runInNewContext(`(async()=>{${source}\n})()`,context);
  ws.onopen();
  async function connect(){element('key').value='fictional-test-key';element('host').value='fixture.cn-beijing.maas.aliyuncs.com';await element('connect').onclick();}
  return{element,requests,document,listeners,get socket(){return ws},connect,resolveMic:(stream)=>resolveMic(stream)};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));

test('empty key field after connect clearly displays cached state and supports reconnect',async()=>{
  const p=await page();await p.connect();
  assert.equal(p.element('key').value,'');assert.match(p.element('credentialState').textContent,/无需重复填写/);
  assert.equal(p.requests[0].body.style,'playful');
  await p.element('disconnect').onclick();
  assert.match(p.element('connect').textContent,/无需重填/);
  await p.element('connect').onclick();assert.equal(p.requests.at(-1).body.key,'');
  await p.element('forget').onclick();assert.equal(p.requests.at(-1).path,'/forget');
  assert.match(p.element('credentialState').textContent,/尚未配置/);
});

test('hiding page pauses capture without disconnecting or forgetting credentials',async()=>{
  const p=await page();await p.connect();p.document.hidden=true;p.listeners.visibilitychange();await flush();
  assert.ok(p.socket.sent.includes('pause'));
  assert.equal(p.requests.filter(r=>r.path==='/disconnect'||r.path==='/forget').length,0);
  assert.match(p.element('status').textContent,/无需重填/);
  assert.equal(p.element('mic').disabled,false);
});

test('late microphone permission after background pause cannot start uploading',async()=>{
  const p=await page();await p.connect();const opening=p.element('mic').onclick();await flush();
  p.document.hidden=true;p.listeners.visibilitychange();await flush();
  let stopped=0;p.resolveMic({getTracks:()=>[{stop(){stopped++}}]});await opening;
  assert.equal(stopped,1);assert.ok(!p.socket.sent.includes('capture_started'));
});

test('audio handling failure preserves specific disconnect reason',async()=>{
  const p=await page();await p.connect();
  p.socket.onmessage({data:'bad-json'});await flush();
  assert.equal(p.requests.at(-1).path,'/disconnect');
  assert.equal(p.requests.at(-1).body.reason,'playback_error');
});
