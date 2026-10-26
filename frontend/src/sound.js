// Quiet lounge music and soft sound effects, synthesised with Web Audio:
// no audio files, nothing fetched. An eight-bar loop at 68 bpm — FM
// electric piano chords, a round bass, brushes and a sparse vibraphone
// line — played through a generated room reverb.
//
// Browsers only allow sound after a user gesture, so nothing plays until
// the first click, tap or key press; the two header toggles remember
// their state per browser.

const PREFS_KEY = "connect-four-audio";
const BPM = 68;
const BEAT = 60 / BPM;
const SWING = 0.6; // share of a beat the first eighth takes

// Eight bars: Dm9 G13 Cmaj9 Am9 Fmaj9 Em7 Dm9 G13sus.
const PROGRESSION = [
  { bass: 38, fifth: 45, chord: [53, 57, 60, 64] },
  { bass: 43, fifth: 38, chord: [53, 59, 64, 69] },
  { bass: 36, fifth: 43, chord: [52, 55, 59, 62] },
  { bass: 45, fifth: 40, chord: [55, 59, 60, 64] },
  { bass: 41, fifth: 48, chord: [57, 60, 64, 67] },
  { bass: 40, fifth: 47, chord: [55, 59, 62, 64] },
  { bass: 38, fifth: 45, chord: [53, 57, 60, 64] },
  { bass: 43, fifth: 38, chord: [53, 57, 60, 65] },
];

const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);

function loadPrefs() {
  try {
    const p = JSON.parse(localStorage.getItem(PREFS_KEY) ?? "{}");
    return { music: p.music !== false, sfx: p.sfx !== false };
  } catch {
    return { music: true, sfx: true };
  }
}

function savePrefs(p) {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(p));
  } catch {
    // Private mode or blocked storage: the toggles still work for this visit.
  }
}

