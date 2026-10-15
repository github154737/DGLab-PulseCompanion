// A continuous mono box-filter resampler, preserving phase across worklet blocks.
class PcmCapture extends AudioWorkletProcessor {
  constructor() { super(); this.sum=0; this.weight=0; this.position=0; this.buffer=[]; }
  process(inputs) {
    const channel=inputs[0]?.[0];
    if (!channel) return true;
    const ratio=sampleRate/16000;
    for (const sample of channel) {
      let remaining=1;
      while (remaining>1e-8) {
        const part=Math.min(remaining,ratio-this.position);
        this.sum+=sample*part; this.weight+=part; this.position+=part; remaining-=part;
        if (this.position>=ratio-1e-8) {
          const v=Math.max(-1,Math.min(1,this.sum/this.weight));
          this.buffer.push(Math.round(v*(v<0?32768:32767)));
          this.sum=0;this.weight=0;this.position=0;
          if(this.buffer.length===640){
            const bytes=new ArrayBuffer(1280),view=new DataView(bytes);
            this.buffer.forEach((n,i)=>view.setInt16(i*2,n,true));
            this.port.postMessage(bytes,[bytes]);this.buffer=[];
          }
        }
      }
    }
    return true;
  }
}
registerProcessor('pcm-capture',PcmCapture);
