/* ============================================================
 * ASTEROID MINER — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="asteroid-miner.css">
 *   <div id="game"></div>
 *   <script src="asteroid-miner.js"><\/script>
 *   <script>
 *     var game = AsteroidMiner.mount(document.getElementById('game'));
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
  var SHIP_OFF = 0;
  var ROCKS_OFF = 24, ROCK_STRIDE = 32, MAX_ROCKS = 28;
  var BULLETS_OFF = 920, BULLET_STRIDE = 24, MAX_BULLETS = 24;
  var PICKUPS_OFF = 1496, PICKUP_STRIDE = 32, MAX_PICKUPS = 40;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[a + 6]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    ship: { x: 0, y: 1, vx: 2, vy: 3, heading: 4, alive: 5 },
    rock: { x: 0, y: 1, vx: 2, vy: 3, radius: 4, size: 5, active: 6, spin: 7 },
    bullet: { x: 0, y: 1, vx: 2, vy: 3, life: 4, active: 5 },
    pickup: { x: 0, y: 1, vx: 2, vy: 3, life: 4, kind: 5, active: 6, phase: 7 },
    depot: { x: 0, y: 1 },
  };
  var SHIP_R = 12;
  var PXS = 3; // chunky pixel scale for the ASCII sprites
  // The game draws into a WORLD/LOW_SCALE buffer and is blown up by this
  // factor. 3 gives a 320x240 field — a resolution an arcade cabinet of the
  // period would recognise — and makes one sprite pixel exactly PXS world px.
  var LOW_SCALE = 3;

  var WASM_B64 = "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";

  // ============================================================
  // PIXEL SPRITES (ASCII grids -> offscreen canvases)
  // Each character is one pixel; '.' is transparent. Every row of a sprite
  // must be the same length.
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

  // The ship points UP at heading 0, matching the engine's convention
  // (vx = sin h, vy = -cos h), so the canvas rotation is heading with no
  // offset to remember or get wrong.
  var SHIP_PAL = { H: '#ffd79a', B: '#ff9d2e', D: '#8a4a06', G: '#6cf0ff' };
  var shipRows = [
    '...HH...',
    '...HH...',
    '..HBBH..',
    '..HBBH..',
    '.HBBBBH.',
    'HBBGGBBH',
    'HBD..DBH',
    'D.D..D.D',
  ];

  var FLAME_PAL = { Y: '#fff2a8', O: '#ffb02e', R: '#ff5470' };
  var flameRows = [
    '.O..O.',
    'OYOOYO',
    'OYYYYO',
    '.RYYR.',
    '..RR..',
    '...R..',
  ];
  var flameRows2 = [
    '.O..O.',
    'OYOOYO',
    '.RYYR.',
    '..RR..',
    '......',
    '......',
  ];

  // One rock drawing, scaled per size. Three hand-drawn rocks would be three
  // things to keep looking like the same material.
  var ROCK_PAL = { L: '#9a8f7d', M: '#6f6658', D: '#463f35', S: '#c3b8a2' };
  var rockRows = [
    '..LLLLL...',
    '.LMMMMMLL.',
    'LMMSSMMMML',
    'LMSSSMMDML',
    'LMMSMMDDML',
    'LMMMMDDDML',
    '.LMMDDDML.',
    '..LLDDLL..',
  ];

  var GEM_PAL = { W: '#eaffff', C: '#6cf0ff', B: '#1c7f96' };
  var gemRows = [
    '..CC..',
    '.CWWC.',
    'CWWCCB',
    'CWCCBB',
    '.CBBB.',
    '..BB..',
  ];

  var CELL_PAL = { O: '#ffb02e', Y: '#ffe6a8', D: '#7a4a06' };
  var cellRows = [
    '.OOOO.',
    'OYYYYO',
    'OYDDYO',
    'OYDDYO',
    'OYYYYO',
    '.OOOO.',
  ];

  var STAR_COLORS = ['#8899bb', '#c9d6ee', '#5d6a8a'];

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
      shot:  function () { tone(720, 240, 0.07, 'square', 0.035); },
      crack: function () { noise(0.18, 0.09); tone(190, 70, 0.16, 'sawtooth', 0.04); },
      gem:   function () { tone(900, 1500, 0.07, 'triangle', 0.045); },
      cell:  function () { tone(420, 880, 0.13, 'triangle', 0.055); },
      // Each gem unloaded is one step up a scale, so a full hold sounds like a
      // full hold — the drip in $dock is what makes that possible.
      drop:  function (n) { tone(520 + (n % 8) * 55, 900 + (n % 8) * 55, 0.07, 'triangle', 0.05); },
      die:   function () { noise(0.5, 0.13); tone(300, 50, 0.6, 'sawtooth', 0.08); },
      level: function () { tone(520, 1040, 0.3, 'triangle', 0.06); },
      warn:  function () { tone(300, 220, 0.14, 'square', 0.03); },
      over:  function () { tone(240, 55, 0.9, 'sawtooth', 0.08); },
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
    if (!container) throw new Error('AsteroidMiner.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'am-root';
    root.innerHTML =
      '<div class="am-hud">' +
        '<span>SCORE <b class="am-a" data-am="score">0</b></span>' +
        '<span>SHIPS <b class="am-r" data-am="lives">4</b></span>' +
        '<span>LVL <b class="am-v" data-am="level">1</b></span>' +
        '<span class="am-gauge">FUEL <span class="am-bar" data-am="bar"><i data-am="fuel"></i></span></span>' +
        '<span>HOLD <b data-am="cargo">0/12</b></span>' +
        '<span>QUOTA <b class="am-a" data-am="quota">0/6</b></span>' +
        '<button type="button" class="am-mute" data-am="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="am-stage">' +
        '<canvas class="am-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="am-touch" aria-hidden="true">' +
          '<div class="am-stickzone" data-am="stickzone">' +
            '<div class="am-stick" data-am="stick">' +
              '<div class="am-stick-knob" data-am="knob"></div>' +
            '</div>' +
          '</div>' +
          '<div class="am-btn am-btn-thrust" data-am="btnThrust">THR</div>' +
          '<div class="am-btn am-btn-fire" data-am="btnFire">FIRE</div>' +
        '</div>' +
        '<div class="am-scan" aria-hidden="true"></div>' +
        '<div class="am-overlay am-note" data-am="note">DOCKED</div>' +
        '<div class="am-overlay am-banner" data-am="banner">LEVEL 1</div>' +
        '<div class="am-overlay am-msg" data-am="msg">GAME OVER<small data-am="msgsmall">PRESS R TO RESTART</small></div>' +
      '</div>' +
      '<div class="am-help" data-am="help">' +
        '[&larr;][&rarr;] TURN &nbsp; [&uarr;] THRUST &nbsp; [SPACE] MINE &nbsp; ' +
        'FILL THE HOLD, FLY IT HOME &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-am="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    /**
     * Everything is drawn into a 320x240 buffer and blown up 3x onto the
     * 960x720 canvas with smoothing off.
     *
     * This is the one change that makes it read as an old game rather than a
     * modern game with pixel-art sprites in it. Every mark rasterises at the
     * low resolution — a rotated rock, the depot's rings, a particle, the
     * exhaust flame — so nothing on screen can be finer than the sprites are,
     * and a rotation lands on the pixel grid instead of gliding over it.
     *
     * The draw code below still works in 960x720 world units. The 1/3
     * transform on `g` is what makes that free: no coordinate in this file
     * had to change.
     */
    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;
    var stage = root.querySelector('.am-stage');
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level');
    var hudCargo = q('cargo'), hudQuota = q('quota');
    var fuelBar = q('bar'), fuelFill = q('fuel');
    var msgEl = q('msg'), bannerEl = q('banner'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute');
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');
    var btnThrust = q('btnThrust'), btnFire = q('btnFire');

    /**
     * Which controls a visitor gets is decided per *event*, by `pointerType`,
     * not by sniffing the device at mount — the same reasoning Grid Breaker's
     * widget spells out. `(pointer: coarse)` describes the *primary* pointer,
     * so it is the right initial guess, and a first touch corrects it.
     */
    function enableTouchUI() {
      if (root.classList.contains('am-is-touch')) return;
      root.classList.add('am-is-touch');
      helpEl.textContent = 'LEFT STICK AIMS • THR TO BURN • FIRE TO MINE • FLY THE HOLD HOME • TAP GAME OVER TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var keys = { left: false, right: false, thrust: false, fire: false };
    var stick = { active: false, ox: 0, oy: 0, on: 0, ang: 0 };
    var touch = { thrust: false, fire: false };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    var prevLevel = 1, prevHits = 0, prevShots = 0, prevGrabs = 0;
    var prevFuels = 0, prevDrops = 0, prevDeaths = 0, prevOver = 0;
    var bannerT = 0, noteT = 0, warnT = 0;

    // ---------- sprites ----------
    var sprShip = makeSprite(shipRows, SHIP_PAL, PXS);
    var sprFlame = [makeSprite(flameRows, FLAME_PAL, PXS), makeSprite(flameRows2, FLAME_PAL, PXS)];
    var sprGem = makeSprite(gemRows, GEM_PAL, PXS);
    var sprCell = makeSprite(cellRows, CELL_PAL, PXS);
    // One rock bitmap per size, pre-scaled, so the frame loop never scales.
    var sprRock = [null,
      makeSprite(rockRows, ROCK_PAL, 3),
      makeSprite(rockRows, ROCK_PAL, 5),
      makeSprite(rockRows, ROCK_PAL, 9)];

    // A fixed starfield, generated once. Deterministic from a small LCG rather
    // than Math.random so a reload looks like the same sky.
    var stars = (function () {
      var out = [], seed = 20260907;
      for (var i = 0; i < 150; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        var x = (seed / 0x7fffffff) * WORLD_W;
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        var y = (seed / 0x7fffffff) * WORLD_H;
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        // Snapped to the low-res grid and sized in whole low-res pixels, so a
        // star is a star and not a grey smear straddling two of them.
        out.push({
          x: Math.round(x / LOW_SCALE) * LOW_SCALE,
          y: Math.round(y / LOW_SCALE) * LOW_SCALE,
          c: STAR_COLORS[seed % 3],
          s: (seed % 7 === 0) ? LOW_SCALE * 2 : LOW_SCALE,
        });
      }
      return out;
    })();

    // ---------- input ----------
    var KEY_MAP = {
      ArrowLeft: 'left', a: 'left', A: 'left',
      ArrowRight: 'right', d: 'right', D: 'right',
      ArrowUp: 'thrust', w: 'thrust', W: 'thrust',
      ' ': 'fire', Spacebar: 'fire',
    };

    function onKeyDown(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = true; stick.on = 0; e.preventDefault(); return; }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
    }
    function onKeyUp(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = false; e.preventDefault(); }
    }

    // A held key or a thumb still on the glass when the tab loses focus never
    // sends its release, and the ship would fly on unattended.
    function releaseAll() {
      keys.left = keys.right = keys.thrust = keys.fire = false;
      touch.thrust = touch.fire = false;
      btnThrust.classList.remove('am-active');
      btnFire.classList.remove('am-active');
      releaseStick();
    }

    function releaseStick() {
      stick.active = false;
      stick.on = 0;
      stickEl.classList.remove('am-active');
      stickEl.style.left = ''; stickEl.style.top = '';
      knobEl.style.transform = 'translate(-50%, -50%)';
    }

    function stagePoint(e) {
      var r = stage.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top, w: r.width, h: r.height };
    }

    function onStickDown(e) {
      if (e.pointerType === 'mouse') return;   // a mouse flies with the keyboard
      enableTouchUI();
      var p = stagePoint(e);
      stick.active = true;
      stick.ox = p.x; stick.oy = p.y;
      stickEl.style.left = (p.x / p.w * 100) + '%';
      stickEl.style.top = (p.y / p.h * 100) + '%';
      stickEl.classList.add('am-active');
      knobEl.style.transform = 'translate(-50%, -50%)';
      if (stickZone.setPointerCapture) {
        try { stickZone.setPointerCapture(e.pointerId); } catch (err) {}
      }
      e.preventDefault();
    }

    function onStickMove(e) {
      if (!stick.active || e.pointerType === 'mouse') return;
      var p = stagePoint(e);
      var dx = p.x - stick.ox, dy = p.y - stick.oy;
      var reach = stickEl.getBoundingClientRect().width / 2 || 40;
      var len = Math.sqrt(dx * dx + dy * dy);
      var k = len > reach ? reach / len : 1;
      knobEl.style.transform =
        'translate(calc(-50% + ' + (dx * k) + 'px), calc(-50% + ' + (dy * k) + 'px))';
      if (len < reach * 0.3) { stick.on = 0; return; }
      // The stick names a heading, in the engine's own convention: 0 is up and
      // the angle grows clockwise, which is atan2(dx, -dy) rather than the
      // usual atan2(dy, dx). The engine still turns toward it at ROT_SPEED, so
      // this is a request, not teleportation.
      stick.ang = Math.atan2(dx, -dy);
      stick.on = 1;
      e.preventDefault();
    }

    function bindButton(el, name) {
      el.addEventListener('pointerdown', function (e) {
        if (e.pointerType === 'mouse') return;
        enableTouchUI();
        touch[name] = true;
        el.classList.add('am-active');
        if (el.setPointerCapture) { try { el.setPointerCapture(e.pointerId); } catch (err) {} }
        e.preventDefault();
      });
      var up = function (e) {
        if (e && e.pointerType === 'mouse') return;
        touch[name] = false;
        el.classList.remove('am-active');
      };
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
      el.addEventListener('pointerleave', up);
    }
    bindButton(btnThrust, 'thrust');
    bindButton(btnFire, 'fire');

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    stickZone.addEventListener('pointerdown', onStickDown);
    stickZone.addEventListener('pointermove', onStickMove);
    // Named, not inline, because destroy() has to be able to take them off
    // again: an anonymous listener on window closes over the whole widget, so
    // a mounted-and-destroyed instance kept its wasm module, its sprites and
    // its particle array alive for the life of the page, and went on calling
    // releaseStick() on a stick nobody could see.
    function onWindowPointerUp() { if (stick.active) releaseStick(); }
    function onWindowPointerCancel() { releaseStick(); }
    global.addEventListener('pointerup', onWindowPointerUp);
    global.addEventListener('pointercancel', onWindowPointerCancel);
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
          life: 0.35 + Math.random() * 0.5, age: 0, color: color,
        });
      }
      if (particles.length > 420) particles.splice(0, particles.length - 420);
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
        g.fillRect(Math.round(p.x / LOW_SCALE) * LOW_SCALE - LOW_SCALE,
                   Math.round(p.y / LOW_SCALE) * LOW_SCALE - LOW_SCALE,
                   LOW_SCALE * 2, LOW_SCALE * 2);
      }
      g.globalAlpha = 1;
    }

    // ---------- drawing ----------
    /**
     * The arena wraps, so anything within `r` of an edge has to be drawn again
     * on the far side or it visibly pops through the seam. Nine placements is
     * the naive version; this is the three-by-three of offsets that actually
     * matter, filtered to the one or two that are on screen.
     */
    function drawWrapped(x, y, r, fn) {
      var ox, oy, i, j;
      for (i = -1; i <= 1; i++) {
        for (j = -1; j <= 1; j++) {
          ox = x + i * WORLD_W;
          oy = y + j * WORLD_H;
          if (ox + r < 0 || ox - r > WORLD_W || oy + r < 0 || oy - r > WORLD_H) continue;
          fn(ox, oy);
        }
      }
    }

    function drawSpriteAt(spr, x, y, ang) {
      g.save();
      g.translate(x, y);
      if (ang) g.rotate(ang);
      g.drawImage(spr, -spr.width / 2, -spr.height / 2);
      g.restore();
    }

    function drawStars() {
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        g.fillStyle = s.c;
        g.fillRect(s.x, s.y, s.s, s.s);
      }
    }

    function drawDepot() {
      var dx = wasm.exports.get_depot_x(), dy = wasm.exports.get_depot_y();
      var r = wasm.exports.get_depot_r();
      var pulse = 0.5 + 0.5 * Math.sin(tGlobal * 2.2);
      drawWrapped(dx, dy, r + 20, function (x, y) {
        g.save();
        g.strokeStyle = 'rgba(125,255,154,' + (0.35 + pulse * 0.35).toFixed(3) + ')';
        g.lineWidth = LOW_SCALE;
        g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.stroke();
        g.strokeStyle = 'rgba(125,255,154,0.18)';
        g.beginPath(); g.arc(x, y, r * (0.55 + pulse * 0.12), 0, Math.PI * 2); g.stroke();
        // The pad itself: a squat hexagon, drawn rather than sprited because it
        // is the one thing on screen that never rotates.
        g.fillStyle = '#123322';
        g.strokeStyle = '#7dff9a';
        g.lineWidth = LOW_SCALE;
        g.beginPath();
        for (var k = 0; k < 6; k++) {
          var a = k * Math.PI / 3 + Math.PI / 6;
          var px = x + Math.cos(a) * 20, py = y + Math.sin(a) * 20;
          if (k === 0) g.moveTo(px, py); else g.lineTo(px, py);
        }
        g.closePath(); g.fill(); g.stroke();
        g.fillStyle = '#7dff9a';
        g.fillRect(x - 3, y - 8, 6, 16);
        g.fillRect(x - 8, y - 3, 16, 6);
        g.restore();
      });
    }

    function drawRocks() {
      for (var i = 0; i < MAX_ROCKS; i++) {
        var a = (ROCKS_OFF + i * ROCK_STRIDE) >> 2;
        var R = FIELD.rock;
        if (f32[a + R.active] <= 0) continue;
        var size = f32[a + R.size] | 0;
        var spr = sprRock[size] || sprRock[1];
        var ang = f32[a + R.spin] * tGlobal;
        var r = f32[a + R.radius];
        drawWrapped(f32[a + R.x], f32[a + R.y], r + 8, function (x, y) {
          drawSpriteAt(spr, x, y, ang);
        });
      }
    }

    function drawBullets() {
      // No glow. A blur is the giveaway that a picture was made after about
      // 1995; brightness on this hardware came from picking a brighter colour.
      for (var i = 0; i < MAX_BULLETS; i++) {
        var a = (BULLETS_OFF + i * BULLET_STRIDE) >> 2;
        if (f32[a + FIELD.bullet.active] <= 0) continue;
        drawWrapped(f32[a + FIELD.bullet.x], f32[a + FIELD.bullet.y], 6, function (x, y) {
          var bx = Math.round(x / LOW_SCALE) * LOW_SCALE;
          var by = Math.round(y / LOW_SCALE) * LOW_SCALE;
          g.fillStyle = '#ffb02e';
          g.fillRect(bx - LOW_SCALE, by - LOW_SCALE, LOW_SCALE * 2, LOW_SCALE * 2);
          g.fillStyle = '#fff2a8';
          g.fillRect(bx - LOW_SCALE, by - LOW_SCALE, LOW_SCALE, LOW_SCALE);
        });
      }
    }

    function drawPickups() {
      for (var i = 0; i < MAX_PICKUPS; i++) {
        var a = (PICKUPS_OFF + i * PICKUP_STRIDE) >> 2;
        var P = FIELD.pickup;
        if (f32[a + P.active] <= 0) continue;
        var kind = f32[a + P.kind] | 0;
        var life = f32[a + P.life];
        var spr = kind === 1 ? sprCell : sprGem;
        var bob = Math.sin(tGlobal * 3.4 + f32[a + P.phase]) * 3;
        // The last three seconds blink, because a gem that simply vanished
        // would read as the game taking it rather than the player being late.
        var visible = life > 3 || (Math.sin(life * 18) > -0.2);
        if (!visible) continue;
        drawWrapped(f32[a + P.x], f32[a + P.y] + bob, 14, function (x, y) {
          drawSpriteAt(spr, x, y, 0);
        });
      }
    }

    function drawShip() {
      var a = SHIP_OFF >> 2;
      if (f32[a + FIELD.ship.alive] <= 0) return;
      var h = f32[a + FIELD.ship.heading];
      var inv = wasm.exports.get_invuln();
      // Blink while invulnerable — visible, but unmistakably not solid yet.
      if (inv > 0 && Math.sin(inv * 26) < -0.1) return;
      var thrusting = wasm.exports.get_thrusting();
      var frame = ((tGlobal * 22) | 0) & 1;
      drawWrapped(f32[a + FIELD.ship.x], f32[a + FIELD.ship.y], 26, function (x, y) {
        if (thrusting) {
          g.save();
          g.translate(x, y);
          g.rotate(h);
          var fl = sprFlame[frame];
          g.drawImage(fl, -fl.width / 2, sprShip.height / 2 - 3);
          g.restore();
        }
        drawSpriteAt(sprShip, x, y, h);
      });
    }

    // ---------- engine events ----------
    // The engine never calls out. It counts, and this reads the counters — one
    // place where "what just happened" is decided, so sound, particles and
    // shake can never disagree about it.
    function pollEvents(dt) {
      var e = wasm.exports;
      var sa = SHIP_OFF >> 2;

      var shots = e.get_shots();
      if (shots > prevShots) { sound.shot(); prevShots = shots; }

      var hits = e.get_hits();
      if (hits > prevHits) {
        sound.crack();
        shake = Math.max(shake, 0.12);
        prevHits = hits;
      }

      var grabs = e.get_grabs();
      if (grabs > prevGrabs) { sound.gem(); prevGrabs = grabs; }

      var fuels = e.get_fuels();
      if (fuels > prevFuels) { sound.cell(); prevFuels = fuels; }

      var drops = e.get_drops();
      if (drops > prevDrops) { sound.drop(drops); prevDrops = drops; }

      var deaths = e.get_deaths();
      if (deaths > prevDeaths) {
        sound.die();
        shake = Math.max(shake, 0.5);
        flash = 0.55;
        var sx = f32[sa + FIELD.ship.x], sy = f32[sa + FIELD.ship.y];
        burst(sx, sy, 46, '#ff5470', 260);
        burst(sx, sy, 22, '#ffb02e', 180);
        prevDeaths = deaths;
      }

      var level = e.get_level();
      if (level !== prevLevel) {
        sound.level();
        bannerEl.textContent = 'LEVEL ' + level;
        bannerT = 1.4;
        prevLevel = level;
      }

      // The fuel warning is a repeating beep rather than a one-shot, because
      // the state it describes persists and gets worse.
      var fuel = e.get_fuel(), fmax = e.get_fuel_max();
      if (fuel < fmax * 0.22 && !e.is_game_over()) {
        warnT -= dt;
        if (warnT <= 0) { sound.warn(); warnT = 1.1; }
      } else {
        warnT = 0;
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

      // Keys and stick are one input each frame. The stick names a heading and
      // the keys name a turn rate; whichever spoke last wins, which is settled
      // here rather than in the engine so `set_input` stays a plain report of
      // what is being asked for.
      var rot = (keys.right ? 1 : 0) - (keys.left ? 1 : 0);
      if (rot !== 0) stick.on = 0;
      wasm.exports.set_input(
        rot,
        (keys.thrust || touch.thrust) ? 1 : 0,
        (keys.fire || touch.fire) ? 1 : 0,
        stick.on,
        stick.ang);

      wasm.exports.step(dt);
      pollEvents(dt);

      var Z = 1 / LOW_SCALE;
      g.setTransform(Z, 0, 0, Z, 0, 0);
      g.fillStyle = '#05070f';
      g.fillRect(0, 0, WORLD_W, WORLD_H);

      if (shake > 0) {
        // Whole low-res pixels only. A sub-pixel shake would resample the
        // whole field every frame and undo the point of the buffer.
        var m = shake * 4;
        g.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m),
          Math.round((Math.random() * 2 - 1) * m));
        shake = Math.max(0, shake - dt * 1.7);
      }

      drawStars();
      drawDepot();
      drawPickups();
      drawRocks();
      drawBullets();
      drawShip();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.75).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.8);
      }

      // Blow the buffer up to the visible canvas. Nearest-neighbour, exact
      // integer scale: every low-res pixel becomes a hard 3x3 block.
      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      // Overlays.
      if (bannerT > 0) { bannerT -= dt; bannerEl.style.opacity = bannerT > 0 ? '1' : '0'; }
      var cargo = wasm.exports.get_cargo();
      var cmax = wasm.exports.get_cargo_max();
      var docked = isDocked();
      if (docked && cargo > 0) { noteEl.textContent = 'UNLOADING'; noteT = 0.2; }
      else if (docked) { noteEl.textContent = 'REFUELLING'; noteT = 0.2; }
      else if (cargo >= cmax) { noteEl.textContent = 'HOLD FULL — FLY HOME'; noteT = 0.2; }
      noteT -= dt;
      noteEl.style.opacity = (noteT > 0 && !wasm.exports.is_game_over()) ? '1' : '0';

      // HUD.
      var fuel = wasm.exports.get_fuel(), fmax = wasm.exports.get_fuel_max();
      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLives.textContent = Math.max(0, Math.round(wasm.exports.get_lives()));
      hudLevel.textContent = wasm.exports.get_level();
      hudCargo.textContent = Math.round(cargo) + '/' + Math.round(cmax);
      hudQuota.textContent = wasm.exports.get_delivered() + '/' + wasm.exports.get_quota();
      fuelFill.style.width = Math.max(0, Math.min(100, fuel / fmax * 100)) + '%';
      if (fuel < fmax * 0.22) fuelBar.classList.add('am-low');
      else fuelBar.classList.remove('am-low');

      rafId = requestAnimationFrame(loop);
    }

    function isDocked() {
      var a = SHIP_OFF >> 2;
      var dx = f32[a + FIELD.ship.x] - wasm.exports.get_depot_x();
      var dy = f32[a + FIELD.ship.y] - wasm.exports.get_depot_y();
      if (dx > WORLD_W / 2) dx -= WORLD_W; if (dx < -WORLD_W / 2) dx += WORLD_W;
      if (dy > WORLD_H / 2) dy -= WORLD_H; if (dy < -WORLD_H / 2) dy += WORLD_H;
      var r = wasm.exports.get_depot_r() + SHIP_R;
      return dx * dx + dy * dy < r * r;
    }

    function restart() {
      if (!wasm) return;
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      particles.length = 0;
      shake = 0; flash = 0; bannerT = 0; noteT = 0; warnT = 0;
      releaseAll();
      prevLevel = wasm.exports.get_level();
      prevShots = wasm.exports.get_shots();
      prevHits = wasm.exports.get_hits();
      prevGrabs = wasm.exports.get_grabs();
      prevFuels = wasm.exports.get_fuels();
      prevDrops = wasm.exports.get_drops();
      prevDeaths = wasm.exports.get_deaths();
      prevOver = 0;
      msgEl.style.display = 'none';
      bannerEl.style.opacity = '0';
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var imports = { env: { sinf: Math.sin, cosf: Math.cos } };
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) { return WebAssembly.instantiate(buf, imports); });
    } else {
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), imports);
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="am-fail">Failed to load game engine: ' + err + '</div>';
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
        global.removeEventListener('pointerup', onWindowPointerUp);
        global.removeEventListener('pointercancel', onWindowPointerCancel);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          lives: wasm.exports.get_lives(),
          level: wasm.exports.get_level(),
          fuel: wasm.exports.get_fuel(),
          cargo: wasm.exports.get_cargo(),
          delivered: wasm.exports.get_delivered(),
          quota: wasm.exports.get_quota(),
          gameOver: !!wasm.exports.is_game_over(),
        };
      },
    };
  }

  global.AsteroidMiner = { mount: mount };

})(window);
