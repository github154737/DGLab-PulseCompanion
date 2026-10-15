const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {test} = require('node:test');
const source = fs.readFileSync(`${__dirname}/pcm-worklet.js`, 'utf8');

for (const rate of [16000, 44100, 48000]) {
  test(`continuous PCM resampling at ${rate} Hz preserves duration across blocks`, () => {
    const packets=[];let Processor;
    const context={sampleRate:rate,AudioWorkletProcessor:class{constructor(){this.port={postMessage:b=>packets.push(b)}}},registerProcessor:(_,p)=>{Processor=p}};
    vm.runInNewContext(source,context);
    const capture=new Processor();
    const input=new Float32Array(rate*2).fill(0.25);
    for(let offset=0;offset<input.length;offset+=128)capture.process([[input.subarray(offset,offset+128)]]);
    assert.equal(packets.length,50);
    assert.equal(packets.reduce((n,b)=>n+b.byteLength,0),64000);
    for(const packet of packets){
      assert.equal(packet.byteLength,1280);
      const view=new DataView(packet);
      for(let i=0;i<packet.byteLength;i+=2)assert.equal(view.getInt16(i,true),8192);
    }
  });
}
test('PCM saturation prevents wraparound and quiet inputs produce zero',()=>{
  const packets=[];let Processor;
  vm.runInNewContext(source,{sampleRate:16000,AudioWorkletProcessor:class{constructor(){this.port={postMessage:b=>packets.push(b)}}},registerProcessor:(_,p)=>{Processor=p}});
  const capture=new Processor();
  for(const value of [-2,0,2])capture.process([[new Float32Array(640).fill(value)]]);
  assert.deepEqual(packets.map(b=>new DataView(b).getInt16(0,true)),[-32768,0,32767]);
});
