/* ============================================================
 * CIRCUIT RUNNER — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="circuit-runner.css">
 *   <div id="game"></div>
 *   <script src="circuit-runner.js"><\/script>
 *   <script>
 *     var game = CircuitRunner.mount(document.getElementById('game'));
 *     // game.restart(); game.destroy(); game.getState();
 *   <\/script>
 *
 * Host page should include (for mobile):
 *   <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
 *
 * Self-contained by design: no imports, no shared modules with any other game
 * in this repo, no network requests at runtime. The engine is embedded below
 * as base64 and everything it needs — sprites, sound, DOM — is in this file.
 * ============================================================ */
(function (global) {
  'use strict';

  // ---- constants: MUST match the memory layout in game.wat ----
  var WORLD_W = 960, WORLD_H = 720;
  var RUNNER_OFF = 0;
  var PARTS_OFF = 24, PART_STRIDE = 32, MAX_PARTS = 24;
  var PICKUPS_OFF = 792, PICKUP_STRIDE = 24, MAX_PICKUPS = 20;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[a + 4]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    runner: { x: 0, lane: 1, targetLane: 2, stun: 3, alive: 4 },
    part: { x: 0, y: 1, lane: 2, kind: 3, active: 4, span: 5, timer: 6, charged: 7 },
    pickup: { x: 0, y: 1, lane: 2, kind: 3, active: 4, phase: 5 },
  };
  var PART_HALF_H = 30;
  var PXS = 3;         // chunky pixel scale for the ASCII sprites
  var LOW_SCALE = 3;   // 320x240 buffer, blown up — see asteroid-miner.js

  var WASM_B64 = "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";

  // ============================================================
  // PIXEL SPRITES (ASCII grids -> offscreen canvases)
  // Each character is one pixel; '.' is transparent. Every row of a sprite
  // must be the same length.
  //
  // Only the fixed-size things are sprites. The components are drawn
  // procedurally, because a part is 1 or 2 lanes wide and an ASCII grid has
  // one width — two hand-drawn variants of the same resistor would be two
  // things to keep looking alike, and the shapes are rectangles with bands and
  // pins, which is exactly what fillRect is for. Everything still lands on the
  // low-res grid, so it is the same picture either way.
  // ============================================================
  function makeSprite(rows, palette, px) {
    var w = rows[0].length, h = rows.length;
    var cv = document.createElement('canvas');
    cv.width = w * px; cv.height = h * px;
    var c = cv.getContext('2d');
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var ch = rows[y][x];
        if (ch === '.') continue;
        c.fillStyle = palette[ch];
        c.fillRect(x * px, y * px, px, px);
      }
    }
    return cv;
  }

  // The runner: a charge carrier riding the trace. Reads as an arrowhead so
  // "which way is forward" is never in question on a board that scrolls.
  var RUNNER_PAL = { W: '#e8fff4', C: '#6ee7a8', G: '#2b9c67', D: '#0d3a26', Y: '#ffd166' };
  var runnerRows = [
    '......YY......',
    '.....YWWY.....',
    '....YWCCWY....',
    '...CWCCCCWC...',
    '..CCCCCCCCCC..',
    '.CCCGGCCGGCCC.',
    'CCCGGGCCGGGCCC',
    'CCGGDDCCDDGGCC',
    'CGGDD.CC.DDGGC',
    'CGGD...CC..DGC',
    '.GG.........G.',
    '.G...........G',
    '..D.........D.',
    '...D.......D..',
  ];

  var CHARGE_PAL = { W: '#ffffff', Y: '#ffd166', O: '#e08a12' };
  var chargeRows = [
    '....YY..',
    '...YWY..',
    '..YWWY..',
    '.YWWYYYY',
    'YYYYWWY.',
    '..OYWY..',
    '..OYY...',
    '..OO....',
  ];

  var BOOST_PAL = { W: '#ffffff', B: '#7cc7ff', D: '#1f5f8f' };
  var boostRows = [
    '.BBBBBB.',
    'BWWWWWWB',
    'BWBBBBWB',
    'BWBWWBWB',
    'BWBWWBWB',
    'BWBBBBWB',
    'BWWWWWWB',
    '.BDDDDB.',
  ];

  // Board palette.
  var PCB = '#071a12';
  var TRACE = '#1d5c3c';
  var TRACE_LIT = '#2f8a58';
  var PAD = '#c08a3e';

  function base64ToBytes(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  // ============================================================
  // SOUND — synthesised, no audio files and nothing to license.
  // The AudioContext is created on the first real input, because browsers
  // refuse to start audio outside a user gesture.
  // ============================================================
  function createSound() {
    var ctx = null, muted = false;

    function ensure() {
      if (ctx) return ctx;
      var AC = global.AudioContext || global.webkitAudioContext;
      if (!AC) return null;
      ctx = new AC();
      return ctx;
    }

    function tone(freq, freq2, dur, type, gain) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended') c.resume();
      var o = c.createOscillator(), g = c.createGain();
      o.type = type || 'square';
      o.frequency.setValueAtTime(freq, c.currentTime);
      o.frequency.exponentialRampToValueAtTime(Math.max(1, freq2), c.currentTime + dur);
      g.gain.setValueAtTime(gain == null ? 0.05 : gain, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + dur);
      o.connect(g); g.connect(c.destination);
      o.start(); o.stop(c.currentTime + dur);
    }

    function noise(dur, gain) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended') c.resume();
      var n = Math.floor(c.sampleRate * dur);
      var buf = c.createBuffer(1, n, c.sampleRate);
      var d = buf.getChannelData(0);
      for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n);
      var src = c.createBufferSource(), g = c.createGain();
      src.buffer = buf;
      g.gain.setValueAtTime(gain == null ? 0.08 : gain, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + dur);
      src.connect(g); g.connect(c.destination);
      src.start();
    }

    return {
      slide:  function () { tone(420, 620, 0.05, 'square', 0.022); },
      // Charges rise a step at a time and wrap every sixth, so a clean run up
      // the board sounds like one rather than like the same blip repeated.
      charge: function (n) { tone(560 + (n % 6) * 60, 900 + (n % 6) * 60, 0.07, 'triangle', 0.05); },
      boost:  function () { tone(500, 1400, 0.26, 'triangle', 0.06); },
      hit:    function () { noise(0.3, 0.11); tone(210, 55, 0.3, 'sawtooth', 0.07); },
      over:   function () { tone(240, 45, 0.95, 'sawtooth', 0.085); },
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
    if (!container) throw new Error('CircuitRunner.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'cr-root';
    root.innerHTML =
      '<div class="cr-hud">' +
        '<span>SCORE <b class="cr-a" data-cr="score">0</b></span>' +
        '<span>DIST <b class="cr-v" data-cr="dist">0m</b></span>' +
        '<span class="cr-gauge">CURRENT <span class="cr-bar" data-cr="bar"><i data-cr="cur"></i></span></span>' +
        '<span class="cr-over" data-cr="over">OVERCLOCK x2</span>' +
        '<button type="button" class="cr-mute" data-cr="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="cr-stage">' +
        '<canvas class="cr-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="cr-touch" aria-hidden="true">' +
          '<div class="cr-tap cr-tap-left" data-cr="tapL">&#9664;</div>' +
          '<div class="cr-tap cr-tap-right" data-cr="tapR">&#9654;</div>' +
        '</div>' +
        '<div class="cr-scan" aria-hidden="true"></div>' +
        '<div class="cr-overlay cr-note" data-cr="note">CURRENT LOW</div>' +
        '<div class="cr-overlay cr-msg" data-cr="msg">POWER LOST<small data-cr="msgsmall">PRESS R TO RESTART</small></div>' +
      '</div>' +
      '<div class="cr-help" data-cr="help">' +
        '[&larr;][&rarr;] CHANGE TRACE &nbsp; COLLECT CURRENT OR IT RUNS OUT &nbsp; ' +
        '[R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-cr="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;

    var stage = root.querySelector('.cr-stage');
    var hudScore = q('score'), hudDist = q('dist');
    var curBar = q('bar'), curFill = q('cur'), overEl = q('over');
    var msgEl = q('msg'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute');
    var tapL = q('tapL'), tapR = q('tapR');

    function enableTouchUI() {
      if (root.classList.contains('cr-is-touch')) return;
      root.classList.add('cr-is-touch');
      helpEl.textContent = 'TAP A SIDE TO CHANGE TRACE • COLLECT CURRENT OR IT RUNS OUT • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var keys = { left: false, right: false };
    var tap = { left: false, right: false };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    var prevSwitches = 0, prevHits = 0, prevCharges = 0, prevBoosts = 0, prevOver = 0;
    var noteT = 0;
    // Scroll offset for the board texture, in world px, wrapped to the tile
    // height so it never grows large enough to lose float precision.
    var scroll = 0;

    // ---------- sprites ----------
    var sprRunner = makeSprite(runnerRows, RUNNER_PAL, PXS);
    var sprCharge = makeSprite(chargeRows, CHARGE_PAL, PXS);
    var sprBoost = makeSprite(boostRows, BOOST_PAL, PXS);

    // ---------- input ----------
    var KEY_MAP = {
      ArrowLeft: 'left', a: 'left', A: 'left',
      ArrowRight: 'right', d: 'right', D: 'right',
    };

    function onKeyDown(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = true; e.preventDefault(); return; }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
    }
    function onKeyUp(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = false; e.preventDefault(); }
    }

    function releaseAll() {
      keys.left = keys.right = false;
      tap.left = tap.right = false;
      tapL.classList.remove('cr-active');
      tapR.classList.remove('cr-active');
    }

    function bindTap(el, side) {
      el.addEventListener('pointerdown', function (e) {
        if (e.pointerType === 'mouse') return;   // a mouse plays with the keyboard
        enableTouchUI();
        tap[side] = true;
        el.classList.add('cr-active');
        if (el.setPointerCapture) { try { el.setPointerCapture(e.pointerId); } catch (err) {} }
        e.preventDefault();
      });
      var up = function (e) {
        if (e && e.pointerType === 'mouse') return;
        tap[side] = false;
        el.classList.remove('cr-active');
      };
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
      el.addEventListener('pointerleave', up);
    }
    bindTap(tapL, 'left');
    bindTap(tapR, 'right');

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);
    global.addEventListener('blur', releaseAll);
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });
    msgEl.addEventListener('click', function () { restart(); });

    // ---------- particles ----------
    function burst(x, y, n, color, speed) {
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2;
        var v = speed * (0.3 + Math.random() * 0.9);
        particles.push({
          x: x, y: y, vx: Math.cos(a) * v, vy: Math.sin(a) * v,
          life: 0.3 + Math.random() * 0.4, age: 0, color: color,
        });
      }
      if (particles.length > 360) particles.splice(0, particles.length - 360);
    }

    function stepParticles(dt) {
      for (var i = particles.length - 1; i >= 0; i--) {
        var p = particles[i];
        p.age += dt;
        if (p.age >= p.life) { particles.splice(i, 1); continue; }
        p.x += p.vx * dt; p.y += p.vy * dt;
        p.vx *= 0.95; p.vy *= 0.95;
        g.globalAlpha = 1 - p.age / p.life;
        g.fillStyle = p.color;
        g.fillRect(snap(p.x) - LOW_SCALE, snap(p.y) - LOW_SCALE, LOW_SCALE * 2, LOW_SCALE * 2);
      }
      g.globalAlpha = 1;
    }

    // ---------- drawing ----------
    function snap(v) { return Math.round(v / LOW_SCALE) * LOW_SCALE; }

    function drawSpriteAt(spr, x, y) {
      g.drawImage(spr, snap(x - spr.width / 2), snap(y - spr.height / 2));
    }

    /**
     * The board: six copper traces with solder pads sliding down them. The pads
     * are the only thing that conveys speed — the traces are unbroken lines, and
     * an unbroken line scrolling past looks identical at any speed.
     */
    function drawBoard() {
      var lanes = wasm.exports.get_lanes();
      var laneW = wasm.exports.get_lane_w();
      var lane = wasm.exports.get_lane();

      g.fillStyle = PCB;
      g.fillRect(0, 0, WORLD_W, WORLD_H);

      for (var l = 0; l < lanes; l++) {
        var cx = snap((l + 0.5) * laneW);
        g.fillStyle = (l === lane) ? TRACE_LIT : TRACE;
        g.fillRect(cx - LOW_SCALE * 2, 0, LOW_SCALE * 4, WORLD_H);
        // solder pads, every 120 world px
        g.fillStyle = PAD;
        for (var y = (scroll % 120) - 120; y < WORLD_H; y += 120) {
          g.fillRect(cx - LOW_SCALE * 3, snap(y), LOW_SCALE * 6, LOW_SCALE * 2);
        }
      }
    }

    function drawParts() {
      var laneW = wasm.exports.get_lane_w();
      for (var i = 0; i < MAX_PARTS; i++) {
        var a = (PARTS_OFF + i * PART_STRIDE) >> 2;
        var R = FIELD.part;
        if (f32[a + R.active] <= 0) continue;
        var x = f32[a + R.x], y = f32[a + R.y];
        var kind = f32[a + R.kind] | 0, span = f32[a + R.span] | 0;
        var hw = span * (laneW / 2) - 26;
        var l = snap(x - hw), r = snap(x + hw);
        var t = snap(y - PART_HALF_H), b = snap(y + PART_HALF_H);
        var w = r - l, h = b - t;

        if (kind === 0) {
          // Resistor: beige body, colour bands, leads out each side.
          g.fillStyle = '#8a6a3a';
          g.fillRect(l - LOW_SCALE * 3, snap(y) - LOW_SCALE, w + LOW_SCALE * 6, LOW_SCALE * 2);
          g.fillStyle = '#d8b784';
          g.fillRect(l, t + LOW_SCALE * 2, w, h - LOW_SCALE * 4);
          var bands = ['#8a3f2a', '#2b2b2b', '#c8a020'];
          for (var k = 0; k < 3; k++) {
            g.fillStyle = bands[k];
            g.fillRect(l + LOW_SCALE * (3 + k * 3), t + LOW_SCALE * 2,
                       LOW_SCALE * 2, h - LOW_SCALE * 4);
          }
        } else if (kind === 1) {
          // Capacitor: two plates, live only while charged. A discharged one is
          // drawn dark and hollow so "safe now" is legible at a glance — the
          // whole point of the kind is that it is a gate, not a wall.
          var live = f32[a + R.charged] !== 0;
          g.fillStyle = live ? '#ffe08a' : '#2a4a3c';
          g.fillRect(l, t, w, LOW_SCALE * 3);
          g.fillRect(l, b - LOW_SCALE * 3, w, LOW_SCALE * 3);
          g.fillStyle = live ? '#ffd166' : '#16281f';
          g.fillRect(l + LOW_SCALE * 2, t + LOW_SCALE * 3, w - LOW_SCALE * 4, h - LOW_SCALE * 6);
          if (live) {
            // arcing between the plates
            g.fillStyle = '#ffffff';
            for (var s = 0; s < 3; s++) {
              var ax = l + LOW_SCALE * 3 + ((Math.random() * (w - LOW_SCALE * 6)) | 0);
              g.fillRect(snap(ax), t + LOW_SCALE * 4, LOW_SCALE, h - LOW_SCALE * 8);
            }
          }
        } else if (kind === 2) {
          // Chip: black body, pins along both long edges, orientation notch.
          g.fillStyle = '#c9c9c9';
          for (var px = l + LOW_SCALE; px < r - LOW_SCALE; px += LOW_SCALE * 4) {
            g.fillRect(px, t - LOW_SCALE * 2, LOW_SCALE * 2, LOW_SCALE * 2);
            g.fillRect(px, b, LOW_SCALE * 2, LOW_SCALE * 2);
          }
          g.fillStyle = '#14161a';
          g.fillRect(l, t, w, h);
          g.fillStyle = '#3a4048';
          g.fillRect(l + LOW_SCALE, t + LOW_SCALE, w - LOW_SCALE * 2, LOW_SCALE);
          g.fillStyle = '#8a9098';
          g.fillRect(l + LOW_SCALE * 2, snap(y) - LOW_SCALE, LOW_SCALE * 2, LOW_SCALE * 2);
        } else {
          // Solder bridge: a spill of molten solder across two traces.
          g.fillStyle = '#9aa4ad';
          g.fillRect(l, t + LOW_SCALE * 2, w, h - LOW_SCALE * 4);
          g.fillStyle = '#d6dee4';
          g.fillRect(l + LOW_SCALE * 2, t + LOW_SCALE * 3, w - LOW_SCALE * 4, LOW_SCALE * 2);
          g.fillStyle = '#5c666e';
          g.fillRect(l, b - LOW_SCALE * 3, w, LOW_SCALE);
        }
      }
    }

    function drawPickups() {
      for (var i = 0; i < MAX_PICKUPS; i++) {
        var a = (PICKUPS_OFF + i * PICKUP_STRIDE) >> 2;
        var P = FIELD.pickup;
        if (f32[a + P.active] <= 0) continue;
        var kind = f32[a + P.kind] | 0;
        var bob = Math.round(Math.sin(tGlobal * 5 + f32[a + P.phase]) * 1.2) * LOW_SCALE;
        drawSpriteAt(kind === 1 ? sprBoost : sprCharge, f32[a + P.x], f32[a + P.y] + bob);
      }
    }

    function drawRunner() {
      var x = wasm.exports.get_runner_x(), y = wasm.exports.get_runner_y();
      var stun = wasm.exports.get_stun();
      // Sparking after a hit: blink, and shed sparks. The engine also makes it
      // immune for exactly this window, so the blink is honest about state.
      if (stun > 0 && Math.sin(stun * 40) < -0.1) return;
      if (wasm.exports.get_overclock() > 0) {
        g.fillStyle = 'rgba(124,199,255,0.30)';
        g.fillRect(snap(x) - LOW_SCALE * 8, 0, LOW_SCALE * 16, WORLD_H);
      }
      drawSpriteAt(sprRunner, x, y);
    }

    // ---------- engine events ----------
    function pollEvents(dt) {
      var e = wasm.exports;

      var sw = e.get_switches();
      if (sw > prevSwitches) { sound.slide(); prevSwitches = sw; }

      var ch = e.get_charges();
      if (ch > prevCharges) {
        sound.charge(ch);
        burst(e.get_runner_x(), e.get_runner_y(), 8, '#ffd166', 150);
        prevCharges = ch;
      }

      var bo = e.get_boosts();
      if (bo > prevBoosts) {
        sound.boost();
        burst(e.get_runner_x(), e.get_runner_y(), 16, '#7cc7ff', 200);
        prevBoosts = bo;
      }

      var hi = e.get_hits();
      if (hi > prevHits) {
        sound.hit();
        shake = Math.max(shake, 0.45);
        flash = 0.45;
        burst(e.get_runner_x(), e.get_runner_y(), 24, '#ff5470', 220);
        prevHits = hi;
      }

      var over = e.is_game_over();
      if (over && !prevOver) { sound.over(); msgEl.style.display = 'block'; }
      prevOver = over;
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      var dt = Math.min((now - lastT) / 1000, 0.05);
      lastT = now;
      tGlobal += dt;

      // Held left and right cancel rather than fighting, and the engine only
      // accepts a change once the previous slide has finished — so holding a
      // key walks trace by trace instead of queueing turns the player has not
      // had a chance to see the board for.
      var move = ((keys.right || tap.right) ? 1 : 0) - ((keys.left || tap.left) ? 1 : 0);
      wasm.exports.set_input(move);
      wasm.exports.step(dt);
      pollEvents(dt);

      if (!wasm.exports.is_game_over()) {
        scroll = (scroll + wasm.exports.get_speed() * dt) % 120;
      }

      var Z = 1 / LOW_SCALE;
      g.setTransform(Z, 0, 0, Z, 0, 0);

      if (shake > 0) {
        var m = shake * 4;
        g.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m),
          Math.round((Math.random() * 2 - 1) * m));
        shake = Math.max(0, shake - dt * 1.8);
      }

      drawBoard();
      drawParts();
      drawPickups();
      drawRunner();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.7).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.9);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      // HUD.
      var cur = wasm.exports.get_current(), curMax = wasm.exports.get_current_max();
      var frac = cur / curMax;
      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudDist.textContent = Math.round(wasm.exports.get_dist() / 10) + 'm';
      curFill.style.width = Math.max(0, frac * 100) + '%';
      if (frac <= 0.25) curBar.classList.add('cr-crit');
      else curBar.classList.remove('cr-crit');
      if (wasm.exports.get_overclock() > 0) overEl.classList.add('cr-on');
      else overEl.classList.remove('cr-on');

      noteT -= dt;
      if (frac <= 0.25 && !wasm.exports.is_game_over()) noteT = 0.2;
      noteEl.style.opacity = noteT > 0 ? '1' : '0';

      rafId = requestAnimationFrame(loop);
    }

    function restart() {
      if (!wasm) return;
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      particles.length = 0;
      shake = 0; flash = 0; noteT = 0; scroll = 0;
      releaseAll();
      prevSwitches = wasm.exports.get_switches();
      prevHits = wasm.exports.get_hits();
      prevCharges = wasm.exports.get_charges();
      prevBoosts = wasm.exports.get_boosts();
      prevOver = 0;
      msgEl.style.display = 'none';
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) { return WebAssembly.instantiate(buf, {}); });
    } else {
      // No imports: nothing in this engine turns through an angle.
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), {});
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="cr-fail">Failed to load game engine: ' + err + '</div>';
    });

    // ---------- public API ----------
    return {
      restart: restart,
      destroy: function () {
        destroyed = true;
        cancelAnimationFrame(rafId);
        global.removeEventListener('keydown', onKeyDown);
        global.removeEventListener('keyup', onKeyUp);
        global.removeEventListener('blur', releaseAll);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          distance: wasm.exports.get_dist(),
          current: wasm.exports.get_current(),
          speed: wasm.exports.get_speed(),
          lane: wasm.exports.get_lane(),
          overclock: wasm.exports.get_overclock(),
          gameOver: !!wasm.exports.is_game_over(),
        };
      },
    };
  }

  global.CircuitRunner = { mount: mount };

})(window);