export function createSound() {
  const prefs = loadPrefs();
  let ctx = null;
  let musicBus, sfxBus, keysBus, noise;
  let timer = null;
  let nextTime = 0;
  let step = 0;
  let playing = false;
  const listeners = new Set();
  const notify = () => listeners.forEach((fn) => fn({ ...prefs, playing }));

  function build() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return false;
    ctx = new AC();

    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -18;
    comp.ratio.value = 3;
    comp.connect(ctx.destination);

    // A generated room: decaying, darkened stereo noise.
    const len = Math.floor(ctx.sampleRate * 3);
    const ir = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = ir.getChannelData(ch);
      let lp = 0;
      for (let i = 0; i < len; i++) {
        lp += 0.35 * (Math.random() * 2 - 1 - lp);
        d[i] = lp * Math.pow(1 - i / len, 3.4);
      }
    }
    const reverb = ctx.createConvolver();
    reverb.buffer = ir;
    const wet = ctx.createGain();
    wet.gain.value = 0.9;
    reverb.connect(wet).connect(comp);

    musicBus = ctx.createGain();
    musicBus.gain.value = 0;
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.frequency.value = 4800;
    musicBus.connect(tone).connect(comp);
    const musicSend = ctx.createGain();
    musicSend.gain.value = 0.34;
    tone.connect(musicSend).connect(reverb);

    // The electric piano's own bus: a slow tremolo and a gentle autopan.
    keysBus = ctx.createGain();
    keysBus.gain.value = 0.85;
    const trem = ctx.createOscillator();
    trem.frequency.value = 4.2;
    const tremDepth = ctx.createGain();
    tremDepth.gain.value = 0.12;
    trem.connect(tremDepth).connect(keysBus.gain);
    trem.start();
    if (ctx.createStereoPanner) {
      const pan = ctx.createStereoPanner();
      const panLfo = ctx.createOscillator();
      panLfo.frequency.value = 0.17;
      const panDepth = ctx.createGain();
      panDepth.gain.value = 0.35;
      panLfo.connect(panDepth).connect(pan.pan);
      panLfo.start();
      keysBus.connect(pan).connect(musicBus);
    } else keysBus.connect(musicBus);

    sfxBus = ctx.createGain();
    sfxBus.gain.value = prefs.sfx ? 0.8 : 0;
    sfxBus.connect(comp);
    const sfxSend = ctx.createGain();
    sfxSend.gain.value = 0.2;
    sfxBus.connect(sfxSend).connect(reverb);

    noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
    const nd = noise.getChannelData(0);
    for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) ctx.suspend();
      else if (playing || prefs.sfx) ctx.resume();
    });
    return true;
  }

  function env(gain, t, peak, attack, decay) {
    gain.gain.setValueAtTime(0.0001, t);
    gain.gain.linearRampToValueAtTime(peak, t + attack);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
  }

  function osc(type, freq, t, stop) {
    const o = ctx.createOscillator();
    o.type = type;
    o.frequency.value = freq;
    o.start(t);
    o.stop(stop);
    return o;
  }

  // ── voices ────────────────────────────────────────────────────────────
  function epiano(t, midi, vel, dur) {
    const f = mtof(midi);
    const out = ctx.createGain();
    out.gain.setValueAtTime(0.0001, t);
    out.gain.linearRampToValueAtTime(0.11 * vel, t + 0.012);
    out.gain.exponentialRampToValueAtTime(0.05 * vel, t + 0.6);
    out.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    const car = osc("sine", f, t, t + dur + 0.05);
    const mod = osc("sine", f, t, t + dur + 0.05);
    const index = ctx.createGain();
    index.gain.setValueAtTime(f * 1.2 * vel, t);
    index.gain.exponentialRampToValueAtTime(f * 0.06, t + 0.9);
    mod.connect(index).connect(car.frequency);
    const tine = osc("sine", f * 4.01, t, t + 0.5);
    const tineGain = ctx.createGain();
    env(tineGain, t, 0.035 * vel, 0.004, 0.35);
    car.connect(out);
    tine.connect(tineGain).connect(out);
    out.connect(keysBus);
  }

  function bass(t, midi, dur, vel = 1) {
    const f = mtof(midi);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(0.3 * vel, t + 0.015);
    g.gain.exponentialRampToValueAtTime(0.12 * vel, t + 0.25);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.value = 480;
    osc("triangle", f, t, t + dur + 0.05).connect(lp);
    osc("sine", f, t, t + dur + 0.05).connect(g);
    lp.connect(g).connect(musicBus);
  }

  function noiseHit(t, { type, freq, q = 0.7, peak, attack, decay, bus }) {
    const src = ctx.createBufferSource();
    src.buffer = noise;
    const filter = ctx.createBiquadFilter();
    filter.type = type;
    filter.frequency.value = freq;
    filter.Q.value = q;
    const g = ctx.createGain();
    env(g, t, peak, attack, decay);
    src.connect(filter).connect(g).connect(bus);
    src.start(t, Math.random() * 0.5);
    src.stop(t + attack + decay + 0.05);
  }

  function vibe(t, midi, vel, bus = musicBus) {
    const f = mtof(midi);
    const g = ctx.createGain();
    env(g, t, 0.07 * vel, 0.004, 1.9);
    const am = ctx.createGain();
    am.gain.value = 1;
    const lfo = osc("sine", 5.2, t, t + 2);
    const depth = ctx.createGain();
    depth.gain.value = 0.25;
    lfo.connect(depth).connect(am.gain);
    osc("sine", f, t, t + 2).connect(am);
    const partial = ctx.createGain();
    env(partial, t, 0.25, 0.003, 0.4);
    osc("sine", f * 3.93, t, t + 0.5).connect(partial).connect(am);
    am.connect(g).connect(bus);
  }

  // ── the sequencer: one swung eighth at a time ────────────────────────
  let phrase = [];

  function playStep(s, t) {
    const barNo = Math.floor(s / 8);
    const bar = PROGRESSION[barNo % PROGRESSION.length];
    const next = PROGRESSION[(barNo + 1) % PROGRESSION.length];
    const pos = s % 8;
    const r = Math.random();
    if (pos === 0) {
      bar.chord.forEach((m, k) => epiano(t + k * 0.022, m, 0.7 + Math.random() * 0.15, BEAT * 4.4));
      bass(t, bar.bass, BEAT * 1.9);
      // A melody on the middle two bars of every four.
      phrase = [];
      if (barNo % 4 === 1 || barNo % 4 === 2) {
        const tones = [...bar.chord.map((m) => m + 12), bar.chord[0] + 14].sort((a, b) => a - b);
        let at = Math.floor(Math.random() * 3);
        let idx = Math.floor(Math.random() * tones.length);
        for (let n = 0; n < 2 + Math.floor(Math.random() * 2) && at < 8; n++) {
          phrase.push({ pos: at, midi: tones[idx] });
          at += 2 + Math.floor(Math.random() * 3);
          idx = Math.max(0, Math.min(tones.length - 1, idx + (Math.random() < 0.5 ? -1 : 1)));
        }
      }
    }
    if (pos === 3 && r < 0.5) {
      bar.chord.slice(2).forEach((m, k) => epiano(t + k * 0.02, m, 0.38, BEAT * 1.6));
    }
    if (pos === 4) bass(t, bar.fifth, BEAT * 1.7, 0.85);
    if (pos === 7 && r < 0.4) bass(t, next.bass + (Math.random() < 0.5 ? 1 : -1), BEAT * 0.45, 0.6);
    if (pos === 2 || pos === 6) {
      noiseHit(t, { type: "bandpass", freq: 2600, q: 0.5, peak: 0.035, attack: 0.04, decay: 0.28, bus: musicBus });
    }
    if ([0, 2, 3, 4, 6, 7].includes(pos)) {
      const soft = pos === 3 || pos === 7 ? 0.55 : 1;
      noiseHit(t, { type: "highpass", freq: 7500, peak: 0.012 * soft, attack: 0.002, decay: 0.09, bus: musicBus });
    }
    for (const note of phrase) if (note.pos === pos) vibe(t + 0.01, note.midi, 0.8 + Math.random() * 0.2);
  }

  function schedule() {
    while (nextTime < ctx.currentTime + 0.3) {
      playStep(step, nextTime);
      nextTime += BEAT * (step % 2 === 0 ? SWING : 1 - SWING);
      step++;
    }
  }

  function startMusic() {
    if (!ctx || playing) return;
    playing = true;
    nextTime = ctx.currentTime + 0.15;
    step = 0;
    const g = musicBus.gain;
    g.cancelScheduledValues(ctx.currentTime);
    g.setValueAtTime(g.value, ctx.currentTime);
    g.linearRampToValueAtTime(0.5, ctx.currentTime + 3);
    timer = setInterval(schedule, 60);
    schedule();
    notify();
  }

  function stopMusic() {
    if (!ctx || !playing) return;
    playing = false;
    const g = musicBus.gain;
    g.cancelScheduledValues(ctx.currentTime);
    g.setValueAtTime(g.value, ctx.currentTime);
    g.linearRampToValueAtTime(0, ctx.currentTime + 1.2);
    const t = timer;
    setTimeout(() => clearInterval(t), 1300);
    timer = null;
    notify();
  }

  const ready = () => ctx !== null && ctx.state === "running";

  return {
    prefs,
    subscribe(fn) {
      listeners.add(fn);
      fn({ ...prefs, playing });
    },
    /// Call from a user gesture: creates or resumes the audio context.
    unlock() {
      if (!ctx && !build()) return;
      if (ctx.state === "suspended") ctx.resume();
      if (prefs.music) startMusic();
    },
    setMusic(on) {
      prefs.music = on;
      savePrefs(prefs);
      if (on) this.unlock();
      else stopMusic();
      notify();
    },
    setSfx(on) {
      prefs.sfx = on;
      savePrefs(prefs);
      if (on) this.unlock();
      if (sfxBus) sfxBus.gain.setTargetAtTime(on ? 0.8 : 0, ctx.currentTime, 0.05);
      notify();
    },

    /// A disc landing: a short knock, a plastic click, a little ring.
    clack(strength) {
      if (!prefs.sfx || !ready()) return;
      const t = ctx.currentTime;
      const s = Math.max(0.05, Math.min(1, strength));
      const body = osc("sine", 300 + 90 * s, t, t + 0.15);
      body.frequency.exponentialRampToValueAtTime(130, t + 0.08);
      const g = ctx.createGain();
      env(g, t, 0.3 * s, 0.002, 0.12);
      body.connect(g).connect(sfxBus);
      noiseHit(t, { type: "bandpass", freq: 2300, q: 1.4, peak: 0.2 * s, attack: 0.001, decay: 0.045, bus: sfxBus });
      const ring = ctx.createGain();
      env(ring, t, 0.03 * s, 0.002, 0.09);
      osc("sine", 1640, t, t + 0.12).connect(ring);
      osc("sine", 2290, t, t + 0.12).connect(ring);
      ring.connect(sfxBus);
    },
    /// Aiming at another column.
    tick() {
      if (!prefs.sfx || !ready()) return;
      const t = ctx.currentTime;
      const g = ctx.createGain();
      env(g, t, 0.018, 0.002, 0.04);
      osc("sine", 980, t, t + 0.06).connect(g).connect(sfxBus);
    },
    /// The slider pulling out and the discs tumbling into the tray.
    release() {
      if (!prefs.sfx || !ready()) return;
      const t = ctx.currentTime;
      noiseHit(t + 0.05, { type: "lowpass", freq: 900, peak: 0.07, attack: 0.15, decay: 0.45, bus: sfxBus });
      for (let i = 0; i < 9; i++) {
        const at = 0.6 + Math.random() * 0.7;
        setTimeout(() => this.clack(0.12 + Math.random() * 0.18), at * 1000);
      }
    },
    /// "win" | "lose" | "draw", once per finished game.
    outcome(kind) {
      if (!prefs.sfx || !ready()) return;
      const t = ctx.currentTime + 0.25;
      const notes = { win: [72, 76, 79, 83, 86], lose: [69, 64, 60], draw: [67, 72, 74] }[kind] ?? [];
      const gap = kind === "win" ? 0.11 : 0.22;
      notes.forEach((m, k) => vibe(t + k * gap, m, kind === "win" ? 0.9 : 0.6, sfxBus));
    },
  };
}
