const $=id=>document.getElementById(id);
let token='', socket, ready=false, busy=false, micBusy=false, audio, stream, capture, input;
let micGeneration=0, playAt=0, playbackEnabled=false;
let credentialsReady=false, lastStatus='', finishing=false;
const playing=new Set(), points=[];
function message(text){$('status').textContent=text;}
async function post(path, body={}) {
  const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Probe-Token':token},body:JSON.stringify(body)});
  const value=await response.json();
  if(!response.ok || value.ok===false) throw new Error(value.error||'操作未完成');
  return value;
}
function buttons(){
  $('connect').disabled=ready||busy||socket?.readyState!==WebSocket.OPEN;
  $('connect').textContent=ready?'已连接':credentialsReady?'重新连接（无需重填密钥）':'连接百炼';
  $('credentialState').textContent=credentialsReady?'密钥已配置在本机内存 · 输入框清空是正常现象，无需重复填写':'尚未配置密钥，或临时配置已清除 / 过期';
  $('key').placeholder=credentialsReady?'已配置，无需重复填写；需要更换时再粘贴':'首次连接时填写，不保存到磁盘';
  $('style').disabled=ready||busy;
  $('mic').disabled=!ready||micBusy||busy;
  $('grant').disabled=!ready||busy;
  $('interrupt').disabled=!ready;
}
function cancelPlayback(){
  for(const node of playing){try{node.stop();}catch{} node.disconnect();}
  playing.clear();playAt=0;$('audioState').textContent='扬声器空闲';
}
async function ensureAudio(){
  if(!audio || audio.state==='closed') audio=new AudioContext({latencyHint:'interactive'});
  await audio.resume();
}
function play(encoded){
  if(!playbackEnabled || !audio || audio.state!=='running') return;
  const raw=atob(encoded),view=new DataView(new ArrayBuffer(raw.length));
  for(let i=0;i<raw.length;i++)view.setUint8(i,raw.charCodeAt(i));
  if(raw.length%2) throw new Error('音频格式异常');
  const buffer=audio.createBuffer(1,raw.length/2,24000),samples=buffer.getChannelData(0);
  for(let i=0;i<samples.length;i++)samples[i]=view.getInt16(i*2,true)/32768;
  playAt=Math.max(playAt,audio.currentTime+0.025);
  if(playAt-audio.currentTime>12) throw new Error('播放缓冲过长');
  const node=audio.createBufferSource();node.buffer=buffer;node.connect(audio.destination);
  playing.add(node);node.onended=()=>{playing.delete(node);node.disconnect();if(!playing.size)$('audioState').textContent='扬声器空闲';};
  node.start(playAt);playAt+=buffer.duration;$('audioState').textContent='正在播放 AI 语音';
}
async function stopMic(){
  ++micGeneration;micBusy=false;
  if(capture){capture.port.onmessage=null;capture.disconnect();capture=null;}
  input?.disconnect();input=null;
  stream?.getTracks().forEach(track=>track.stop());stream=null;
  $('capture').textContent='麦克风关闭 · 未上传';$('mic').textContent='开启麦克风并上传';buttons();
}
async function finish(reason='user_disconnect',forget=false){
  if(finishing)return;
  finishing=true;busy=true;
  ready=false;playbackEnabled=false;cancelPlayback();await stopMic();
  if(audio){await audio.close().catch(()=>{});audio=null;}
  try{await post(forget?'/forget':'/disconnect',{reason});if(forget)credentialsReady=false;}catch(error){message(error.message);}
  finally{finishing=false;busy=false;buttons();}
}
async function pauseCapture(){
  playbackEnabled=false;cancelPlayback();
  if(socket?.readyState===WebSocket.OPEN)socket.send('pause');
  await stopMic();
  if(ready)message('已暂停采集与模拟输出 · 返回后点击开启麦克风，无需重填密钥');
}
$('connect').onclick=async()=>{
  busy=true;buttons();message('正在连接百炼…');
  let body={host:$('host').value.trim(),key:$('key').value.trim(),style:$('style').value};
  $('key').value='';
  try{
    await ensureAudio();playbackEnabled=true;
    const result=await post('/connect',body);credentialsReady=result.credentials_ready===true;ready=true;message('已连接 · 点击“开启麦克风并上传”开始');
  }catch(error){playbackEnabled=false;message(error.message);}
  finally{body.key='';body=null;busy=false;buttons();}
};
$('disconnect').onclick=()=>finish();
$('forget').onclick=()=>finish('user_disconnect',true);
$('mic').onclick=async()=>{
  if(stream){await pauseCapture();return;}
  const generation=++micGeneration;micBusy=true;buttons();
  let next;
  try{
    await ensureAudio();
    next=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:false},video:false});
    if(generation!==micGeneration||!ready){next.getTracks().forEach(t=>t.stop());return;}
    await audio.audioWorklet.addModule('/pcm-worklet.js');
    if(generation!==micGeneration||!ready){next.getTracks().forEach(t=>t.stop());return;}
    stream=next;input=audio.createMediaStreamSource(stream);capture=new AudioWorkletNode(audio,'pcm-capture');
    playbackEnabled=true;socket.send('capture_started');
    capture.port.onmessage=event=>{
      if(generation!==micGeneration||!ready||socket.readyState!==WebSocket.OPEN)return;
      if(socket.bufferedAmount>64000){void finish('audio_backpressure');return;}
      socket.send(event.data);
    };
    input.connect(capture);capture.connect(audio.destination);
    stream.getTracks().forEach(t=>t.onended=()=>{void finish('capture_ended');});
    $('capture').textContent='麦克风采集中 · 正在上传百炼 · 本机不保存音频';$('mic').textContent='关闭麦克风';
  }catch{next?.getTracks().forEach(t=>t.stop());await stopMic();message('无法采集麦克风，请检查浏览器权限和输入设备');}
  finally{micBusy=false;buttons();}
};
$('interrupt').onclick=()=>{cancelPlayback();socket?.send('interrupt');};
$('grant').onclick=async()=>{cancelPlayback();try{await post('/grant');}catch(error){message(error.message);}};
$('stop').onclick=async()=>{cancelPlayback();socket?.send('interrupt');try{await post('/stop');$('receipt').textContent='已请求停止，旧模型动作已撤销';}catch(error){message(error.message);}};
$('report').onclick=async()=>{
  try{const value=await post('/report');$('reportStatus').textContent=`已保存到 reports/voice-probe-live.json：收到 ${value.report.counts.output_audio_chunks||0} 个音频片段，成功执行 ${value.report.counts.accepted_tools||0} 次模拟工具调用。`;}catch(error){$('reportStatus').textContent=error.message;}
};
function draw(state){
  $('gain').textContent=`${Math.round((state.gain_target||0)*100)}%`;
  $('lease').textContent=`${Math.ceil((state.remaining_ms||0)/1000)} 秒`;
  $('phase').textContent=({playing:'模拟播放中',authorized:'已授权',ready:'待授权',stopped:'已停止',disconnected:'未连接'})[state.phase]||state.phase;
  points.push(state.output?.[0]||0);if(points.length>180)points.shift();
  const canvas=$('wave'),ctx=canvas.getContext('2d');ctx.clearRect(0,0,canvas.width,canvas.height);
  ctx.strokeStyle='#177e79';ctx.lineWidth=3;ctx.beginPath();points.forEach((n,i)=>{const x=i*canvas.width/179,y=110-n*300;i?ctx.lineTo(x,y):ctx.moveTo(x,y);});ctx.stroke();
}
function transcript(event){
  const li=document.createElement('li');li.textContent=`${event.speaker==='user'?'你':'AI'}：${String(event.text||'').slice(0,4000)}`;
  $('transcripts').append(li);while($('transcripts').children.length>40)$('transcripts').firstChild.remove();
  li.scrollIntoView({block:'nearest'});
}
try{
  const boot=await fetch('/bootstrap').then(r=>r.json());token=boot.token;credentialsReady=boot.credentials_ready===true;
  socket=new WebSocket(`ws://${location.host}/ws?token=${encodeURIComponent(token)}`);
  socket.onopen=()=>{message(credentialsReady?'本机临时配置仍有效 · 点击重新连接即可':'本机验证服务就绪 · 请填写 API Host 和新密钥');buttons();};
  socket.onmessage=event=>{
    try{
      const value=JSON.parse(event.data);
      if(typeof value.credentials_ready==='boolean')credentialsReady=value.credentials_ready;
      if(value.type==='state'){ready=value.ready;if(value.status!==lastStatus){lastStatus=value.status;message(value.status);}buttons();draw(value);}
      else if(value.type==='audio')play(value.data);
      else if(value.type==='interrupt')cancelPlayback();
      else if(value.type==='transcript')transcript(value);
      else if(value.type==='speech')$('capture').textContent=value.active?'正在听你说话 · 音频上传中':'等待 AI 回复 · 音频上传中';
      else if(value.type==='receipt')$('receipt').textContent=value.ok?(value.action==='stop'?'模型停止成功：模拟输出已归零，需重新授权':`模型动作成功：${value.action}，目标强度 ${Math.round(value.gain_target*100)}%（仅模拟）`):`模型动作未执行：${value.error}`;
      else if(value.type==='closed'){ready=false;playbackEnabled=false;cancelPlayback();void stopMic();lastStatus=value.message;message(value.message);}
    }catch{void finish('playback_error');}
  };
  socket.onclose=()=>{ready=false;playbackEnabled=false;cancelPlayback();void stopMic();message('本机连接已断开，请刷新页面');buttons();};
  socket.onerror=()=>message('无法连接本机验证服务');
  setInterval(()=>{if(socket.readyState===WebSocket.OPEN)socket.send('heartbeat');},1000);
}catch{message('本机验证服务不可用，请重新运行启动脚本');}
document.addEventListener('visibilitychange',()=>{if(document.hidden && (ready||micBusy)){void pauseCapture();}});
window.addEventListener('pagehide',()=>{stream?.getTracks().forEach(t=>t.stop());socket?.close();});
