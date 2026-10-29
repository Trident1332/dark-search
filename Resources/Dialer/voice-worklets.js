/* Ottocaller — AudioWorklet processors for the Mac voice path (driven by macvoice.js).
 *
 *   mac-capture  hands every microphone frame (mono float32, 128 samples at the context rate)
 *                to the page, which packs it into 20 ms int16 packets for the voice service.
 *                Its output is silence: it only exists so the node stays in the graph.
 *   mac-player   plays the int16 blocks the service sends back from a small queue and fills
 *                with silence when the queue runs dry. If the queue ever backs up (a stall on the
 *                service side), it drops the oldest audio so the delay never creeps up. */
class MacCapture extends AudioWorkletProcessor {
  process(inputs) {
    var ch = inputs[0] && inputs[0][0];
    if (ch && ch.length) this.port.postMessage(ch.slice(0));   // the buffer is reused by the engine: copy
    return true;
  }
}

class MacPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.q = []; this.head = 0; this.queued = 0; this.underruns = 0; this.dropped = 0;
    this.maxQueue = Math.round(sampleRate * 0.45);  // 450 ms: more than that queued means we are late (the service's blocks arrive with some jitter)
    this.trimAbove = Math.round(sampleRate * 0.2); this.trimmed = 0;
    this.prebuffer = Math.round(sampleRate * 0.12); this.waiting = true;   // 120 ms
    var self = this;
    this.port.onmessage = function (e) {
      var d = e.data;
      if (d === "flush") { self.q = []; self.head = 0; self.queued = 0; self.waiting = true; return; }
      if (d === "stats") { self.port.postMessage({ queued_ms: Math.round(1000 * self.queued / sampleRate), underruns: self.underruns, dropped_ms: Math.round(1000 * self.dropped / sampleRate), trimmed_ms: Math.round(1000 * self.trimmed / sampleRate) }); return; }
      var i16 = new Int16Array(d), f = new Float32Array(i16.length), silent = true;
      for (var i = 0; i < i16.length; i++) { f[i] = i16[i] / 32768; if (i16[i]) silent = false; }
      f.silent = silent;
      // A block of pure silence (the service's gate) is dropped rather than queued while more than 200 ms is
      // already waiting: the delay heals itself in every pause without anyone hearing a cut.
      if (silent && self.queued > self.trimAbove) { self.trimmed += f.length; return; }
      self.q.push(f); self.queued += f.length;
      while (self.queued > self.maxQueue && self.q.length > 1) {   // late: skip the oldest block
        var old = self.q.shift(); self.queued -= old.length - self.head; self.dropped += old.length - self.head; self.head = 0;
      }
    };
  }
  process(inputs, outputs) {
    var out = outputs[0][0]; if (!out) return true;
    // Jitter buffer: after running dry, wait until PREBUFFER ms are queued before playing again, so one late
    // block from the service costs a slightly longer pause instead of a gap in the middle of a word.
    if (this.waiting) { if (this.queued < this.prebuffer) { out.fill(0); return true; } this.waiting = false; }
    var i = 0;
    while (i < out.length && this.q.length) {
      var cur = this.q[0], n = Math.min(out.length - i, cur.length - this.head);
      out.set(cur.subarray(this.head, this.head + n), i);
      i += n; this.head += n; this.queued -= n;
      if (this.head >= cur.length) { this.q.shift(); this.head = 0; }
    }
    if (i < out.length) { if (i === 0) this.underruns++; out.fill(0, i); this.waiting = true; }
    return true;
  }
}

registerProcessor("mac-capture", MacCapture);
registerProcessor("mac-player", MacPlayer);
