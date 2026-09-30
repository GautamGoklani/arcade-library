/* ============================================================
 * PULSE — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="pulse.css">
 *   <div id="game"></div>
 *   <script src="pulse.js"><\/script>
 *   <script>
 *     var game = Pulse.mount(document.getElementById('game'));
 *     // game.restart(); game.destroy(); game.getState();
 *   <\/script>
 *
 * Host page should include (for mobile):
 *   <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
 *
 * Self-contained by design: no imports, no shared modules with any other game
 * in this repo, no network requests at runtime. The engine is embedded below
 * as base64 and everything it needs — sprites, sound, DOM — is in this file.
 *
 * THE SOUNDTRACK IS NOT SCHEDULED HERE. The engine owns the tempo, the bar and
 * the step counter; this file diffs `get_steps()` like any other event counter
 * and plays a note when it moves. See createSound() and pollEvents().
 * ============================================================ */
(function (global) {
  'use strict';

  // ---- constants: MUST match the memory layout in game.wat ----
  var WORLD_W = 960, WORLD_H = 720;
  var BAR_OFF = 0, BAR_STRIDE = 4;
  var ENEMIES_OFF = 64, ENEMY_STRIDE = 32, MAX_ENEMIES = 32;
  var BOLTS_OFF = 1088, BOLT_STRIDE = 24, MAX_BOLTS = 24;
  var CHIMES_OFF = 1664, CHIME_STRIDE = 12, MAX_CHIMES = 8;
  // Field positions inside each record — bytes for a bar step, f32 slots for
  // the rest — the `@fields` lines in game.wat, copied. Every read goes through
  // this table rather than a bare `f32[a + 5]`, so scripts/check-layout.mjs can
  // see a field that moved.
  var FIELD = {
    bar: { seg: 0, kind: 1, spent: 2, lead: 3 },
    enemy: { seg: 0, depth: 1, hp: 2, maxHp: 3, kind: 4, active: 5, flash: 6, hopT: 7 },
    bolt: { seg: 0, depth: 1, dmg: 2, active: 3, onBeat: 4, speed: 5 },
    chime: { seg: 0, depth: 1, active: 2 },
  };
  var LOW_SCALE = 3;   // 320x240 buffer, blown up — see asteroid-miner.js

  // Tube geometry, in world units. Not in the engine: the engine works in a
  // segment index and a depth of 0..1, and how big the tube is on screen is a
  // drawing decision it has no opinion about.
  var CX = 480, CY = 352, R_IN = 46, R_OUT = 292;

  var WASM_B64 = "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";

  // Palette. No glow anywhere — brightness is a brighter colour.
  // The tube has to read at 320x240 through a scanline overlay and a vignette,
  // which is three chances to lose a dark line. The first pass used the same
  // #2a1f4a as the canvas border and the spokes simply were not there.
  var TUBE = '#463473';
  var TUBE_LIT = '#8a6ad8';
  var RIM = '#e0cbff';
  var KIND_COL = ['#6ee7ff', '#7cff9a', '#ffb02e', '#ff8bd0'];
  var KIND_DARK = ['#1d5a70', '#2a6b3a', '#7a5410', '#7a3a60'];
  // The conductor: white-gold, the one warm light inside the tube. Every
  // other creature is a colour of the bar ring; this one is what plays it.
  var COND_COL = '#fff0b8', COND_DARK = '#8a6a1c', COND_HURT = '#ffb02e';
  // The lead line: a pale mint no creature wears, so its ring and its chimes
  // read as a second voice rather than as more of the first.
  var LEAD_COL = '#b8ffe0', LEAD_DARK = '#2f7a62';

  function base64ToBytes(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  // ============================================================
  // SOUND — the instrument.
  //
  // The engine is the sequencer. It counts sixteenth notes and decides what
  // spawns on which of them; this file is told "a step happened, and it was
  // step 6 of the bar, and something spawned on segment 9" and turns that into
  // a kick, a hat and a bass note.
  //
  // Nothing is scheduled ahead. A conventional Web Audio sequencer looks a
  // second into the future and books notes against the audio clock, which is
  // the right way to build a music app and the wrong way to build this: the
  // moment the music is booked ahead, it is a second out of step with a
  // simulation that can be paused, restarted or slowed by a stuttering frame,
  // and the note stops being the same event as the spawn. What is traded for
  // that is up to a frame of jitter — 16ms at 60fps, against a sixteenth note
  // of 156ms at the opening tempo. It is audible if you listen for it and it
  // is worth it, because a player timing a shot to what they hear is timing it
  // to what the engine actually did.
  // ============================================================
  function createSound() {
    var ctx = null, muted = false, master = null;

    function ensure() {
      if (ctx) return ctx;
      var AC = global.AudioContext || global.webkitAudioContext;
      if (!AC) return null;
      ctx = new AC();
      master = ctx.createGain();
      master.gain.value = 0.9;
      master.connect(ctx.destination);
      return ctx;
    }

    function osc(freq, freq2, dur, type, gain, delay) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended') c.resume();
      var t0 = c.currentTime + (delay || 0);
      var o = c.createOscillator(), g = c.createGain();
      o.type = type || 'square';
      o.frequency.setValueAtTime(freq, t0);
      if (freq2 !== freq) o.frequency.exponentialRampToValueAtTime(Math.max(1, freq2), t0 + dur);
      g.gain.setValueAtTime(gain, t0);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      o.connect(g); g.connect(master);
      o.start(t0); o.stop(t0 + dur);
    }

    function noise(dur, gain, hp) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended') c.resume();
      var n = Math.max(1, Math.floor(c.sampleRate * dur));
      var buf = c.createBuffer(1, n, c.sampleRate);
      var d = buf.getChannelData(0);
      for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n);
      var src = c.createBufferSource(), g = c.createGain();
      src.buffer = buf;
      g.gain.setValueAtTime(gain, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + dur);
      if (hp) {
        var f = c.createBiquadFilter();
        f.type = 'highpass';
        f.frequency.value = hp;
        src.connect(f); f.connect(g);
      } else {
        src.connect(g);
      }
      g.connect(master);
      src.start();
    }

    // A minor pentatonic, two octaves, so the bass line cannot land on a wrong
    // note however the pattern comes out. Twelve segments map onto ten
    // degrees, which is why the top two wrap — a tube has no top or bottom.
    var SCALE = [110.0, 130.81, 146.83, 164.81, 196.0,
                 220.0, 261.63, 293.66, 329.63, 392.0];

    return {
      // one sixteenth of the track
      step: function (stepIdx) {
        if (stepIdx % 4 === 0) {
          osc(150, 44, 0.13, 'sine', 0.16);                 // kick
        } else if (stepIdx % 8 === 4) {
          noise(0.11, 0.075, 1400);                          // snare
        }
        // a closed hat on every sixteenth, quiet enough to be the floor
        noise(0.022, stepIdx % 2 === 0 ? 0.022 : 0.012, 6500);
      },
      // a spawn: the bass note says which segment it came out on
      spawn: function (seg, kind) {
        var f = SCALE[seg % SCALE.length];
        osc(f, f, 0.17, kind === 2 ? 'sawtooth' : 'triangle', 0.075);
      },
      onbeat: function (n) { osc(660 + (n % 4) * 110, 1320, 0.05, 'square', 0.035); },
      offbeat: function () { osc(190, 120, 0.07, 'square', 0.03); },
      kill: function (n) {
        var f = SCALE[(n * 3) % SCALE.length] * 2;
        osc(f, f * 1.5, 0.09, 'triangle', 0.05);
      },
      perfect: function () {
        osc(261.63, 261.63, 0.34, 'triangle', 0.05);
        osc(392.0, 392.0, 0.34, 'triangle', 0.045, 0.04);
        osc(523.25, 523.25, 0.34, 'triangle', 0.04, 0.08);
      },
      leak: function () { noise(0.3, 0.1, 200); osc(90, 40, 0.34, 'sawtooth', 0.08); },
      // The build-up: a note on every sixteenth, climbing the bar, so the
      // drop is heard coming for a whole bar before it lands.
      riser: function (stepIdx) {
        var f = 220 * Math.pow(2, stepIdx / 12);
        osc(f, f * 1.02, 0.08, 'sawtooth', 0.02 + stepIdx * 0.002);
      },
      drop: function () {
        osc(80, 30, 0.6, 'sine', 0.22);
        noise(0.45, 0.12, 120);
        osc(220, 110, 0.5, 'sawtooth', 0.06);
      },
      condHit: function () { osc(880, 1760, 0.07, 'square', 0.04); },
      condDown: function () {
        noise(0.5, 0.12, 300);
        osc(261.63, 523.25, 0.5, 'triangle', 0.06);
        osc(392.0, 783.99, 0.5, 'triangle', 0.05, 0.06);
        osc(523.25, 1046.5, 0.6, 'triangle', 0.045, 0.12);
      },
      // The lead: a bell two octaves above the bass, on the segment's degree,
      // so the melody walks the same scale the spawns do and cannot clash.
      lead: function (seg) {
        var f = SCALE[seg % SCALE.length] * 4;
        osc(f, f, 0.28, 'sine', 0.05);
        osc(f * 2, f * 2, 0.12, 'sine', 0.015);
      },
      chime: function (seg) {
        var f = SCALE[seg % SCALE.length] * 4;
        osc(f, f * 1.5, 0.16, 'triangle', 0.05);
      },
      slam: function () { noise(0.5, 0.16, 80); osc(70, 25, 0.6, 'sawtooth', 0.1); },
      over: function () { osc(220, 36, 1.1, 'sawtooth', 0.09); },
      setMuted: function (m) { muted = m; },
      close: function () { if (ctx && ctx.close) { try { ctx.close(); } catch (e) {} } ctx = null; },
    };
  }

  // ============================================================
  // MOUNT
  // ============================================================
  function mount(container, opts) {
    opts = opts || {};
    if (typeof container === 'string') container = document.querySelector(container);
    if (!container) throw new Error('Pulse.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'pl-root';
    root.innerHTML =
      '<div class="pl-hud">' +
        '<span>SCORE <b class="pl-a" data-pl="score">0</b></span>' +
        '<span class="pl-gauge">SHIELD <span class="pl-bar pl-shield" data-pl="shbar"><i data-pl="shield"></i></span></span>' +
        '<span class="pl-gauge">GROOVE <span class="pl-bar pl-groove"><i data-pl="groove"></i></span></span>' +
        '<span>x<b class="pl-a" data-pl="mult">1.0</b></span>' +
        '<span class="pl-c" data-pl="bpm">96 BPM</span>' +
        '<button type="button" class="pl-mute" data-pl="mute">SOUND ON</button>' +
        '<button type="button" class="pl-mute pl-pause" data-pl="pause">PAUSE</button>' +
        '<button type="button" class="pl-mute pl-diff" data-pl="diff">NORMAL</button>' +
      '</div>' +
      '<div class="pl-stage">' +
        '<canvas class="pl-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="pl-touch" aria-hidden="true">' +
          '<div class="pl-tap pl-tap-left" data-pl="tapL">&#8634;</div>' +
          '<div class="pl-tap pl-tap-right" data-pl="tapR">&#8635;</div>' +
          '<div class="pl-fire" data-pl="tapF">FIRE</div>' +
        '</div>' +
        '<div class="pl-scan" aria-hidden="true"></div>' +
        '<div class="pl-overlay pl-note" data-pl="note"></div>' +
        '<div class="pl-overlay pl-msg" data-pl="msg">SILENCE<small data-pl="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="pl-overlay pl-msg pl-paused" data-pl="paused">PAUSED<small data-pl="pausedsmall">PRESS P TO RESUME</small></div>' +
      '</div>' +
      '<div class="pl-help" data-pl="help">' +
        '[&larr;][&rarr;] ROTATE &nbsp; [SPACE] FIRE — ON THE EIGHTH NOTE IT HITS THREE TIMES AS HARD ' +
        '&nbsp; [P] PAUSE &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-pl="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;

    var hudScore = q('score'), hudMult = q('mult'), hudBpm = q('bpm');
    var shBar = q('shbar'), shFill = q('shield'), grFill = q('groove');
    var msgEl = q('msg'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute');
    var tapL = q('tapL'), tapR = q('tapR'), tapF = q('tapF');

    function enableTouchUI() {
      if (root.classList.contains('pl-is-touch')) return;
      root.classList.add('pl-is-touch');
      helpEl.textContent =
        'TAP A SIDE TO ROTATE • TAP FIRE ON THE BEAT — IN TIME IT HITS THREE TIMES AS HARD • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
      q('pausedsmall').textContent = 'TAP TO RESUME';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null, u8 = null;
    var destroyed = false, paused = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    // Which setting the next run asks for. Only the choice lives here; what a
    // setting does is the table at the top of game.wat — which here means a
    // different arrangement of the song, since the engine is the sequencer.
    var DIFFICULTIES = ['easy', 'normal', 'hard'];
    var difficulty = DIFFICULTIES.indexOf(opts.difficulty);
    if (difficulty < 0) difficulty = 1;
    var keys = { left: false, right: false, fire: false };
    // Gamepad, read once a frame rather than listened for: the Gamepad API only
    // refreshes its snapshots when getGamepads() is called, so a listener would
    // report whatever frame it happened to fire on. Rebuilt every poll, so
    // nothing latches the way a missed keyup can.
    var PAD_DEADZONE = 0.5;    // rotation is one segment at a time, like the keys
    var pad = { left: false, right: false, fire: false };
    var padPrev = { pause: false, restart: false, mute: false };
    var tap = { left: false, right: false, fire: false };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0, beatFlash = 0;
    var prevSteps = 0, prevSpawns = 0, prevShots = 0, prevBeatShots = 0;
    var prevKills = 0, prevLeaks = 0, prevPerfects = 0, prevOver = 0;
    var noteT = 0, noteText = '';
    var prevDrops = 0, prevCondHits = 0, prevCondKills = 0, prevSlams = 0, prevChimes = 0;
    // Where the conductor was last drawn, so its fall has somewhere to burst:
    // by the frame the counter says so, it has left the pool.
    var condX = 480, condY = 352;

    // ---------- input ----------
    var KEY_MAP = {
      ArrowLeft: 'left', a: 'left', A: 'left',
      ArrowRight: 'right', d: 'right', D: 'right',
      ' ': 'fire',
    };

    function onKeyDown(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = true; e.preventDefault(); return; }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
      // A held key auto-repeats, and a toggle on every repeat would flicker.
      if ((e.key === 'p' || e.key === 'P' || e.key === 'Escape') && !e.repeat) {
        setPaused(!paused);
        e.preventDefault();
      }
    }
    function onKeyUp(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = false; e.preventDefault(); }
    }
    function releaseAll() {
      keys.left = keys.right = keys.fire = false;
      tap.left = tap.right = tap.fire = false;
      tapL.classList.remove('pl-active');
      tapR.classList.remove('pl-active');
      tapF.classList.remove('pl-active');
    }

    function bindTap(el, side) {
      el.addEventListener('pointerdown', function (e) {
        if (e.pointerType === 'mouse') return;   // a mouse plays with the keyboard
        enableTouchUI();
        tap[side] = true;
        el.classList.add('pl-active');
        if (el.setPointerCapture) { try { el.setPointerCapture(e.pointerId); } catch (err) {} }
        e.preventDefault();
      });
      var up = function (e) {
        if (e && e.pointerType === 'mouse') return;
        tap[side] = false;
        el.classList.remove('pl-active');
      };
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
      el.addEventListener('pointerleave', up);
    }
    bindTap(tapL, 'left');
    bindTap(tapR, 'right');
    bindTap(tapF, 'fire');

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);
    // Losing focus also pauses: whoever alt-tabbed away was not planning to come
    // back to a bar still playing and enemies still climbing.
    function onBlur() { releaseAll(); setPaused(true); }
    global.addEventListener('blur', onBlur);

    // ---------- pause ----------
    // Pause lives here and not in the engine, because it is a decision about the
    // clock rather than about the game: the engine advances by whatever dt it is
    // handed, so pausing is the loop no longer calling step(). The loop keeps
    // drawing, so the frozen tube stays on screen.
    //
    // This title is the one where that matters most. The engine *is* the
    // sequencer — it owns the tempo, the bar and the step counter, and the
    // widget plays notes off them — so stopping step() stops the music dead,
    // with nothing queued to flush and nothing to resynchronise on the way back
    // in. That is exactly the property chapter 22 argues for.
    var stage = root.querySelector('.pl-stage');
    var pausedEl = q('paused'), pauseBtn = q('pause');
    function setPaused(on) {
      if (!wasm) return;
      if (on && wasm.exports.is_game_over()) return;   // nothing to pause once it has fallen silent
      paused = on;
      pausedEl.style.display = on ? 'block' : 'none';
      pauseBtn.textContent = on ? 'RESUME' : 'PAUSE';
      // Anything held when play stopped must not still be held when it resumes:
      // the same latch releaseAll() exists to prevent on blur.
      if (on) releaseAll();
    }
    pauseBtn.addEventListener('click', function () { setPaused(!paused); pauseBtn.blur(); });

    // ---------- difficulty ----------
    // The button cycles EASY -> NORMAL -> HARD and starts a fresh run at once,
    // because a score that was half Easy and half Hard is a number no
    // best-score list could file — and because the tempo is part of the
    // setting, so changing it mid-song would be heard as a lurch.
    var diffBtn = q('diff');
    diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
    diffBtn.addEventListener('click', function () {
      difficulty = (difficulty + 1) % DIFFICULTIES.length;
      diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
      restart();
      diffBtn.blur();
    });
    // Paused, a press anywhere on the tube resumes and does nothing else: the
    // tap zones cover the stage, so a tap meant to unpause would otherwise also
    // rotate or fire.
    stage.addEventListener('pointerdown', function (e) {
      if (!paused) return;
      e.preventDefault();
      e.stopPropagation();
      setPaused(false);
    }, true);

    // ---------- gamepad ----------
    // Standard mapping, and both a face button and a trigger for fire, so a pad
    // with worn triggers still plays: left stick or d-pad rotates, A / X / either
    // trigger fires, Start pauses, Back or Y restarts, a shoulder button mutes.
    // Rotation is digital, because the tube turns one segment at a time.
    function pollGamepad() {
      pad.left = false; pad.right = false; pad.fire = false;
      var nav = global.navigator;
      var pads = nav && nav.getGamepads ? nav.getGamepads() : null;
      if (!pads) return;
      var p = null, i;
      for (i = 0; i < pads.length; i++) if (pads[i] && pads[i].connected) { p = pads[i]; break; }
      if (!p) return;

      var buttons = p.buttons || [], axes = p.axes || [];
      // A trigger reports an analog value and may never set `pressed`.
      var btn = function (n) { var b = buttons[n]; return !!(b && (b.pressed || b.value > 0.5)); };
      var ax = axes[0] || 0;
      pad.left = ax < -PAD_DEADZONE || btn(14);
      pad.right = ax > PAD_DEADZONE || btn(15);
      pad.fire = btn(0) || btn(2) || btn(6) || btn(7);

      var pausePress = btn(9), restartPress = btn(8) || btn(3), mutePress = btn(4) || btn(5);
      if (pausePress && !padPrev.pause) setPaused(!paused);
      if (restartPress && !padPrev.restart) restart();
      if (mutePress && !padPrev.mute) toggleMute();
      padPrev.pause = pausePress; padPrev.restart = restartPress; padPrev.mute = mutePress;
    }
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });
    msgEl.addEventListener('click', function () { restart(); });

    // ---------- particles ----------
    function burst(x, y, n, color, speed) {
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2;
        var v = speed * (0.3 + Math.random() * 0.9);
        particles.push({
          x: x, y: y, vx: Math.cos(a) * v, vy: Math.sin(a) * v,
          life: 0.22 + Math.random() * 0.35, age: 0, color: color,
        });
      }
      if (particles.length > 300) particles.splice(0, particles.length - 300);
    }

    function stepParticles(dt) {
      for (var i = particles.length - 1; i >= 0; i--) {
        var p = particles[i];
        p.age += dt;
        if (p.age >= p.life) { particles.splice(i, 1); continue; }
        p.x += p.vx * dt; p.y += p.vy * dt;
        p.vx *= 0.94; p.vy *= 0.94;
        g.globalAlpha = 1 - p.age / p.life;
        g.fillStyle = p.color;
        g.fillRect(snap(p.x) - LOW_SCALE, snap(p.y) - LOW_SCALE, LOW_SCALE * 2, LOW_SCALE * 2);
      }
      g.globalAlpha = 1;
    }

    // ---------- drawing ----------
    function snap(v) { return Math.round(v / LOW_SCALE) * LOW_SCALE; }

    var segs = 12;                        // replaced from the engine on boot
    function segAngle(seg) { return (seg + 0.5) / segs * Math.PI * 2 - Math.PI / 2; }
    function pos(seg, depth, out) {
      var a = segAngle(seg);
      var r = R_IN + (R_OUT - R_IN) * depth;
      out[0] = CX + Math.cos(a) * r;
      out[1] = CY + Math.sin(a) * r;
      return out;
    }
    var P = [0, 0], P2 = [0, 0];

    function dot(x, y, size, color) {
      g.fillStyle = color;
      var s = size * LOW_SCALE;
      g.fillRect(snap(x) - s, snap(y) - s, s * 2, s * 2);
    }

    function radial(seg, d0, d1, width, color) {
      // a segment spoke, drawn as a run of dots — a line on a 320x240 grid is
      // a run of pixels anyway, and doing it explicitly keeps it on the grid
      var steps = Math.max(2, Math.round((d1 - d0) * 34));
      g.fillStyle = color;
      for (var i = 0; i <= steps; i++) {
        pos(seg, d0 + (d1 - d0) * (i / steps), P);
        g.fillRect(snap(P[0]) - width, snap(P[1]) - width, width * 2, width * 2);
      }
    }

    function ring(depth, width, color, skip) {
      var a = segAngle(0);
      var r = R_IN + (R_OUT - R_IN) * depth;
      var steps = Math.max(20, Math.round(r * 0.42));
      g.fillStyle = color;
      for (var i = 0; i < steps; i++) {
        if (skip && (i % skip)) continue;
        var t = (i / steps) * Math.PI * 2;
        g.fillRect(snap(CX + Math.cos(t) * r) - width, snap(CY + Math.sin(t) * r) - width,
                   width * 2, width * 2);
      }
    }

    /**
     * The tube: twelve spokes and a few depth rings, breathing on the engine's
     * step phase. The swell is not decoration — it is the metronome. A player
     * who is looking at the board rather than at the HUD still has to be able
     * to see where the beat is, and the whole picture pulsing is the only
     * signal big enough to catch out of the corner of an eye.
     */
    function drawTube() {
      var e = wasm.exports;
      var phase = e.get_step_phase();
      var step = e.get_step_idx();
      // quarter notes swell hardest, eighths less, sixteenths barely
      var strength = (step % 4 === 0) ? 1 : (step % 2 === 0 ? 0.5 : 0.2);
      var swell = (1 - phase) * strength;

      g.fillStyle = '#0b0818';
      g.fillRect(0, 0, WORLD_W, WORLD_H);

      var lit = swell > 0.45;
      for (var s = 0; s < segs; s++) {
        radial(s, 0, 1, LOW_SCALE / 3, s === e.get_seg() ? TUBE_LIT : TUBE);
      }
      ring(0, LOW_SCALE / 3, lit ? TUBE_LIT : TUBE, 0);
      ring(0.25, LOW_SCALE / 3, TUBE, 3);
      ring(0.55, LOW_SCALE / 3, TUBE, 3);
      ring(0.8, LOW_SCALE / 3, TUBE, 2);
      // The rim is the line being defended, so it is the brightest thing on
      // the board that is not a creature.
      ring(1, LOW_SCALE / 2 + (swell > 0.6 ? LOW_SCALE / 3 : 0), lit ? RIM : '#a78ae0', 0);
    }

    /**
     * The bar plan, as sixteen ticks outside the rim, read straight out of the
     * engine's memory. This is the one thing the widget looks at *ahead* of
     * the simulation: the pattern for the coming bar is already decided, so
     * showing it turns the track from something you react to into something
     * you can read — which is the difference between a rhythm game and a
     * whack-a-mole with a soundtrack.
     */
    function drawBarRing() {
      var e = wasm.exports;
      var n = e.get_steps_per_bar();
      var here = e.get_step_idx();
      // Far enough out to be clearly a separate thing from the rim, and drawn
      // large: at R_OUT+26 with one-pixel dots the whole ring vanished into
      // the rim at any sensible display size, which is a HUD element nobody
      // can read.
      var r = R_OUT + 38;
      var dropping = e.get_drop_state() === 2;
      for (var i = 0; i < n; i++) {
        var a = (i / n) * Math.PI * 2 - Math.PI / 2;
        var x = CX + Math.cos(a) * r, y = CY + Math.sin(a) * r;
        var cell = BAR_OFF + i * BAR_STRIDE;
        var seg = u8[cell + FIELD.bar.seg];
        var kindCol = KIND_COL[u8[cell + FIELD.bar.kind] & 3];
        var strong = (i % 4 === 0);
        if (seg !== 0) {
          dot(x, y, strong ? 2.4 : 1.8, kindCol);
          // During the drop every note on the ring is one the conductor will
          // step to, so the ring is its route — ringed in its colour.
          if (dropping) {
            g.fillStyle = COND_COL;
            var rr = (strong ? 3.4 : 2.8) * LOW_SCALE;
            for (var k = 0; k < 8; k++) {
              var tt = (k / 8) * Math.PI * 2;
              g.fillRect(snap(x + Math.cos(tt) * rr), snap(y + Math.sin(tt) * rr), LOW_SCALE, LOW_SCALE);
            }
          }
        } else {
          // Empty steps still have to be *there*. At the first pass they were
          // #241a3e on #0b0818 and the ring read as four amber dots floating in
          // nothing rather than as sixteen positions, three of which were full.
          dot(x, y, strong ? 1.6 : 1.0, strong ? '#7a63b0' : '#4a3a75');
        }
        // The lead line's ring, outside the bass ring: a mint tick where the
        // phrase has a note, nothing where it does not — two rings are two
        // lines, which is what the player is reading.
        var ld = u8[cell + FIELD.bar.lead];
        if (ld !== 0) {
          var lx = CX + Math.cos(a) * (r + 18), ly = CY + Math.sin(a) * (r + 18);
          dot(lx, ly, i === here ? 2.2 : 1.5, LEAD_COL);
        }
        if (i === here) {
          // the playhead
          dot(x, y, 3.2, '#ffffff');
          dot(x, y, 1.8, seg !== 0 ? kindCol : '#c9a6ff');
        }
      }
    }

    function drawEnemies() {
      for (var i = 0; i < MAX_ENEMIES; i++) {
        var a = (ENEMIES_OFF + i * ENEMY_STRIDE) >> 2;
        var E = FIELD.enemy;
        if (f32[a + E.active] <= 0) continue;
        var seg = f32[a + E.seg] | 0, depth = f32[a + E.depth];
        var kind = f32[a + E.kind] | 0, hp = f32[a + E.hp], maxHp = f32[a + E.maxHp];
        var flash = f32[a + E.flash];
        pos(seg, depth, P);
        if (kind === 4) { drawConductor(seg, depth, hp, maxHp, flash); continue; }
        // a wedge that grows as it climbs, so "nearly at the rim" is legible
        // from the size as well as from the position
        var size = 1.1 + depth * 1.9;
        if (flash > 0 && Math.sin(flash * 120) > 0) {
          dot(P[0], P[1], size + 0.6, '#ffffff');
        } else {
          dot(P[0], P[1], size, KIND_COL[kind]);
          dot(P[0], P[1], size * 0.5, KIND_DARK[kind]);
        }
        // a mirror wears a ring, because "off-beat shots do nothing" has to be
        // visible before the player wastes three of them finding out
        if (kind === 3) {
          g.fillStyle = '#ff8bd0';
          var rr = (size + 1.4) * LOW_SCALE;
          for (var k = 0; k < 10; k++) {
            var t = (k / 10) * Math.PI * 2 + tGlobal * 2;
            g.fillRect(snap(P[0] + Math.cos(t) * rr), snap(P[1] + Math.sin(t) * rr),
                       LOW_SCALE, LOW_SCALE);
          }
        }
        if (hp < maxHp) {
          g.fillStyle = '#ff5470';
          g.fillRect(snap(P[0]) - LOW_SCALE * 3, snap(P[1]) - (size + 1.6) * LOW_SCALE,
                     Math.round(6 * (1 - hp / maxHp)) * LOW_SCALE, LOW_SCALE);
        }
      }
    }

    /**
     * The conductor: a band across the whole width of its segment, not a dot,
     * because it is the one thing in the tube you are meant to line up on and
     * hold. Its health is the band itself, burning down from both ends, so
     * there is no separate bar to look away to.
     */
    function drawConductor(seg, depth, hp, maxHp, flash) {
      var frac = Math.max(0, hp / maxHp);
      var hit = flash > 0 && Math.sin(flash * 120) > 0;
      var r = R_IN + (R_OUT - R_IN) * depth;
      var a0 = seg / segs * Math.PI * 2 - Math.PI / 2;
      var a1 = (seg + 1) / segs * Math.PI * 2 - Math.PI / 2;
      var mid = (a0 + a1) / 2, half = (a1 - a0) / 2 * 0.92;
      var n = 14;
      for (var band = -1; band <= 1; band++) {
        var rb = r + band * LOW_SCALE * 1.5;
        for (var i = 0; i <= n; i++) {
          var u = i / n * 2 - 1;                       // -1..1 across the segment
          var t = mid + u * half;
          var lit = Math.abs(u) <= frac;
          g.fillStyle = hit ? '#ffffff' : (lit ? (band === 0 ? COND_COL : COND_DARK) : '#2a2140');
          g.fillRect(snap(CX + Math.cos(t) * rb) - LOW_SCALE, snap(CY + Math.sin(t) * rb) - LOW_SCALE,
                     LOW_SCALE * 2, LOW_SCALE * 2);
        }
      }
      // a baton: a spoke up from the band toward the rim, so which way it
      // faces — at you — is never in doubt
      radial(seg, depth + 0.03, depth + 0.1, LOW_SCALE / 2, frac > 0.3 ? COND_COL : COND_HURT);
      pos(seg, depth, P);
      condX = P[0]; condY = P[1];
    }

    // Chimes: a mint diamond climbing its segment a quarter-tube a step. In
    // the last quarter it is lit, because that is when it lands — on the next
    // beat — and where you need to be.
    function drawChimes() {
      for (var i = 0; i < MAX_CHIMES; i++) {
        var a = (CHIMES_OFF + i * CHIME_STRIDE) >> 2;
        var C = FIELD.chime;
        if (f32[a + C.active] <= 0) continue;
        var seg = f32[a + C.seg] | 0;
        // eased between steps with the step phase, so it glides rather than
        // teleports — the engine moves it on the step, the picture follows
        var d = Math.min(1, f32[a + C.depth] + wasm.exports.get_step_phase() * 0.25);
        pos(seg, d, P);
        var landing = f32[a + C.depth] >= 0.7;
        var sz = (1 + d * 1.4) * LOW_SCALE;
        g.fillStyle = landing ? '#ffffff' : LEAD_COL;
        g.fillRect(snap(P[0]) - sz, snap(P[1]) - LOW_SCALE, sz * 2, LOW_SCALE * 2);
        g.fillRect(snap(P[0]) - LOW_SCALE, snap(P[1]) - sz, LOW_SCALE * 2, sz * 2);
        if (landing) {
          // mark the rim where it will land
          pos(seg, 1, P2);
          dot(P2[0], P2[1], 1.2, LEAD_DARK);
        }
      }
    }

    function drawBolts() {
      for (var i = 0; i < MAX_BOLTS; i++) {
        var a = (BOLTS_OFF + i * BOLT_STRIDE) >> 2;
        var B = FIELD.bolt;
        if (f32[a + B.active] <= 0) continue;
        var onBeat = f32[a + B.onBeat] !== 0;
        var seg = f32[a + B.seg] | 0, depth = f32[a + B.depth];
        pos(seg, depth, P);
        pos(seg, Math.min(1, depth + (onBeat ? 0.09 : 0.05)), P2);
        var col = onBeat ? '#fff3c4' : '#7b6aa0';
        g.fillStyle = col;
        var n = 5;
        for (var s = 0; s <= n; s++) {
          g.fillRect(snap(P[0] + (P2[0] - P[0]) * (s / n)) - LOW_SCALE / 2,
                     snap(P[1] + (P2[1] - P[1]) * (s / n)) - LOW_SCALE / 2,
                     LOW_SCALE, LOW_SCALE);
        }
      }
    }

    function drawPlayer() {
      var e = wasm.exports;
      var seg = e.get_seg();
      // The claw sits just outside the rim and spans its segment, so which
      // twelfth of the ring is yours is unambiguous.
      var a0 = seg / segs * Math.PI * 2 - Math.PI / 2;
      var a1 = (seg + 1) / segs * Math.PI * 2 - Math.PI / 2;
      var ready = e.get_fire_cd() <= 0;
      g.fillStyle = ready ? '#ffd166' : '#8a7030';
      for (var i = 0; i <= 10; i++) {
        var t = a0 + (a1 - a0) * (i / 10);
        g.fillRect(snap(CX + Math.cos(t) * (R_OUT + 8)) - LOW_SCALE,
                   snap(CY + Math.sin(t) * (R_OUT + 8)) - LOW_SCALE,
                   LOW_SCALE * 2, LOW_SCALE * 2);
      }
      pos(seg, 1, P);
      dot(P[0], P[1], 2.2, ready ? '#fff3c4' : '#a08850');
    }

    // ---------- engine events ----------
    function pollEvents() {
      var e = wasm.exports;

      // ---- the track ----
      // One note per sixteenth. If a frame was long enough to swallow more
      // than one step the engine will have fired both, and both are played —
      // a bar with a hole in it is worse than two notes close together.
      var st = e.get_steps();
      if (st > prevSteps) {
        var n = Math.min(4, st - prevSteps);
        for (var i = 0; i < n; i++) sound.step(e.get_step_idx());
        if (e.get_step_idx() >= 0) {
          var lcell = BAR_OFF + e.get_step_idx() * BAR_STRIDE;
          var lseg = u8[lcell + FIELD.bar.lead];
          if (lseg !== 0) sound.lead(lseg - 1);
        }
        if (e.get_drop_state() === 1) {
          sound.riser(e.get_step_idx());
          if (e.get_step_idx() % 4 === 0) { noteText = 'DROP IN ' + (4 - e.get_step_idx() / 4); noteT = 0.5; }
        }
        beatFlash = (e.get_step_idx() % 4 === 0) ? 0.34 : 0.16;
        prevSteps = st;
      }

      var sp = e.get_spawns();
      if (sp > prevSpawns) {
        // the bar plan still holds what just spawned, at the current step
        var cell = BAR_OFF + e.get_step_idx() * BAR_STRIDE;
        var seg = u8[cell + FIELD.bar.seg];
        if (seg !== 0) sound.spawn(seg - 1, u8[cell + FIELD.bar.kind] & 3);
        prevSpawns = sp;
      }

      // ---- the player ----
      var sh = e.get_shots(), bs = e.get_beat_shots();
      if (sh > prevShots) {
        if (bs > prevBeatShots) sound.onbeat(bs);
        else sound.offbeat();
        prevShots = sh; prevBeatShots = bs;
      }

      var k = e.get_kills();
      if (k > prevKills) {
        sound.kill(k);
        pos(e.get_seg(), 0.5, P);
        burst(P[0], P[1], 6, '#ffffff', 130);
        prevKills = k;
      }

      var lk = e.get_leaks();
      if (lk > prevLeaks) {
        sound.leak();
        shake = Math.max(shake, 0.5);
        flash = 0.5;
        prevLeaks = lk;
      }

      var pf = e.get_perfects();
      if (pf > prevPerfects) {
        sound.perfect();
        noteText = 'PERFECT BAR';
        noteT = 0.9;
        prevPerfects = pf;
      }

      // ---- the drop ----
      // After the perfect-bar check on purpose: the build-up is usually a
      // clean bar, so both land on the same barline, and the drop is the news.
      var dr = e.get_drops();
      if (dr > prevDrops) {
        sound.drop();
        shake = Math.max(shake, 0.6);
        beatFlash = 0.6;
        noteText = 'THE DROP';
        noteT = 1.2;
        prevDrops = dr;
      }
      var cm = e.get_chimes();
      if (cm > prevChimes) {
        sound.chime(e.get_seg());
        pos(e.get_seg(), 1, P);
        burst(P[0], P[1], 8, LEAD_COL, 120);
        prevChimes = cm;
      }

      var ch = e.get_cond_hits();
      if (ch > prevCondHits) { sound.condHit(); prevCondHits = ch; }
      var ck = e.get_cond_kills();
      if (ck > prevCondKills) {
        sound.condDown();
        shake = Math.max(shake, 0.7);
        burst(condX, condY, 26, COND_COL, 220);
        noteText = 'CONDUCTOR DOWN';
        noteT = 1.4;
        prevCondKills = ck;
      }
      var sl = e.get_slams();
      if (sl > prevSlams) {
        sound.slam();
        shake = Math.max(shake, 0.9);
        flash = 0.7;
        noteText = 'THE DROP ENDS';
        noteT = 1.2;
        prevSlams = sl;
      }

      var over = e.is_game_over();
      if (over && !prevOver) { sound.over(); msgEl.style.display = 'block'; }
      prevOver = over;
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      // Before the pause gate: Start has to be able to unpause, and Back to
      // restart from the game-over screen.
      pollGamepad();
      var dt = Math.max(0, Math.min((now - lastT) / 1000, 0.05));
      lastT = now;
      // Paused stops the animation clock too, so the ring, the particles and the
      // shake hold still with the bar instead of playing on over it. lastT still
      // advances, so the first frame back is one frame long.
      if (paused) dt = 0;
      tGlobal += dt;

      if (!paused) {
        var move = ((keys.right || tap.right || pad.right) ? 1 : 0) -
                   ((keys.left || tap.left || pad.left) ? 1 : 0);
        wasm.exports.set_input(move, (keys.fire || tap.fire || pad.fire) ? 1 : 0);
        wasm.exports.step(dt);
        pollEvents();
      }

      var Z = 1 / LOW_SCALE;
      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (shake > 0) {
        var m = shake * 4;
        g.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m),
          Math.round((Math.random() * 2 - 1) * m));
        shake = Math.max(0, shake - dt * 1.9);
      }

      drawTube();
      drawBarRing();
      drawBolts();
      drawEnemies();
      drawChimes();
      drawPlayer();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (beatFlash > 0) {
        g.fillStyle = 'rgba(201,166,255,' + (beatFlash * 0.11).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        beatFlash = Math.max(0, beatFlash - dt * 3.4);
      }
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.6).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.9);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      // HUD
      var e = wasm.exports;
      hudScore.textContent = Math.round(e.get_score());
      hudMult.textContent = e.get_mult().toFixed(1);
      hudBpm.textContent = Math.round(e.get_bpm()) + ' BPM';
      var sf = e.get_shield() / e.get_shield_max();
      shFill.style.width = Math.max(0, sf * 100) + '%';
      shBar.classList.toggle('pl-crit', sf <= 0.3);
      grFill.style.width = (e.get_groove() * 100) + '%';

      noteT -= dt;
      if (noteT > 0) { noteEl.textContent = noteText; noteEl.style.opacity = '1'; }
      else noteEl.style.opacity = '0';

      rafId = requestAnimationFrame(loop);
    }

    function restart() {
      if (!wasm) return;
      // set_difficulty only records the choice; init() is what applies it
      wasm.exports.set_difficulty(difficulty);
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      u8 = new Uint8Array(wasm.exports.memory.buffer);
      // The markup says 96 BPM, which is Normal's floor. Ask the engine, so an
      // Easy or Hard run does not show Normal's tempo until the first frame.
      hudBpm.textContent = Math.round(wasm.exports.get_bpm()) + ' BPM';
      segs = wasm.exports.get_segments();
      particles.length = 0;
      shake = 0; flash = 0; beatFlash = 0; noteT = 0;
      releaseAll();
      prevSteps = wasm.exports.get_steps();
      prevSpawns = wasm.exports.get_spawns();
      prevShots = wasm.exports.get_shots();
      prevBeatShots = wasm.exports.get_beat_shots();
      prevKills = wasm.exports.get_kills();
      prevLeaks = wasm.exports.get_leaks();
      prevPerfects = wasm.exports.get_perfects();
      prevDrops = wasm.exports.get_drops();
      prevCondHits = wasm.exports.get_cond_hits();
      prevCondKills = wasm.exports.get_cond_kills();
      prevSlams = wasm.exports.get_slams();
      prevChimes = wasm.exports.get_chimes();
      prevOver = 0;
      msgEl.style.display = 'none';
      setPaused(false);
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) { return WebAssembly.instantiate(buf, {}); });
    } else {
      // No imports: the tube is twelve segments and a depth, so nothing in the
      // engine turns through an angle.
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), {});
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="pl-fail">Failed to load game engine: ' + err + '</div>';
    });

    // ---------- public API ----------
    return {
      restart: restart,
      destroy: function () {
        destroyed = true;
        cancelAnimationFrame(rafId);
        global.removeEventListener('keydown', onKeyDown);
        global.removeEventListener('keyup', onKeyUp);
        global.removeEventListener('blur', onBlur);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          shield: wasm.exports.get_shield(),
          groove: wasm.exports.get_groove(),
          multiplier: wasm.exports.get_mult(),
          bpm: wasm.exports.get_bpm(),
          level: wasm.exports.get_level(),
          bar: wasm.exports.get_bar(),
          onBeatShots: wasm.exports.get_beat_shots(),
          shots: wasm.exports.get_shots(),
          gameOver: !!wasm.exports.is_game_over(),
          paused: paused,
          difficulty: DIFFICULTIES[wasm.exports.get_difficulty()],
        };
      },
    };
  }

  global.Pulse = { mount: mount };

})(window);
