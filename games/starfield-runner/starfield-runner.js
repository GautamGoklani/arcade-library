/* ============================================================
 * STARFIELD RUNNER — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="starfield-runner.css">
 *   <div id="game"></div>
 *   <script src="starfield-runner.js"><\/script>
 *   <script>
 *     var game = StarfieldRunner.mount(document.getElementById('game'));
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
  var ROCKS_OFF = 16, ROCK_STRIDE = 40, MAX_ROCKS = 26;
  var PXS = 3;         // chunky pixel scale for the ASCII sprites
  var LOW_SCALE = 3;   // 320x240 buffer, blown up — see asteroid-miner.js

  var WASM_B64 = "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";

  // ============================================================
  // PIXEL SPRITES (ASCII grids -> offscreen canvases)
  // Each character is one pixel; '.' is transparent. Every row of a sprite
  // must be the same length.
  //
  // The debris is *not* sprites. A rock is a radius the engine chose from a
  // range, and an ASCII grid has one size — three hand-drawn boulders would be
  // three things to keep looking alike, and would all be the wrong radius for
  // the collision the player is being scored on. They are drawn as pixel discs
  // instead, on the same low-res grid, so it is the same picture either way.
  // Circuit Runner reached the same conclusion about its components.
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

  // The ship, in three banks. A dart, because the only question the sprite has
  // to answer is which way it is being pushed — and the bank answers it half a
  // second before the position does, which is the half second the player needs.
  var SHIP_PAL = { W: '#eaf6ff', C: '#66e2ff', B: '#2f7fb8', D: '#123a55', Y: '#ffd166' };
  var shipLevel = [
    '......WW......',
    '.....WCCW.....',
    '.....WCCW.....',
    '....WCCCCW....',
    '....CCCCCC....',
    '...CCCWWCCC...',
    '..CCCCWWCCCC..',
    '.CCBBCWWCBBCC.',
    'CCBBBCWWCBBBCC',
    'CBBDDBCCBDDBBC',
    'CBD...CC...DBC',
    '.B....CC....B.',
    '......YY......',
  ];
  var shipLeft = [
    '.....WW.......',
    '....WCCW......',
    '....WCCW......',
    '...WCCCCW.....',
    '..CCCCCC......',
    '.CCCWWCCC.....',
    'CCCCWWCCCC....',
    'CCBBCWWCBBC...',
    'CBBBCWWCBBBC..',
    'BBDDBCCBDDBBC.',
    'BD...CC...DBCC',
    '.....CC....BBC',
    '.....YY.......',
  ];
  var shipRight = [
    '.......WW.....',
    '......WCCW....',
    '......WCCW....',
    '.....WCCCCW...',
    '......CCCCCC..',
    '.....CCCWWCCC.',
    '....CCCCWWCCCC',
    '...CBBCWWCBBCC',
    '..CBBBCWWCBBBC',
    '.CBBDDBCCBDDBB',
    'CCBD...CC...DB',
    'CBB....CC.....',
    '.......YY.....',
  ];

  var FLAME_PAL = { Y: '#ffd166', O: '#ff8a3c', W: '#fff6dc', R: '#e8283c' };
  var flameA = [
    '.YY.',
    'YWWY',
    'YOOY',
    '.OO.',
    '.R..',
  ];
  var flameB = [
    '.YY.',
    'YWWY',
    '.OO.',
    '.O..',
    '....',
  ];

  // Board palette. No glow anywhere — brightness is a brighter colour, which
  // is the only way a picture reads as a machine of the period rather than a
  // modern one with pixel sprites in it.
  var SPACE = '#050916';
  var ROCK_FACE = ['#6b6f7e', '#7d6a58', '#5e6f78'];   // shard, boulder, slab
  var ROCK_LIT  = ['#9aa0b2', '#a8917a', '#87a0ad'];
  var ROCK_DARK = ['#33363f', '#3d3128', '#2c383f'];
  var GRAZE_COL = '#ffd166';
  var LANE_COL = 'rgba(102,180,255,0.16)';
  var LANE_EDGE = 'rgba(102,180,255,0.30)';

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

    function tone(freq, freq2, dur, type, gain, delay) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended') c.resume();
      var t0 = c.currentTime + (delay || 0);
      var o = c.createOscillator(), g = c.createGain();
      o.type = type || 'square';
      o.frequency.setValueAtTime(freq, t0);
      o.frequency.exponentialRampToValueAtTime(Math.max(1, freq2), t0 + dur);
      g.gain.setValueAtTime(gain == null ? 0.05 : gain, t0);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      o.connect(g); g.connect(c.destination);
      o.start(t0); o.stop(t0 + dur);
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
      // Grazes step up in eights, so a run of them reads as a run and not as
      // the same blip five times.
      graze: function (n) {
        tone(700 + (n % 8) * 45, 1000 + (n % 8) * 45, 0.045, 'square', 0.024);
      },
      // A squeeze is two notes because it is two edges. The interval widens
      // with the multiplier, so the sound says how well it is going without
      // anyone having to look at the HUD.
      squeeze: function (mult) {
        tone(620, 780, 0.06, 'triangle', 0.05);
        tone(880 + mult * 55, 1180 + mult * 55, 0.11, 'triangle', 0.055, 0.055);
      },
      patch: function () { tone(340, 900, 0.30, 'triangle', 0.06); },
      hit: function () { noise(0.32, 0.11); tone(190, 48, 0.34, 'sawtooth', 0.075); },
      over: function () { tone(230, 42, 1.0, 'sawtooth', 0.085); },
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
    if (!container) throw new Error('StarfieldRunner.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'sr-root';
    root.innerHTML =
      '<div class="sr-hud">' +
        '<span>SCORE <b class="sr-a" data-sr="score">0</b></span>' +
        '<span>DIST <b data-sr="dist">0m</b></span>' +
        '<span class="sr-hull">HULL <span class="sr-plates" data-sr="plates"></span></span>' +
        '<span class="sr-gauge">CHARGE <span class="sr-bar"><i data-sr="charge"></i></span></span>' +
        '<span class="sr-mult sr-one" data-sr="mult">x1<u data-sr="multbar"></u></span>' +
        '<button type="button" class="sr-mute" data-sr="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="sr-stage">' +
        '<canvas class="sr-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="sr-touch" aria-hidden="true">' +
          '<div class="sr-stickzone" data-sr="stickzone">' +
            '<div class="sr-stick" data-sr="stick"><div class="sr-stick-knob" data-sr="knob"></div></div>' +
          '</div>' +
        '</div>' +
        '<div class="sr-scan" aria-hidden="true"></div>' +
        '<div class="sr-overlay sr-note" data-sr="note">SQUEEZE</div>' +
        '<div class="sr-overlay sr-msg" data-sr="msg">HULL BREACH<small data-sr="msgsmall">PRESS R TO RESTART</small></div>' +
      '</div>' +
      '<div class="sr-help" data-sr="help">' +
        '[&larr;][&rarr;] FLY &nbsp; SHAVE THE ROCKS — CLOSE PASSES ARE THE ONLY SCORE ' +
        'AND THE ONLY REPAIR &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-sr="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;

    var stage = root.querySelector('.sr-stage');
    var hudScore = q('score'), hudDist = q('dist');
    var platesEl = q('plates'), chargeEl = q('charge');
    var multEl = q('mult'), multBar = q('multbar');
    var msgEl = q('msg'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute');
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');

    // Hull plates are built once and only ever toggled, so a repair and a
    // breach are the same DOM operation in reverse.
    var plateEls = [];
    (function () {
      for (var i = 0; i < 3; i++) {
        var el = document.createElement('span');
        el.className = 'sr-plate';
        platesEl.appendChild(el);
        plateEls.push(el);
      }
    })();

    function enableTouchUI() {
      if (root.classList.contains('sr-is-touch')) return;
      root.classList.add('sr-is-touch');
      helpEl.textContent =
        'SLIDE TO FLY • SHAVE THE ROCKS — CLOSE PASSES ARE THE ONLY SCORE AND THE ONLY REPAIR • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var keys = { left: false, right: false };
    var stick = { active: false, ox: 0, dir: 0 };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0, pulse = 0;
    var prevGrazes = 0, prevSqueezes = 0, prevHits = 0, prevPatches = 0, prevOver = 0;
    var prevHull = 3;
    var noteT = 0, noteText = '';
    // Parallax stars. Pure decoration, owned here rather than in the engine
    // for exactly that reason — nothing collides with a star, nothing scores
    // one, and the engine has no opinion about how deep the sky is.
    var STAR_LAYERS = [
      { n: 46, f: 0.22, c: '#2b3a5c' },
      { n: 30, f: 0.50, c: '#4f6a99' },
      { n: 18, f: 0.92, c: '#a8c4e8' },
    ];
    var stars = [];

    // ---------- sprites ----------
    var sprShip = [
      makeSprite(shipLeft, SHIP_PAL, PXS),
      makeSprite(shipLevel, SHIP_PAL, PXS),
      makeSprite(shipRight, SHIP_PAL, PXS),
    ];
    var sprFlame = [makeSprite(flameA, FLAME_PAL, PXS), makeSprite(flameB, FLAME_PAL, PXS)];

    // ---------- input ----------
    var KEY_MAP = {
      ArrowLeft: 'left', a: 'left', A: 'left',
      ArrowRight: 'right', d: 'right', D: 'right',
    };

    function onKeyDown(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = true; stick.dir = 0; e.preventDefault(); return; }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
    }
    function onKeyUp(e) {
      var k = KEY_MAP[e.key];
      if (k) { keys[k] = false; e.preventDefault(); }
    }

    function releaseAll() {
      keys.left = keys.right = false;
      releaseStick();
    }

    function releaseStick() {
      stick.active = false;
      stick.dir = 0;
      stickEl.classList.remove('sr-active');
      stickEl.style.left = ''; stickEl.style.top = '';
      knobEl.style.transform = 'translate(-50%, -50%)';
    }

    function stagePoint(e) {
      var r = stage.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top, w: r.width, h: r.height };
    }

    function onStickDown(e) {
      if (e.pointerType === 'mouse') return;   // a mouse plays with the keyboard
      enableTouchUI();
      var p = stagePoint(e);
      stick.active = true;
      stick.ox = p.x;
      stickEl.style.left = (p.x / p.w * 100) + '%';
      stickEl.style.top = (p.y / p.h * 100) + '%';
      stickEl.classList.add('sr-active');
      knobEl.style.transform = 'translate(-50%, -50%)';
      if (stickZone.setPointerCapture) {
        try { stickZone.setPointerCapture(e.pointerId); } catch (err) {}
      }
      e.preventDefault();
    }

    function onStickMove(e) {
      if (!stick.active || e.pointerType === 'mouse') return;
      var p = stagePoint(e);
      var dx = p.x - stick.ox;
      var reach = stickEl.getBoundingClientRect().width / 2 || 40;
      var k = Math.max(-1, Math.min(1, dx / reach));
      knobEl.style.transform = 'translate(calc(-50% + ' + (k * reach) + 'px), -50%)';
      // Analogue, and horizontal only. set_input takes an f32 and scales the
      // thrust by it, so a nudge drifts and a full push commits — which is the
      // distinction the whole scoring rule rests on, and the reason this title
      // gets a rail rather than Circuit Runner's two tap halves.
      stick.dir = Math.abs(k) < 0.10 ? 0 : k;
      e.preventDefault();
    }

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    stickZone.addEventListener('pointerdown', onStickDown);
    stickZone.addEventListener('pointermove', onStickMove);
    // Named, not inline, so destroy() can take them off again.
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
          life: 0.25 + Math.random() * 0.4, age: 0, color: color,
        });
      }
      if (particles.length > 340) particles.splice(0, particles.length - 340);
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

    function seedStars() {
      stars.length = 0;
      for (var l = 0; l < STAR_LAYERS.length; l++) {
        for (var i = 0; i < STAR_LAYERS[l].n; i++) {
          stars.push({
            x: Math.random() * WORLD_W,
            y: Math.random() * WORLD_H,
            l: l,
            size: l === 2 ? LOW_SCALE * 2 : LOW_SCALE,
          });
        }
      }
    }

    function drawStars(dt, speed) {
      g.fillStyle = SPACE;
      g.fillRect(0, 0, WORLD_W, WORLD_H);
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        s.y += speed * STAR_LAYERS[s.l].f * dt;
        if (s.y > WORLD_H) { s.y -= WORLD_H + 8; s.x = Math.random() * WORLD_W; }
        g.fillStyle = STAR_LAYERS[s.l].c;
        g.fillRect(snap(s.x), snap(s.y), s.size, s.size);
      }
    }

    /**
     * The guaranteed corridor of whichever field is arriving next, read off
     * that field's rocks (every rock carries its field's `path`).
     *
     * Drawing it is a design decision, not a debug view. The engine builds a
     * line no rock may ever cross; hiding it would make the game a memory test
     * about where that line probably is. Showing it turns every field into the
     * question the title is actually about — *the safe line is right there,
     * and it is worth nothing* — and makes leaving it a choice rather than an
     * accident.
     */
    function drawCorridor() {
      var shipY = wasm.exports.get_ship_y();
      var topY = null, path = 0;
      for (var i = 0; i < MAX_ROCKS; i++) {
        var a = (ROCKS_OFF + i * ROCK_STRIDE) >> 2;
        if (f32[a + 4] <= 0) continue;
        var y = f32[a + 1];
        if (y > shipY - 20) continue;
        if (topY === null || y > topY) { topY = y; path = f32[a + 9]; }
      }
      if (topY === null) return;

      var half = wasm.exports.get_corridor() / 2;
      var l = snap(path - half), r = snap(path + half);
      g.fillStyle = LANE_COL;
      g.fillRect(l, 0, r - l, snap(shipY));
      g.fillStyle = LANE_EDGE;
      // dashed edges, so the channel reads as a marked route rather than a wall
      for (var yy = (Math.round(tGlobal * 90) % 36) - 36; yy < shipY; yy += 36) {
        g.fillRect(l, snap(yy), LOW_SCALE, LOW_SCALE * 6);
        g.fillRect(r - LOW_SCALE, snap(yy), LOW_SCALE, LOW_SCALE * 6);
      }
    }

    /**
     * A rock, as a pixel disc: rows of fillRect on the low-res grid, so it is
     * the same kind of shape as everything else on screen and it is exactly
     * the radius the engine is scoring against.
     */
    function pixelDisc(cx, cy, r, face, lit, dark) {
      var s = LOW_SCALE;
      var top = snap(cy - r), bot = snap(cy + r);
      for (var y = top; y <= bot; y += s) {
        var dy = y + s / 2 - cy;
        var half = Math.sqrt(Math.max(0, r * r - dy * dy));
        if (half < s / 2) continue;
        var l = snap(cx - half), w = snap(cx + half) - l;
        if (w <= 0) continue;
        g.fillStyle = face;
        g.fillRect(l, y, w, s);
        // one lit pixel run along the upper-left, one dark along the lower
        if (dy < -r * 0.25) { g.fillStyle = lit; g.fillRect(l, y, Math.min(w, s * 3), s); }
        if (dy > r * 0.35) { g.fillStyle = dark; g.fillRect(l, y, w, s); }
      }
    }

    function drawRocks() {
      var band = wasm.exports.get_graze_band();
      for (var i = 0; i < MAX_ROCKS; i++) {
        var a = (ROCKS_OFF + i * ROCK_STRIDE) >> 2;
        if (f32[a + 4] <= 0) continue;
        var x = f32[a], y = f32[a + 1], r = f32[a + 3];
        if (y < -r - 10 || y > WORLD_H + r + 10) continue;
        var kind = f32[a + 7] | 0;
        pixelDisc(x, y, r, ROCK_FACE[kind], ROCK_LIT[kind], ROCK_DARK[kind]);

        // Craters, rotating with the rock's own spin. Their angles come from
        // the pool index, so a given rock keeps its own face for its whole
        // pass instead of boiling.
        var spin = f32[a + 6] * tGlobal;
        for (var k = 0; k < 3; k++) {
          var ang = spin + i * 1.7 + k * 2.1;
          var rad = r * (0.25 + ((i + k) % 3) * 0.2);
          g.fillStyle = ROCK_DARK[kind];
          g.fillRect(snap(x + Math.cos(ang) * rad), snap(y + Math.sin(ang) * rad),
                     LOW_SCALE * 2, LOW_SCALE * 2);
        }

        // The graze ring. `near` is the tightest clearance this rock has ever
        // had, so the ring lights as the ship closes and *stays* lit once the
        // pass is banked — the player sees which rocks paid before the score
        // catches up.
        var near = f32[a + 5];
        if (near > 0 && near < band) {
          var t = 1 - near / band;
          g.globalAlpha = 0.25 + t * 0.6;
          g.fillStyle = GRAZE_COL;
          ringAt(x, y, r + band * 0.6);
          g.globalAlpha = 1;
        }
      }
    }

    function ringAt(cx, cy, r) {
      var steps = 14;
      for (var i = 0; i < steps; i++) {
        var a = (i / steps) * Math.PI * 2;
        g.fillRect(snap(cx + Math.cos(a) * r), snap(cy + Math.sin(a) * r), LOW_SCALE, LOW_SCALE);
      }
    }

    function drawShip() {
      var e = wasm.exports;
      var x = e.get_ship_x(), y = e.get_ship_y(), vx = e.get_ship_vx();
      var invuln = e.get_invuln();
      // Blinking after a hit: the engine makes the ship immune for exactly
      // this window, so the blink is honest about state rather than decorative.
      if (invuln > 0 && Math.sin(invuln * 42) < -0.1) return;
      var bank = vx < -90 ? 0 : (vx > 90 ? 2 : 1);
      drawSpriteAt(sprFlame[(tGlobal * 22 | 0) & 1], x, y + 26);
      drawSpriteAt(sprShip[bank], x, y);
    }

    // ---------- engine events ----------
    function pollEvents() {
      var e = wasm.exports;
      var sx = e.get_ship_x(), sy = e.get_ship_y();

      var gz = e.get_grazes();
      if (gz > prevGrazes) {
        sound.graze(gz);
        burst(sx, sy - 6, 4, GRAZE_COL, 110);
        prevGrazes = gz;
      }

      var sq = e.get_squeezes();
      if (sq > prevSqueezes) {
        sound.squeeze(e.get_mult());
        burst(sx, sy, 14, '#ffffff', 190);
        pulse = 0.3;
        noteText = 'SQUEEZE x' + Math.round(e.get_mult());
        noteT = 0.55;
        prevSqueezes = sq;
      }

      var pa = e.get_patches();
      if (pa > prevPatches) {
        sound.patch();
        burst(sx, sy, 20, '#6ee7a8', 170);
        noteText = 'PLATE RESTORED';
        noteT = 0.8;
        prevPatches = pa;
      }

      var hi = e.get_hits();
      if (hi > prevHits) {
        sound.hit();
        shake = Math.max(shake, 0.5);
        flash = 0.5;
        burst(sx, sy, 26, '#ff5470', 240);
        prevHits = hi;
      }

      var over = e.is_game_over();
      if (over && !prevOver) { sound.over(); msgEl.style.display = 'block'; }
      prevOver = over;
    }

    // ---------- HUD ----------
    function drawHud() {
      var e = wasm.exports;
      var hull = Math.round(e.get_hull());
      hudScore.textContent = Math.round(e.get_score());
      hudDist.textContent = Math.round(e.get_dist() / 10) + 'm';
      for (var i = 0; i < plateEls.length; i++) {
        var on = i < hull;
        plateEls[i].classList.toggle('sr-off', !on);
        if (!on && i < prevHull) {
          // retrigger the flash by taking the class off and putting it back
          plateEls[i].classList.remove('sr-lost');
          void plateEls[i].offsetWidth;
          plateEls[i].classList.add('sr-lost');
        }
      }
      prevHull = hull;
      chargeEl.style.width = (e.get_charge() / e.get_charge_max() * 100) + '%';
      var m = Math.round(e.get_mult());
      multEl.firstChild.nodeValue = 'x' + m;
      multEl.classList.toggle('sr-one', m <= 1);
      multBar.style.transform = 'scaleX(' + (m <= 1 ? 1 : e.get_mult_frac()) + ')';
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      // Clamped at both ends. The ceiling is the usual one — a tab that was
      // backgrounded for ten seconds must not advance the board ten seconds
      // in one step. The floor is not decoration: a timestamp that goes
      // backwards (a restored tab, a clock adjustment) drives tGlobal
      // negative, and everything downstream that indexes an array by a frame
      // counter then reads off the front of it.
      var dt = Math.max(0, Math.min((now - lastT) / 1000, 0.05));
      lastT = now;
      tGlobal += dt;

      // Keyboard is two states, the stick is analogue, and the engine takes an
      // f32 either way. Held left and right cancel rather than fighting.
      var move = stick.dir;
      if (keys.left || keys.right) {
        move = (keys.right ? 1 : 0) - (keys.left ? 1 : 0);
      }
      wasm.exports.set_input(move);
      wasm.exports.step(dt);
      pollEvents();

      var speed = wasm.exports.get_speed();
      var Z = 1 / LOW_SCALE;
      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (shake > 0) {
        var s = shake * 4;
        g.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * s),
          Math.round((Math.random() * 2 - 1) * s));
        shake = Math.max(0, shake - dt * 1.9);
      }

      drawStars(wasm.exports.is_game_over() ? 0 : dt, speed);
      drawCorridor();
      drawRocks();
      drawShip();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (pulse > 0) {
        g.fillStyle = 'rgba(255,246,220,' + (pulse * 0.30).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        pulse = Math.max(0, pulse - dt * 2.4);
      }
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.65).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.9);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      drawHud();
      noteT -= dt;
      if (noteT > 0) { noteEl.textContent = noteText; noteEl.style.opacity = '1'; }
      else noteEl.style.opacity = '0';

      rafId = requestAnimationFrame(loop);
    }

    function restart() {
      if (!wasm) return;
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      particles.length = 0;
      seedStars();
      shake = 0; flash = 0; pulse = 0; noteT = 0;
      releaseAll();
      prevGrazes = wasm.exports.get_grazes();
      prevSqueezes = wasm.exports.get_squeezes();
      prevHits = wasm.exports.get_hits();
      prevPatches = wasm.exports.get_patches();
      prevHull = Math.round(wasm.exports.get_hull());
      prevOver = 0;
      msgEl.style.display = 'none';
      for (var i = 0; i < plateEls.length; i++) {
        plateEls[i].classList.remove('sr-off', 'sr-lost');
      }
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) { return WebAssembly.instantiate(buf, {}); });
    } else {
      // No imports: clearance is a distance, and f32.sqrt is an instruction.
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), {});
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="sr-fail">Failed to load game engine: ' + err + '</div>';
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
          distance: wasm.exports.get_dist(),
          speed: wasm.exports.get_speed(),
          hull: wasm.exports.get_hull(),
          charge: wasm.exports.get_charge(),
          multiplier: wasm.exports.get_mult(),
          grazes: wasm.exports.get_grazes(),
          squeezes: wasm.exports.get_squeezes(),
          gameOver: !!wasm.exports.is_game_over(),
        };
      },
    };
  }

  global.StarfieldRunner = { mount: mount };

})(window);
