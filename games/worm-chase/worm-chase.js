/* ============================================================
 * WORM CHASE — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="worm-chase.css">
 *   <div id="game"></div>
 *   <script src="worm-chase.js"><\/script>
 *   <script>
 *     var game = WormChase.mount(document.getElementById('game'));
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
  var COLS = 32, ROWS = 24, CELL = 30;
  var WORLD_W = COLS * CELL, WORLD_H = ROWS * CELL;   // 960 x 720
  var CELLS = COLS * ROWS;
  var GRID_OFF = 0, CELL_STRIDE = 4;
  var CHASER_OFF = 6144, CHASER_STRIDE = 32, MAX_CHASERS = 8;
  // Field positions inside each record — bytes for a cell, i32 slots for a
  // chaser — the `@fields` lines in game.wat, copied. Every read goes through
  // this table rather than a bare `u8[a + 3]`, so scripts/check-layout.mjs can
  // see a field that moved.
  var FIELD = {
    cell: { state: 0, hazard: 1, mark: 2, epoch: 3 },
    chaser: { cx: 0, cy: 1, pcx: 2, pcy: 3, dx: 4, dy: 5, active: 6, pad: 7 },
  };
  var PXS = 3;  // chunky pixel scale for the ASCII sprites: 8 glyphs -> 24px
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

  /**
   * Rotate an ASCII grid a quarter turn clockwise. The head is drawn once,
   * facing up, and the other three headings are this function applied 1, 2 and
   * 3 times — which keeps the eyes on the leading edge without four hand-drawn
   * sprites that would inevitably drift apart from each other.
   */
  function rotateRows(rows) {
    var h = rows.length, w = rows[0].length, out = [];
    for (var x = 0; x < w; x++) {
      var line = '';
      for (var y = h - 1; y >= 0; y--) line += rows[y][x];
      out.push(line);
    }
    return out;
  }

  var HEAD_PAL = { L: '#9dffc0', G: '#38d97a', K: '#04140c' };
  var headUp = [
    '..LLLL..',
    '.LGGGGL.',
    'LGKGGKGL',
    'LGKGGKGL',
    'LGGGGGGL',
    'LGGGGGGL',
    '.LGGGGL.',
    '..LLLL..',
  ];

  var CHASER_PAL = { R: '#ff4d6d', D: '#7a0f24', K: '#2b0410' };
  var chaserRows = [
    '..RRRR..',
    '.RRRRRR.',
    'RRKRRKRR',
    'RRKRRKRR',
    'RRRRRRRR',
    'RDRRRRDR',
    '.R.RR.R.',
    'D..RR..D',
  ];

  var HAZARD_PAL = { H: '#ffb02e', D: '#6d3a05' };
  var hazardRows = [
    '...HH...',
    '..HHHH..',
    '.HHDDHH.',
    'HHDDDDHH',
    'HHDDDDHH',
    '.HHDDHH.',
    '..HHHH..',
    '...HH...',
  ];

  // Territory fill, indexed by the epoch byte the engine stamps on capture.
  // Six shades cycling means the board records its own history: you can see
  // which push took which ground without the engine storing a timestamp.
  var EPOCH_FILL = ['#18382a', '#1b4032', '#1d4a3a', '#1a4744', '#204d33', '#25543d'];
  var TERRITORY_EDGE = '#5ef08a';
  var TRAIL_COLOR = '#7cf2ff';

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
      turn:    function () { tone(360, 300, 0.03, 'square', 0.018); },
      // Bigger captures sound bigger. The engine reports how many cells the
      // last one took, and that is the only thing this needs to know.
      capture: function (cells) {
        var n = Math.max(1, Math.min(cells, 260));
        tone(420 + n, 900 + n * 3, 0.14 + n / 2600, 'triangle', 0.06);
        tone(210 + n / 2, 450 + n, 0.2, 'square', 0.03);
      },
      kill:    function () { tone(880, 180, 0.16, 'sawtooth', 0.06); noise(0.12, 0.06); },
      die:     function () { tone(320, 60, 0.5, 'sawtooth', 0.07); noise(0.3, 0.09); },
      level:   function () { tone(520, 1040, 0.3, 'triangle', 0.06); },
      over:    function () { tone(240, 55, 0.9, 'sawtooth', 0.08); },
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
    if (!container) throw new Error('WormChase.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'wc-root';
    root.innerHTML =
      '<div class="wc-hud">' +
        '<span>SCORE <b class="wc-a" data-wc="score">0</b></span>' +
        '<span>LIVES <b class="wc-r" data-wc="lives">5</b></span>' +
        '<span>LEVEL <b class="wc-v" data-wc="level">1</b></span>' +
        '<span>HELD <b data-wc="held">3%</b> / <span data-wc="target">34%</span></span>' +
        '<button type="button" class="wc-mute" data-wc="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="wc-stage">' +
        '<canvas class="wc-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="wc-scan" aria-hidden="true"></div>' +
        '<div class="wc-touch" aria-hidden="true">' +
          // The whole board is the steering zone. A worm turns on both axes, so
          // there is no half of the screen that could be reserved for anything
          // else, and the ring re-anchors under wherever the thumb lands rather
          // than sitting somewhere the player has to look for.
          '<div class="wc-stickzone" data-wc="stickzone">' +
            '<div class="wc-stick" data-wc="stick">' +
              '<div class="wc-stick-knob" data-wc="knob"></div>' +
            '</div>' +
          '</div>' +
        '</div>' +
        '<div class="wc-overlay wc-idle" data-wc="idle">HOLD A DIRECTION TO MOVE</div>' +
        '<div class="wc-overlay wc-banner" data-wc="banner">LEVEL 1</div>' +
        '<div class="wc-overlay wc-msg" data-wc="msg">GAME OVER<small data-wc="msgsmall">PRESS R TO RESTART</small></div>' +
      '</div>' +
      '<div class="wc-help" data-wc="help">' +
        'HOLD [ARROWS]/[WASD] TO MOVE &nbsp; LEAVE YOUR LAND AND LOOP BACK TO CLAIM &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-wc="' + name + '"]'); };
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
    var stage = root.querySelector('.wc-stage');
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level');
    var hudHeld = q('held'), hudTarget = q('target');
    var msgEl = q('msg'), bannerEl = q('banner'), idleEl = q('idle'), helpEl = q('help');
    var muteBtn = q('mute');
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');

    /**
     * Which controls a visitor gets is decided per *event*, by `pointerType`,
     * not by sniffing the device at mount — same reasoning as Grid Breaker's
     * widget. `(pointer: coarse)` describes the *primary* pointer, so it is
     * true on phones and false on a laptop with a touchscreen, which is the
     * right initial guess; a first touch on any device corrects it.
     */
    function enableTouchUI() {
      if (root.classList.contains('wc-is-touch')) return;
      root.classList.add('wc-is-touch');
      helpEl.textContent = 'HOLD AND DRAG ANYWHERE TO MOVE • LOOP BACK TO YOUR LAND TO CLAIM • TAP GAME OVER TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
      idleEl.textContent = 'HOLD AND DRAG TO MOVE';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, u8 = null, i32 = null;
    var destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var facing = { x: 0, y: -1 };          // last non-zero heading, for the sprite
    var stick = { active: false, ox: 0, oy: 0, dx: 0, dy: 0 };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    // Per-cell capture glow. The engine has no idea a screen exists; this is
    // filled by diffing the grid against the previous frame's states.
    var cellFlash = new Float32Array(CELLS);
    var prevState = new Uint8Array(CELLS);
    var prevLevel = 1, prevCaps = 0, prevDeaths = 0, prevKills = 0, prevOver = 0;
    var bannerT = 0, idleT = 0;

    // ---------- sprites ----------
    var sprHead = [];   // 0 = up, 1 = right, 2 = down, 3 = left
    var rows = headUp;
    for (var s = 0; s < 4; s++) {
      sprHead.push(makeSprite(rows, HEAD_PAL, PXS));
      rows = rotateRows(rows);
    }
    var sprChaser = makeSprite(chaserRows, CHASER_PAL, PXS);
    var sprHazard = makeSprite(hazardRows, HAZARD_PAL, PXS);

    // ---------- input ----------
    // Compared against the engine's *current* heading, not the sprite's
    // `facing`: after a death the engine parks the worm with no heading at all
    // while `facing` still remembers the way it was pointing, and a player who
    // presses that same key to set off again must not have it swallowed.
    function steer(dx, dy) {
      if (!wasm) return;
      if (dx === wasm.exports.get_dir_x() && dy === wasm.exports.get_dir_y()) return;
      wasm.exports.set_input(dx, dy);
      if (dx || dy) sound.turn();     // letting go is silent
    }

    var KEYS = {
      ArrowLeft: [-1, 0], a: [-1, 0], A: [-1, 0],
      ArrowRight: [1, 0], d: [1, 0], D: [1, 0],
      ArrowUp: [0, -1], w: [0, -1], W: [0, -1],
      ArrowDown: [0, 1], s: [0, 1], S: [0, 1],
    };

    // Which direction keys are down, most recently pressed last. The worm moves
    // while one is held and stops when the last one is released, so a keyup has
    // to know whether any *other* direction is still down — hence a stack
    // rather than a boolean per key. Releasing a key while another is held
    // hands steering back to that one instead of stopping.
    var held = [];

    function pushHeld(name) {
      var i = held.indexOf(name);
      if (i >= 0) held.splice(i, 1);
      held.push(name);
    }

    function applyHeld() {
      if (!held.length) { steer(0, 0); return; }
      var k = KEYS[held[held.length - 1]];
      steer(k[0], k[1]);
    }

    function onKeyDown(e) {
      var k = KEYS[e.key];
      if (k) {
        // Key auto-repeat fires keydown over and over while a key is held;
        // pushHeld is idempotent and steer() ignores a heading already taken,
        // so the repeats cost nothing.
        pushHeld(e.key);
        applyHeld();
        e.preventDefault();
        return;
      }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
    }

    function onKeyUp(e) {
      if (!KEYS[e.key]) return;
      var i = held.indexOf(e.key);
      if (i >= 0) held.splice(i, 1);
      applyHeld();
      e.preventDefault();
    }

    // A key still down when the tab loses focus never sends its keyup, and the
    // worm would drive on unattended.
    function releaseKeys() {
      held.length = 0;
      steer(0, 0);
    }

    // A thumb still on the glass when the tab loses focus never sends its
    // pointerup, and the knob would stay stuck out at the edge.
    function releaseStick() {
      stick.active = false;
      stick.dx = 0; stick.dy = 0;
      stickEl.classList.remove('wc-active');
      stickEl.style.left = ''; stickEl.style.top = '';
      knobEl.style.transform = 'translate(-50%, -50%)';
      steer(0, 0);            // lifting the thumb stops the worm
    }

    function releaseAll() {
      releaseKeys();
      releaseStick();
    }

    function stagePoint(e) {
      var r = stage.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top, w: r.width, h: r.height };
    }

    function onStickDown(e) {
      if (e.pointerType === 'mouse') return;   // a mouse steers with the keyboard
      enableTouchUI();
      var p = stagePoint(e);
      stick.active = true;
      stick.ox = p.x; stick.oy = p.y;
      stickEl.style.left = (p.x / p.w * 100) + '%';
      stickEl.style.top = (p.y / p.h * 100) + '%';
      stickEl.classList.add('wc-active');
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
      knobEl.style.transform = 'translate(calc(-50% + ' + (dx * k) + 'px), calc(-50% + ' + (dy * k) + 'px))';
      // Snap to the dominant axis past a dead zone. A worm has four headings,
      // so an analog reading would only ever be rounded to one of them — doing
      // it here rather than in the engine keeps set_input honest about what it
      // accepts.
      var dead = reach * 0.42;
      if (len < dead) { steer(0, 0); return; }
      if (Math.abs(dx) > Math.abs(dy)) steer(dx > 0 ? 1 : -1, 0);
      else steer(0, dy > 0 ? 1 : -1);
      e.preventDefault();
    }

    function onStickUp(e) {
      if (e && e.pointerType === 'mouse') return;
      releaseStick();
    }

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    stickZone.addEventListener('pointerdown', onStickDown);
    stickZone.addEventListener('pointermove', onStickMove);
    global.addEventListener('pointerup', onStickUp);
    global.addEventListener('pointercancel', onStickUp);
    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);
    global.addEventListener('blur', releaseAll);
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });
    msgEl.addEventListener('click', function () { restart(); });

    // ---------- particles ----------
    function burst(x, y, n, color, speed) {
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2;
        var v = speed * (0.35 + Math.random() * 0.9);
        particles.push({
          x: x, y: y,
          vx: Math.cos(a) * v, vy: Math.sin(a) * v,
          life: 0.4 + Math.random() * 0.5, age: 0, color: color,
        });
      }
      if (particles.length > 400) particles.splice(0, particles.length - 400);
    }

    function stepParticles(dt) {
      for (var i = particles.length - 1; i >= 0; i--) {
        var p = particles[i];
        p.age += dt;
        if (p.age >= p.life) { particles.splice(i, 1); continue; }
        p.x += p.vx * dt; p.y += p.vy * dt;
        p.vx *= 0.94; p.vy *= 0.94;
        ctx.globalAlpha = 1 - p.age / p.life;
        ctx.fillStyle = p.color;
        ctx.fillRect(Math.round(p.x) - 2, Math.round(p.y) - 2, 4, 4);
      }
      ctx.globalAlpha = 1;
    }

    // ---------- drawing ----------
    function cellCenterX(c) { return c * CELL + CELL / 2; }
    function cellCenterY(r) { return r * CELL + CELL / 2; }

    function drawBoard(dt) {
      var i, c, r, a, st, ep;

      // Territory fills, and the capture glow that fades over them.
      for (r = 0; r < ROWS; r++) {
        for (c = 0; c < COLS; c++) {
          i = r * COLS + c;
          a = GRID_OFF + i * CELL_STRIDE;
          st = u8[a + FIELD.cell.state];
          if (st !== prevState[i]) {
            if (st === 1) cellFlash[i] = 1;
            prevState[i] = st;
          }
          if (st === 1) {
            ep = u8[a + FIELD.cell.epoch];
            ctx.fillStyle = EPOCH_FILL[(ep > 0 ? ep - 1 : 0) % EPOCH_FILL.length];
            ctx.fillRect(c * CELL, r * CELL, CELL, CELL);
          }
          if (cellFlash[i] > 0) {
            ctx.fillStyle = 'rgba(158,255,205,' + (cellFlash[i] * 0.55).toFixed(3) + ')';
            ctx.fillRect(c * CELL, r * CELL, CELL, CELL);
            cellFlash[i] = Math.max(0, cellFlash[i] - dt * 1.6);
          }
        }
      }

      // Grid lines, under everything else that matters.
      // Solid one-pixel bars rather than stroked hairlines: a 1px stroke drawn
      // into the one-third buffer is a third of a pixel wide, which comes out
      // as an anti-aliased smear rather than a line.
      ctx.fillStyle = 'rgba(126,220,180,0.05)';
      for (c = 1; c < COLS; c++) ctx.fillRect(c * CELL, 0, LOW_SCALE, WORLD_H);
      for (r = 1; r < ROWS; r++) ctx.fillRect(0, r * CELL, WORLD_W, LOW_SCALE);

      // The border of owned territory: every edge where an owned cell meets
      // something that is not one. Drawn as a single path so the whole outline
      // is one stroke call however ragged it has become.
      // Each edge is a one-pixel bar inside the owned cell rather than a 2px
      // stroke centred on the boundary, for the same reason as the grid.
      ctx.fillStyle = TERRITORY_EDGE;
      for (r = 0; r < ROWS; r++) {
        for (c = 0; c < COLS; c++) {
          if (u8[GRID_OFF + (r * COLS + c) * CELL_STRIDE + FIELD.cell.state] !== 1) continue;
          var x = c * CELL, y = r * CELL;
          if (c === 0 || u8[GRID_OFF + (r * COLS + c - 1) * CELL_STRIDE + FIELD.cell.state] !== 1) {
            ctx.fillRect(x, y, LOW_SCALE, CELL);
          }
          if (c === COLS - 1 || u8[GRID_OFF + (r * COLS + c + 1) * CELL_STRIDE + FIELD.cell.state] !== 1) {
            ctx.fillRect(x + CELL - LOW_SCALE, y, LOW_SCALE, CELL);
          }
          if (r === 0 || u8[GRID_OFF + ((r - 1) * COLS + c) * CELL_STRIDE + FIELD.cell.state] !== 1) {
            ctx.fillRect(x, y, CELL, LOW_SCALE);
          }
          if (r === ROWS - 1 || u8[GRID_OFF + ((r + 1) * COLS + c) * CELL_STRIDE + FIELD.cell.state] !== 1) {
            ctx.fillRect(x, y + CELL - LOW_SCALE, CELL, LOW_SCALE);
          }
        }
      }

      // Trail and hazards.
      // The trail: a node per cell plus a bar bridging each gap to the next
      // one. Drawing only the nodes leaves a dotted line, and a dotted line
      // does not look like something a chaser could cut — which is the one
      // thing the player has to understand about it at a glance.
      var pulse = 0.62 + 0.38 * Math.sin(tGlobal * 9);
      var pad = 7, span = CELL - pad * 2;
      // No glow: the trail used to carry a shadowBlur halo, which is the one
      // effect that marks a picture as post-1995. It is bright enough on its
      // own against the dark board, and brighter still at the top of its pulse.
      ctx.fillStyle = 'rgba(124,242,255,' + pulse.toFixed(3) + ')';
      for (r = 0; r < ROWS; r++) {
        for (c = 0; c < COLS; c++) {
          if (u8[GRID_OFF + (r * COLS + c) * CELL_STRIDE + FIELD.cell.state] !== 2) continue;
          var tx = c * CELL, ty = r * CELL;
          ctx.fillRect(tx + pad, ty + pad, span, span);
          // Only right and down, so each join is drawn once.
          if (c < COLS - 1 && u8[GRID_OFF + (r * COLS + c + 1) * CELL_STRIDE + FIELD.cell.state] === 2) {
            ctx.fillRect(tx + CELL - pad, ty + pad, pad * 2, span);
          }
          if (r < ROWS - 1 && u8[GRID_OFF + ((r + 1) * COLS + c) * CELL_STRIDE + FIELD.cell.state] === 2) {
            ctx.fillRect(tx + pad, ty + CELL - pad, span, pad * 2);
          }
        }
      }

      for (r = 0; r < ROWS; r++) {
        for (c = 0; c < COLS; c++) {
          if (!u8[GRID_OFF + (r * COLS + c) * CELL_STRIDE + FIELD.cell.hazard]) continue;
          ctx.drawImage(sprHazard,
            Math.round(cellCenterX(c) - sprHazard.width / 2),
            Math.round(cellCenterY(r) - sprHazard.height / 2));
        }
      }
    }

    function drawChasers() {
      var f = wasm.exports.get_chase_frac();
      // One view over the whole buffer, made once at boot. A fresh
      // Int32Array per chaser per frame would be 480 throwaway objects a
      // second for eight records that never move.
      for (var i = 0; i < MAX_CHASERS; i++) {
        var w = (CHASER_OFF + i * CHASER_STRIDE) >> 2;
        var C = FIELD.chaser;
        if (!i32[w + C.active]) continue;
        var cx = i32[w + C.pcx] + (i32[w + C.cx] - i32[w + C.pcx]) * f;
        var cy = i32[w + C.pcy] + (i32[w + C.cy] - i32[w + C.pcy]) * f;
        ctx.drawImage(sprChaser,
          Math.round(cx * CELL + CELL / 2 - sprChaser.width / 2),
          Math.round(cy * CELL + CELL / 2 - sprChaser.height / 2));
      }
    }

    function drawWorm() {
      var e = wasm.exports;
      var dx = e.get_dir_x(), dy = e.get_dir_y();
      if (dx || dy) { facing.x = dx; facing.y = dy; }
      // Standing still means the last tick completed, so the head belongs at
      // its current cell — frac 1, not 0, which would draw it a cell behind.
      var f = (dx || dy) ? e.get_tick_frac() : 1;
      var wx = e.get_prev_x() + (e.get_head_x() - e.get_prev_x()) * f;
      var wy = e.get_prev_y() + (e.get_head_y() - e.get_prev_y()) * f;

      var idx = 0;
      if (facing.x > 0) idx = 1;
      else if (facing.y > 0) idx = 2;
      else if (facing.x < 0) idx = 3;

      var spr = sprHead[idx];
      ctx.drawImage(spr,
        Math.round(wx * CELL + CELL / 2 - spr.width / 2),
        Math.round(wy * CELL + CELL / 2 - spr.height / 2));
    }

    // ---------- engine events ----------
    // The engine never calls out. It counts, and this reads the counters —
    // one place where "what just happened" is decided, so sound, particles and
    // shake can never disagree about it.
    function pollEvents() {
      var e = wasm.exports;

      var caps = e.get_capture_count();
      if (caps > prevCaps) {
        var cells = e.get_capture_cells();
        sound.capture(cells);
        burst(cellCenterX(e.get_head_x()), cellCenterY(e.get_head_y()),
              Math.min(10 + Math.floor(cells / 4), 60), '#9effcd', 190);
        prevCaps = caps;
      }

      var kills = e.get_kills();
      if (kills > prevKills) { sound.kill(); shake = Math.max(shake, 0.18); prevKills = kills; }

      var deaths = e.get_deaths();
      if (deaths > prevDeaths) {
        sound.die();
        shake = Math.max(shake, 0.45);
        flash = 0.5;
        burst(cellCenterX(e.get_head_x()), cellCenterY(e.get_head_y()), 40, '#ff4d6d', 260);
        prevDeaths = deaths;
      }

      var level = e.get_level();
      if (level !== prevLevel) {
        sound.level();
        bannerEl.textContent = 'LEVEL ' + level;
        bannerT = 1.3;
        prevLevel = level;
        cellFlash.fill(0);
        prevState.fill(0);
      }

      var over = e.is_game_over();
      if (over && !prevOver) { sound.over(); msgEl.style.display = 'block'; }
      prevOver = over;
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      var dt = Math.min((now - lastT) / 1000, 0.1);
      lastT = now;
      tGlobal += dt;

      wasm.exports.step(dt);
      pollEvents();

      ctx.setTransform(Z, 0, 0, Z, 0, 0);
      ctx.fillStyle = '#060c0e';
      ctx.fillRect(0, 0, WORLD_W, WORLD_H);

      if (shake > 0) {
        var m = shake * 14;
        ctx.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m / LOW_SCALE),
          Math.round((Math.random() * 2 - 1) * m / LOW_SCALE));
        shake = Math.max(0, shake - dt * 1.6);
      }

      drawBoard(dt);
      drawChasers();
      drawWorm();
      stepParticles(dt);

      ctx.setTransform(Z, 0, 0, Z, 0, 0);
      if (flash > 0) {
        ctx.fillStyle = 'rgba(255,60,90,' + (flash * 0.8).toFixed(3) + ')';
        ctx.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.8);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      // Overlays.
      if (bannerT > 0) { bannerT -= dt; bannerEl.style.opacity = bannerT > 0 ? '1' : '0'; }
      // Stopping is a move now, not a mistake, so the prompt waits out a real
      // pause instead of flashing every time a key comes up.
      var stopped = !wasm.exports.get_dir_x() && !wasm.exports.get_dir_y();
      idleT = stopped ? idleT + dt : 0;
      idleEl.style.opacity = (idleT > 1.2 && !wasm.exports.is_game_over()) ? '1' : '0';

      // HUD.
      var owned = wasm.exports.get_owned(), total = wasm.exports.get_total();
      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLives.textContent = Math.max(0, Math.round(wasm.exports.get_lives()));
      hudLevel.textContent = wasm.exports.get_level();
      hudHeld.textContent = Math.round(owned / total * 100) + '%';
      hudTarget.textContent = Math.round(wasm.exports.get_target() / total * 100) + '%';

      rafId = requestAnimationFrame(loop);
    }

    function restart() {
      if (!wasm) return;
      wasm.exports.init();
      u8 = new Uint8Array(wasm.exports.memory.buffer);
      i32 = new Int32Array(wasm.exports.memory.buffer);
      particles.length = 0;
      cellFlash.fill(0);
      prevState.fill(0);
      shake = 0; flash = 0; bannerT = 0; idleT = 0;
      facing.x = 0; facing.y = -1;
      prevLevel = wasm.exports.get_level();
      prevCaps = wasm.exports.get_capture_count();
      prevDeaths = wasm.exports.get_deaths();
      prevKills = wasm.exports.get_kills();
      prevOver = 0;
      msgEl.style.display = 'none';
      bannerEl.style.opacity = '0';
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) { return WebAssembly.instantiate(buf, {}); });
    } else {
      // No imports at all: this engine needs no maths JavaScript could lend it.
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), {});
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="wc-fail">Failed to load game engine: ' + err + '</div>';
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
        global.removeEventListener('pointerup', onStickUp);
        global.removeEventListener('pointercancel', onStickUp);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          lives: wasm.exports.get_lives(),
          level: wasm.exports.get_level(),
          owned: wasm.exports.get_owned(),
          target: wasm.exports.get_target(),
          total: wasm.exports.get_total(),
          gameOver: !!wasm.exports.is_game_over(),
        };
      },
    };
  }

  global.WormChase = { mount: mount };

})(window);
