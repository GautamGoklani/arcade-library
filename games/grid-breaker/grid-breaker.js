/* ============================================================
 * GRID BREAKER — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + pointer + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="grid-breaker.css">
 *   <div id="game"></div>
 *   <script src="grid-breaker.js"><\/script>
 *   <script>
 *     var game = GridBreaker.mount(document.getElementById('game'));
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
  var BALLS_OFF = 16, BALL_STRIDE = 32, MAX_BALLS = 6;
  var POWER_OFF = 208, POWER_STRIDE = 24, MAX_POWER = 8;
  var TILES_OFF = 400, TILE_STRIDE = 8;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[o + 5]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    paddle: { x: 0, y: 1, halfW: 2, vx: 3 },
    ball: { x: 0, y: 1, vx: 2, vy: 3, radius: 4, active: 5, stuck: 6, stickOff: 7 },
    power: { x: 0, y: 1, vx: 2, vy: 3, kind: 4, active: 5 },
    tile: { hp: 0, kind: 1 },
  };
  var COLS = 15, ROWS = 12;
  var TILE_W = 60, TILE_H = 26, GRID_X = 30, GRID_Y = 70;
  var PADDLE_HALF_H = 9;
  var PXS = 3; // chunky pixel scale for the ASCII sprites
  var LOW_SCALE = 3;  // 1/3-size buffer, blown up — see the retro adapter in mount()

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

  var BALL_PAL = { W: '#ffffff', C: '#bfefff', S: '#4aa8d8' };
  var ballRows = [
    '.WWWW.',
    'WWWWCW',
    'WWWCCS',
    'WCCCSS',
    'CCSSSS',
    '.SSSS.',
  ];

  // Power-up capsule faces. One glyph each, drawn on the capsule body:
  //   WIDE, MULTI, SLOW, STICKY — in engine kind order.
  var ICON_PAL = { K: '#0b0d16', W: '#ffffff' };
  var iconWide = [
    '.......',
    'W.....W',
    'WW...WW',
    'WWWWWWW',
    'WW...WW',
    'W.....W',
    '.......',
  ];
  var iconMulti = [
    '..WWW..',
    '.W...W.',
    'W.....W',
    'W.....W',
    'W.....W',
    '.W...W.',
    '..WWW..',
  ];
  var iconSlow = [
    '.WWWWW.',
    '..W.W..',
    '..WWW..',
    '...W...',
    '..WWW..',
    '..W.W..',
    '.WWWWW.',
  ];
  var iconSticky = [
    'WWWWWWW',
    'W.....W',
    'W.....W',
    '.W...W.',
    '..W.W..',
    '...W...',
    '...W...',
  ];

  var sprBall = makeSprite(ballRows, BALL_PAL, PXS);
  var sprIcons = [
    makeSprite(iconWide, ICON_PAL, 2),
    makeSprite(iconMulti, ICON_PAL, 2),
    makeSprite(iconSlow, ICON_PAL, 2),
    makeSprite(iconSticky, ICON_PAL, 2),
  ];

  // Row hues for plain tiles — the wall reads as a gradient top to bottom,
  // which also makes it obvious at a glance how deep you have dug.
  var ROW_COLORS = [
    ['#b45cff', '#d7a3ff', '#5a1e8a'],
    ['#6a7bff', '#a9b4ff', '#2b3391'],
    ['#2fb8ff', '#a2e2ff', '#12557f'],
    ['#28d6b0', '#a6f2e2', '#0f6354'],
    ['#5ad84a', '#bff5b6', '#266620'],
    ['#c9d63a', '#eff5a8', '#5d6613'],
    ['#ffb02e', '#ffdba1', '#7d5008'],
    ['#ff7a3d', '#ffc6a8', '#7d2f08'],
    ['#ff4d6d', '#ffb3c0', '#7d0f22'],
    ['#ff5ca8', '#ffb8d8', '#7d0c47'],
    ['#a06bff', '#d3bcff', '#3d1a7a'],
    ['#4ad2ff', '#b6ecff', '#0e5673'],
  ];
  var TOUGH_COLORS = ['#9fb3c8', '#e2ecf5', '#43566b'];
  var TOUGH_HURT = ['#7d8ea1', '#c3d2e0', '#33424f'];
  var BOMB_COLORS = ['#ff3b30', '#ffb0aa', '#7a1109'];
  var SOLID_COLORS = ['#5b6472', '#98a3b3', '#2b3038'];
  var POWER_COLORS = ['#ffb02e', '#4ad2ff', '#b45cff', '#5ad84a'];

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
      try { ctx = new AC(); } catch (e) { ctx = null; }
      return ctx;
    }

    function tone(freq, freq2, dur, type, gain) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      if (c.state === 'suspended' && c.resume) c.resume();
      var o = c.createOscillator(), g = c.createGain();
      o.type = type || 'square';
      o.frequency.setValueAtTime(freq, c.currentTime);
      if (freq2 && freq2 !== freq) {
        o.frequency.exponentialRampToValueAtTime(Math.max(1, freq2), c.currentTime + dur);
      }
      g.gain.setValueAtTime(gain || 0.05, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + dur);
      o.connect(g); g.connect(c.destination);
      o.start(); o.stop(c.currentTime + dur + 0.02);
    }

    function noise(dur, gain) {
      if (muted) return;
      var c = ensure();
      if (!c) return;
      var n = Math.floor(c.sampleRate * dur);
      var buf = c.createBuffer(1, n, c.sampleRate);
      var d = buf.getChannelData(0);
      for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n);
      var src = c.createBufferSource(), g = c.createGain();
      src.buffer = buf;
      g.gain.setValueAtTime(gain || 0.09, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + dur);
      src.connect(g); g.connect(c.destination);
      src.start();
    }

    return {
      paddle: function () { tone(300, 420, 0.06, 'square', 0.05); },
      wall:   function () { tone(220, 200, 0.04, 'square', 0.03); },
      brick:  function (row) { tone(520 + row * 45, 700 + row * 45, 0.05, 'square', 0.045); },
      tough:  function () { tone(180, 150, 0.06, 'sawtooth', 0.04); },
      bomb:   function () { noise(0.32, 0.13); tone(120, 40, 0.3, 'sawtooth', 0.06); },
      power:  function () { tone(660, 1180, 0.16, 'triangle', 0.06); },
      launch: function () { tone(420, 760, 0.1, 'triangle', 0.05); },
      lose:   function () { tone(300, 70, 0.5, 'sawtooth', 0.07); },
      level:  function () { tone(520, 1040, 0.28, 'triangle', 0.06); },
      over:   function () { tone(240, 55, 0.85, 'sawtooth', 0.08); },
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
    if (!container) throw new Error('GridBreaker.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'gb-root';
    root.innerHTML =
      '<div class="gb-hud">' +
        '<span>SCORE <b class="gb-a" data-gb="score">0</b></span>' +
        '<span>LIVES <b class="gb-r" data-gb="lives">5</b></span>' +
        '<span>LEVEL <b class="gb-v" data-gb="level">1</b></span>' +
        '<span>TILES <b data-gb="tiles">0</b></span>' +
        '<button type="button" class="gb-mute" data-gb="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="gb-stage">' +
        '<canvas class="gb-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="gb-scan" aria-hidden="true"></div>' +
        '<div class="gb-overlay gb-msg" data-gb="msg">GAME OVER<small data-gb="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="gb-overlay gb-banner" data-gb="banner">LEVEL 1</div>' +
        '<div class="gb-overlay gb-serve" data-gb="serve">PRESS SPACE TO LAUNCH</div>' +
        '<div class="gb-touch" aria-hidden="true">' +
          // Left half is one big capture zone; the ring re-anchors to wherever
          // the thumb lands, so the stick is never somewhere you have to look
          // for. The knob only travels horizontally — the paddle has one axis,
          // and a knob that slid vertically would promise control that is not
          // there.
          '<div class="gb-stickzone" data-gb="stickzone">' +
            '<div class="gb-stick" data-gb="stick">' +
              '<div class="gb-stick-knob" data-gb="knob"></div>' +
            '</div>' +
          '</div>' +
          '<div class="gb-btn gb-btn-launch" data-gb="btnLaunch">LAUNCH</div>' +
        '</div>' +
      '</div>' +
      '<div class="gb-help" data-gb="help">' +
        '[A]/[D] or MOUSE MOVE &nbsp; [SPACE] LAUNCH &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-gb="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    // ---------- the retro render treatment ----------
    // Everything below draws into `ctx`, which is no longer the canvas on the
    // page: it is a buffer a third the size, blown up onto `screen` once per
    // frame with smoothing off. This title predates that look and was
    // retrofitted to match the rest of the library; see CLAUDE.md, "The retro
    // render treatment".
    //
    // The titles built for this resolution snap every coordinate at the call
    // site. This one was drawn at full resolution, with bevels one and three
    // pixels wide scattered over dozens of calls, so the snap lives in the
    // adapter instead: fillRect and drawImage round their edges to whole
    // low-res pixels, and a detail that would round away to nothing keeps one
    // pixel rather than vanishing. That keeps the retrofit to this block and a
    // handful of transform lines, and leaves the draw code as it was written.
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;
    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var ctx = low.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    var rawFillRect = ctx.fillRect.bind(ctx);
    var rawDrawImage = ctx.drawImage.bind(ctx);
    ctx.fillRect = function (x, y, w, h) {
      var l = snap(x), t = snap(y), r = snap(x + w), b = snap(y + h);
      if (r === l && w > 0) r = l + LOW_SCALE;
      if (b === t && h > 0) b = t + LOW_SCALE;
      rawFillRect(l, t, r - l, b - t);
    };
    ctx.drawImage = function (img, x, y) {
      // Every call in this file uses the three-argument form.
      if (arguments.length === 3) rawDrawImage(img, snap(x), snap(y));
      else rawDrawImage.apply(null, arguments);
    };
    function snap(v) { return Math.round(v / LOW_SCALE) * LOW_SCALE; }
    // One low-res pixel, in world units, for a transform: the base scale plus
    // an offset that is always a whole low-res pixel, screen shake included.
    var Z = 1 / LOW_SCALE;
    var stage = root.querySelector('.gb-stage');
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level'), hudTiles = q('tiles');
    var msgEl = q('msg'), bannerEl = q('banner'), serveEl = q('serve'), helpEl = q('help');
    var muteBtn = q('mute');

    /**
     * Which controls a visitor gets is decided per *event*, by `pointerType`,
     * not by sniffing the device at mount. Asking `'ontouchstart' in window`
     * classes every touchscreen laptop as a touch device and takes mouse
     * steering away from someone holding a mouse — and on a hybrid machine the
     * answer can change from one moment to the next anyway.
     *
     * So the stick and the button are always present and always interactive,
     * a mouse is always routed to steering whatever it lands on, and this flag
     * only governs *presentation*: whether the touch overlay is visible and
     * which help text is shown.
     *
     * `(pointer: coarse)` alone (without the ontouchstart fallback) describes
     * the *primary* pointer, so it is true on phones and tablets and false on a
     * laptop with a touchscreen — exactly the right initial guess. A first
     * touch on any device corrects it.
     */
    function enableTouchUI() {
      if (root.classList.contains('gb-is-touch')) return;
      root.classList.add('gb-is-touch');
      helpEl.textContent = 'LEFT THUMBSTICK TO MOVE • LAUNCH BUTTON RIGHT • TAP GAME OVER TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
      serveEl.textContent = 'PRESS LAUNCH';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null, i32 = null;
    var running = false, destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var input = { left: false, right: false, launch: false };
    var pointer = { active: false, x: WORLD_W / 2 };
    // Thumbstick. `dir` is the analog value handed straight to the engine:
    // set_input takes it as an f32 and applies `x += dir * PADDLE_SPEED * dt`,
    // so anything in [-1,1] is legal. The keys are just the special case that
    // only ever asks for the extremes.
    var stick = { active: false, dir: 0, originX: 0 };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    // The engine's event counters as of last frame. See pollEvents().
    var prev = { breaks: 0, chips: 0, booms: 0, bounces: 0, powers: 0,
                 drains: 0, launches: 0, hurts: 0, clears: 0 };
    // Tile hit points as of last frame. This is no longer how the widget learns
    // that a tile broke — the counters say that — only *where* to put the
    // sparks, which is a drawing question a counter cannot answer.
    var prevTileHp = new Float32Array(COLS * ROWS);

    // ---------- input ----------
    function onKeyDown(e) {
      if (e.key === 'a' || e.key === 'A' || e.key === 'ArrowLeft') { input.left = true; pointer.active = false; e.preventDefault(); }
      if (e.key === 'd' || e.key === 'D' || e.key === 'ArrowRight') { input.right = true; pointer.active = false; e.preventDefault(); }
      if (e.key === ' ') { input.launch = true; e.preventDefault(); }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
    }
    function onKeyUp(e) {
      if (e.key === 'a' || e.key === 'A' || e.key === 'ArrowLeft') input.left = false;
      if (e.key === 'd' || e.key === 'D' || e.key === 'ArrowRight') input.right = false;
      if (e.key === ' ') input.launch = false;
    }
    // A held key with the tab backgrounded never sees its keyup, and neither
    // does a thumb still on the glass.
    function releaseAll() {
      input.left = input.right = input.launch = false;
      if (stick.active) releaseStick();
    }

    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);
    global.addEventListener('blur', releaseAll);

    // Touch and mouse are two control schemes sharing one set of listeners.
    // They cannot fight, because a pointer is routed by its `pointerType`: a
    // mouse only ever steers, a finger or pen only ever works the stick and the
    // button. Both stay live at once, so a hybrid machine follows whichever the
    // person actually picks up, switching mid-game if they swap.
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');
    var btnLaunch = q('btnLaunch');
    var pointers = new Map();   // pointerId -> { kind:'stick'|'btn'|'mouse' }

    // Below this fraction of the ring radius the thumb counts as centred, so
    // resting on the pad holds the paddle still instead of creeping.
    var STICK_DEADZONE = 0.16;

    function anchorStick(cx, cy) {
      var zr = stickZone.getBoundingClientRect();
      var r = stickEl.offsetWidth / 2;
      var x = Math.max(r, Math.min(zr.width - r, cx - zr.left));
      var y = Math.max(r, Math.min(zr.height - r, cy - zr.top));
      stick.originX = zr.left + x;
      stickEl.style.left = x + 'px';
      stickEl.style.top = y + 'px';
      stickEl.classList.add('gb-active');
    }

    function moveStick(cx) {
      var r = stickEl.offsetWidth / 2 || 1;
      var dx = cx - stick.originX;
      // One axis: the paddle only moves left and right, so the knob does too.
      stick.dir = Math.max(-1, Math.min(1, dx / r));
      knobEl.style.transform =
        'translate(-50%,-50%) translateX(' + (stick.dir * r) + 'px)';
    }

    function releaseStick() {
      stick.active = false;
      stick.dir = 0;
      stickEl.classList.remove('gb-active');
      stickEl.style.left = '';
      stickEl.style.top = '';
      knobEl.style.transform = 'translate(-50%,-50%)';
    }

    // Mouse steering: the paddle follows the cursor in world coordinates, so it
    // works at any rendered size. This is the better control for a breaker,
    // which is why a mouse keeps it even on a machine that can also be touched.
    function mouseX(e) {
      var rect = canvas.getBoundingClientRect();
      return ((e.clientX - rect.left) / rect.width) * WORLD_W;
    }

    var isMouse = function (e) { return !e.pointerType || e.pointerType === 'mouse'; };

    function onPointerDown(e) {
      // Game-over text is tappable (a phone has no R key) and sits above
      // everything else, so it is checked first whatever the pointer is.
      if (msgEl.style.display === 'block' && msgEl.contains(e.target)) {
        e.preventDefault();
        restart();
        return;
      }

      if (isMouse(e)) {
        // A mouse never reaches the stick or the button, whatever it lands on —
        // those exist for fingers. It steers, and clicking launches.
        pointers.set(e.pointerId, { kind: 'mouse' });
        pointer.active = true;
        pointer.x = mouseX(e);
        input.launch = true;
        return;
      }

      // A finger or pen: this device is being touched, whatever the media query
      // guessed at mount, so show the controls it is reaching for.
      enableTouchUI();
      // Drop mouse steering, or a stale cursor position keeps driving the
      // paddle while a thumb is on the stick.
      pointer.active = false;

      if (btnLaunch.contains(e.target)) {
        e.preventDefault();
        pointers.set(e.pointerId, { kind: 'btn' });
        input.launch = true;
        btnLaunch.classList.add('gb-active');
        return;
      }
      if (stickZone.contains(e.target) && !stick.active) {
        e.preventDefault();
        pointers.set(e.pointerId, { kind: 'stick' });
        stick.active = true;
        anchorStick(e.clientX, e.clientY);
        moveStick(e.clientX);
      }
    }

    function onPointerMove(e) {
      if (isMouse(e)) {
        // Steering follows the cursor whether or not a button is held, and
        // without needing a pointerdown first.
        pointer.active = true;
        pointer.x = mouseX(e);
        return;
      }
      var p = pointers.get(e.pointerId);
      if (!p || p.kind !== 'stick') return;
      e.preventDefault();
      moveStick(e.clientX);
    }

    // Covers pointerup, pointercancel and the browser stealing the pointer, so
    // nothing can latch on. The launch button stays held while a thumb slides
    // off it — only a real release clears it.
    function onPointerUp(e) {
      var p = pointers.get(e.pointerId);
      if (!p) return;
      pointers.delete(e.pointerId);
      if (p.kind === 'stick') {
        releaseStick();
      } else if (p.kind === 'btn') {
        input.launch = false;
        btnLaunch.classList.remove('gb-active');
      } else {
        input.launch = false;
      }
    }

    function onPointerOut(e) {
      if (isMouse(e)) pointer.active = false;
    }

    stage.addEventListener('pointerdown', onPointerDown);
    stage.addEventListener('pointermove', onPointerMove);
    stage.addEventListener('pointerup', onPointerUp);
    stage.addEventListener('pointercancel', onPointerUp);
    stage.addEventListener('pointerleave', onPointerOut);
    // Releasing outside the stage never emits pointerup on it.
    global.addEventListener('pointerup', onPointerUp);
    global.addEventListener('pointercancel', onPointerUp);
    msgEl.addEventListener('click', function () { restart(); });

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
      muteBtn.setAttribute('aria-pressed', muted ? 'true' : 'false');
    }
    muteBtn.addEventListener('click', toggleMute);

    // ---------- effects ----------
    function burst(x, y, color, n, speed) {
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2;
        var s = speed * (0.35 + Math.random() * 0.9);
        particles.push({
          x: x, y: y,
          vx: Math.cos(a) * s, vy: Math.sin(a) * s - 30,
          life: 0.35 + Math.random() * 0.35, t: 0, col: color,
        });
      }
    }
    function stepParticles(dt) {
      for (var i = particles.length - 1; i >= 0; i--) {
        var p = particles[i];
        p.t += dt;
        if (p.t >= p.life) { particles.splice(i, 1); continue; }
        p.vy += 620 * dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        var fade = 1 - p.t / p.life;
        ctx.globalAlpha = fade;
        ctx.fillStyle = fade > 0.6 ? '#ffffff' : p.col;
        var s = fade > 0.5 ? 4 : 3;
        ctx.fillRect(p.x | 0, p.y | 0, s, s);
      }
      ctx.globalAlpha = 1;
    }

    // ---------- memory readers ----------
    function tileAt(c, r) {
      var o = (TILES_OFF + (r * COLS + c) * TILE_STRIDE) / 4;
      return { hp: f32[o + FIELD.tile.hp], kind: f32[o + FIELD.tile.kind] };
    }
    function readBall(i) {
      var o = (BALLS_OFF + i * BALL_STRIDE) / 4, B = FIELD.ball;
      return { x: f32[o + B.x], y: f32[o + B.y], active: f32[o + B.active], stuck: f32[o + B.stuck] };
    }
    function readPower(i) {
      var o = (POWER_OFF + i * POWER_STRIDE) / 4, P = FIELD.power;
      return { x: f32[o + P.x], y: f32[o + P.y], kind: f32[o + P.kind], active: f32[o + P.active] };
    }

    // ---------- drawing ----------
    function tilePalette(kind, hp) {
      if (kind === 3) return SOLID_COLORS;
      if (kind === 2) return BOMB_COLORS;
      if (kind === 1) return hp > 1 ? TOUGH_COLORS : TOUGH_HURT;
      return null; // plain tiles take their colour from their row
    }

    function drawTile(c, r, kind, hp) {
      var x = GRID_X + c * TILE_W, y = GRID_Y + r * TILE_H;
      var pal = tilePalette(kind, hp) || ROW_COLORS[r % ROW_COLORS.length];
      var w = TILE_W - 3, h = TILE_H - 3;

      ctx.fillStyle = pal[0];
      ctx.fillRect(x + 1, y + 1, w, h);
      // bevel: light on the top-left, shadow on the bottom-right
      ctx.fillStyle = pal[1];
      ctx.fillRect(x + 1, y + 1, w, 3);
      ctx.fillRect(x + 1, y + 1, 3, h);
      ctx.fillStyle = pal[2];
      ctx.fillRect(x + 1, y + h - 2, w, 3);
      ctx.fillRect(x + w - 2, y + 1, 3, h);

      if (kind === 2) {
        // bomb: a dark core with a lit fuse
        ctx.fillStyle = '#2b0704';
        ctx.fillRect(x + w / 2 - 6, y + h / 2 - 5, 14, 12);
        ctx.fillStyle = (Math.floor(tGlobal * 9) % 2) ? '#ffd23c' : '#ff7a1e';
        ctx.fillRect(x + w / 2 + 6, y + h / 2 - 9, 4, 5);
      } else if (kind === 3) {
        // solid: rivets, so it reads as "not yours to break"
        ctx.fillStyle = '#20242b';
        ctx.fillRect(x + 6, y + 6, 4, 4);
        ctx.fillRect(x + w - 8, y + 6, 4, 4);
        ctx.fillRect(x + 6, y + h - 8, 4, 4);
        ctx.fillRect(x + w - 8, y + h - 8, 4, 4);
      } else if (kind === 1 && hp <= 1) {
        // a chipped tough tile shows the crack that says "one more"
        ctx.fillStyle = '#2b3038';
        ctx.fillRect(x + 12, y + 7, 3, 12);
        ctx.fillRect(x + 15, y + 12, 10, 3);
        ctx.fillRect(x + 30, y + 9, 3, 9);
      }
    }

    function drawPaddle() {
      var px = f32[FIELD.paddle.x], py = f32[FIELD.paddle.y], half = f32[FIELD.paddle.halfW];
      var w = half * 2, h = PADDLE_HALF_H * 2;
      var x = px - half, y = py - PADDLE_HALF_H;
      var wide = wasm.exports.get_wide() > 0;
      var sticky = wasm.exports.get_sticky() > 0;

      ctx.fillStyle = wide ? '#5ad84a' : '#d8e2ee';
      ctx.fillRect(x, y, w, h);
      ctx.fillStyle = wide ? '#bff5b6' : '#ffffff';
      ctx.fillRect(x, y, w, 3);
      ctx.fillStyle = wide ? '#266620' : '#5b6472';
      ctx.fillRect(x, y + h - 3, w, 3);
      // the ends are what steer the ball, so they are coloured as controls
      ctx.fillStyle = '#ffb02e';
      ctx.fillRect(x, y, 12, h);
      ctx.fillRect(x + w - 12, y, 12, h);
      if (sticky) {
        ctx.fillStyle = 'rgba(90,216,74,0.85)';
        for (var i = 0; i < w; i += 12) ctx.fillRect(x + i + 3, y - 3, 6, 3);
      }
    }

    function drawPower(p) {
      var col = POWER_COLORS[p.kind | 0] || '#ffffff';
      ctx.fillStyle = col;
      ctx.fillRect(p.x - 14, p.y - 9, 28, 18);
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.fillRect(p.x - 14, p.y - 9, 28, 3);
      ctx.fillStyle = 'rgba(0,0,0,0.3)';
      ctx.fillRect(p.x - 14, p.y + 6, 28, 3);
      var icon = sprIcons[p.kind | 0];
      if (icon) ctx.drawImage(icon, Math.round(p.x - icon.width / 2), Math.round(p.y - icon.height / 2));
    }

    function drawBackground() {
      ctx.fillStyle = '#070912';
      ctx.fillRect(0, 0, WORLD_W, WORLD_H);
      // faint grid, so the playfield reads as a lattice even when cleared
      // Solid one-pixel bars rather than stroked hairlines: a 1px stroke drawn
      // into the one-third buffer is a third of a pixel wide, which comes out
      // as an anti-aliased smear rather than a line.
      ctx.fillStyle = 'rgba(120,150,220,0.05)';
      for (var gx = GRID_X; gx <= GRID_X + COLS * TILE_W; gx += TILE_W) {
        ctx.fillRect(gx, 0, LOW_SCALE, WORLD_H);
      }
      for (var gy = GRID_Y; gy <= GRID_Y + ROWS * TILE_H; gy += TILE_H) {
        ctx.fillRect(0, gy, WORLD_W, LOW_SCALE);
      }
      // the floor line: cross it and you lose the ball
      ctx.fillStyle = 'rgba(255,77,109,0.35)';
      ctx.fillRect(0, WORLD_H - 3, WORLD_W, 3);
    }

    function showBanner(text) {
      bannerEl.textContent = text;
      bannerEl.style.opacity = '1';
      clearTimeout(showBanner._t);
      showBanner._t = setTimeout(function () { bannerEl.style.opacity = '0'; }, 1000);
    }

    function snapshotTiles() {
      for (var r = 0; r < ROWS; r++) {
        for (var c = 0; c < COLS; c++) {
          prevTileHp[r * COLS + c] = f32[(TILES_OFF + (r * COLS + c) * TILE_STRIDE) / 4 + FIELD.tile.hp];
        }
      }
    }

    function syncCounters() {
      var e = wasm.exports;
      prev.breaks = e.get_breaks(); prev.chips = e.get_chips(); prev.booms = e.get_booms();
      prev.bounces = e.get_bounces(); prev.powers = e.get_powers(); prev.drains = e.get_drains();
      prev.launches = e.get_launches(); prev.hurts = e.get_hurts(); prev.clears = e.get_clears();
    }

    /** Where did something break? Sparks only — no sound, no shake, no rules. */
    function sparkBrokenTiles() {
      for (var r = 0; r < ROWS; r++) {
        for (var c = 0; c < COLS; c++) {
          var idx = r * COLS + c;
          var hp = f32[(TILES_OFF + idx * TILE_STRIDE) / 4 + FIELD.tile.hp];
          if (prevTileHp[idx] > 0 && hp <= 0) {
            var kind = f32[(TILES_OFF + idx * TILE_STRIDE) / 4 + FIELD.tile.kind];
            var cx = GRID_X + c * TILE_W + TILE_W / 2;
            var cy = GRID_Y + r * TILE_H + TILE_H / 2;
            if (kind === 2) burst(cx, cy, '#ff7a1e', 22, 260);
            else burst(cx, cy, (tilePalette(kind, 1) || ROW_COLORS[r % ROW_COLORS.length])[0], 8, 150);
          }
          prevTileHp[idx] = hp;
        }
      }
    }

    /**
     * What happened this frame, according to the engine's event counters.
     *
     * This used to be inferred: diff every tile's hit points, count live balls,
     * watch lives and level for changes. That is the renderer deciding what
     * the rules did, and it could only hear events that leave a mark in
     * memory — which is why the paddle, power-up and launch sounds below
     * existed in this file for as long as they did without ever being played.
     */
    function pollEvents() {
      var e = wasm.exports, n;

      // A bomb is the boom, not every brick it takes with it: one detonation
      // can clear nine cells and chain into more, and nine brick notes on top
      // of the boom is noise.
      n = e.get_booms();
      if (n > prev.booms) {
        shake = Math.max(shake, 7);
        sound.bomb();
        prev.booms = n;
        prev.breaks = e.get_breaks();
      }
      n = e.get_breaks();
      if (n > prev.breaks) { sound.brick(e.get_last_break_row()); prev.breaks = n; }

      n = e.get_chips();
      if (n > prev.chips) { sound.tough(); prev.chips = n; }

      n = e.get_bounces();
      if (n > prev.bounces) { sound.paddle(); prev.bounces = n; }

      n = e.get_powers();
      if (n > prev.powers) { sound.power(); prev.powers = n; }

      n = e.get_launches();
      if (n > prev.launches) { sound.launch(); prev.launches = n; }

      // a ball lost is worth a sound even when a life is not
      n = e.get_drains();
      if (n > prev.drains) { sound.wall(); prev.drains = n; }

      n = e.get_clears();
      if (n > prev.clears) {
        showBanner('LEVEL ' + e.get_level());
        sound.level();
        snapshotTiles();
        prev.clears = n;
      }

      n = e.get_hurts();
      if (n > prev.hurts) {
        flash = 0.3;
        shake = Math.max(shake, 6);
        sound.lose();
        prev.hurts = n;
      }
    }

    function restart() {
      if (!wasm || destroyed) return;
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      i32 = new Int32Array(wasm.exports.memory.buffer);
      msgEl.style.display = 'none';
      particles.length = 0;
      shake = 0; flash = 0;
      snapshotTiles();
      syncCounters();
      running = true;
    }

    // ---------- main loop ----------
    function loop(now) {
      if (destroyed) return;
      // Clamped at both ends. The ceiling stops a backgrounded tab teleporting
      // the ball across the arena on its first frame back; the floor matters
      // because a negative dt walks the ball to a NaN position, and the first
      // `i32.trunc_f32_s` the engine does on it traps — taking the whole game
      // down rather than dropping a frame. Found with the headless harness.
      var dt = Math.max(0, Math.min((now - lastT) / 1000, 0.05));
      lastT = now;
      tGlobal += dt;

      var anyStuck = false;

      if (running) {
        var dir = (input.right ? 1 : 0) - (input.left ? 1 : 0);
        // The stick is analog: a nudge walks the paddle, a full push sprints it.
        // Held past the deadzone it overrides the keys, which cannot express
        // anything between 0 and 1 anyway.
        if (stick.active && Math.abs(stick.dir) > STICK_DEADZONE) dir = stick.dir;
        wasm.exports.set_input(dir, input.launch ? 1 : 0, pointer.active ? 1 : 0, pointer.x);
        wasm.exports.step(dt);
        // Re-viewed every frame: a memory.grow would detach the old buffer and
        // every read through it would come back as zero.
        f32 = new Float32Array(wasm.exports.memory.buffer);
        i32 = new Int32Array(wasm.exports.memory.buffer);

        sparkBrokenTiles();
        pollEvents();

        if (wasm.exports.is_game_over()) {
          running = false;
          msgEl.style.display = 'block';
          sound.over();
        }
      }

      // ---- render ----
      ctx.setTransform(Z, 0, 0, Z, 0, 0);
      if (shake > 0) {
        ctx.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() - 0.5) * shake / LOW_SCALE),
          Math.round((Math.random() - 0.5) * shake / LOW_SCALE));
        shake = Math.max(0, shake - dt * 26);
      }

      drawBackground();

      for (var rr = 0; rr < ROWS; rr++) {
        for (var cc = 0; cc < COLS; cc++) {
          var t = tileAt(cc, rr);
          if (t.hp !== 0) drawTile(cc, rr, t.kind | 0, t.hp);
        }
      }

      for (var i = 0; i < MAX_POWER; i++) {
        var p = readPower(i);
        if (p.active > 0) drawPower(p);
      }

      drawPaddle();

      var ballsAlive = 0;
      for (i = 0; i < MAX_BALLS; i++) {
        var b = readBall(i);
        if (b.active > 0) {
          ballsAlive++;
          if (b.stuck > 0) anyStuck = true;
          ctx.drawImage(sprBall,
            Math.round(b.x - sprBall.width / 2), Math.round(b.y - sprBall.height / 2));
        }
      }

      stepParticles(dt);

      if (flash > 0) {
        ctx.fillStyle = 'rgba(255,60,90,' + (flash * 0.9).toFixed(3) + ')';
        ctx.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      serveEl.style.opacity = (anyStuck && running) ? '1' : '0';

      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLives.textContent = Math.max(0, Math.round(wasm.exports.get_lives()));
      hudLevel.textContent = wasm.exports.get_level();
      hudTiles.textContent = Math.max(0, wasm.exports.get_tiles_left());

      rafId = requestAnimationFrame(loop);
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
      root.innerHTML = '<div class="gb-fail">Failed to load game engine: ' + err + '</div>';
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
        global.removeEventListener('pointerup', onPointerUp);
        global.removeEventListener('pointercancel', onPointerUp);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          lives: wasm.exports.get_lives(),
          level: wasm.exports.get_level(),
          tilesLeft: wasm.exports.get_tiles_left(),
          gameOver: !!wasm.exports.is_game_over(),
        };
      },
    };
  }

  global.GridBreaker = { mount: mount };

})(window);
