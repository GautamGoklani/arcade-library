/* ============================================================
 * PIXEL WAVE — embeddable retro arcade game widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="pixel-wave.css">
 *   <div id="game"></div>
 *   <script src="pixel-wave.js"><\/script>
 *   <script>
 *     const game = PixelWave.mount(document.getElementById('game'));
 *     // game.restart(); game.destroy(); game.getState();
 *   <\/script>
 *
 * Host page should include (for mobile):
 *   <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
 * ============================================================ */
(function (global) {
  'use strict';

  // ---- constants: MUST match game.wat memory layout ----
  var WORLD_W = 1200, WORLD_H = 750;
  var BOTS_OFF = 24, BOT_STRIDE = 40, MAX_BOTS = 33;
  var BULLETS_OFF = 1344, BULLET_STRIDE = 24, MAX_BULLETS = 160;
  var AST_OFF = 5184, AST_STRIDE = 24, MAX_AST = 20;
  var PXS = 3; // chunky pixel scale

  var WASM_B64 = "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";

  // ============================================================
  // PIXEL SPRITES (ASCII grids -> offscreen canvases)
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

  var P_PAL = { W:'#f2f6ff', R:'#e8283c', B:'#2450d8', C:'#39d5ff', G:'#9aa6b8', D:'#3e4756', Y:'#ffd23c' };
  var playerRows = [
    '.......W.......',
    '.......W.......',
    '......WCW......',
    '......WCW......',
    '..D...WBW...D..',
    '..RD..WBW..DR..',
    '..RD.WWBWW.DR..',
    '..RW.WBBBW.WR..',
    '..RWWWBBBWWWR..',
    '.RRWWWWBWWWWRR.',
    '.RWWRWWWWWRWWR.',
    '.RWRRWDWDWRRWR.',
    '.WWRWWDWDWWRWW.',
    'WWWRWWWWWWWRWWW',
    'WW.RW.WWW.WR.WW',
    'W..R..WWW..R..W',
    '......W.W......',
    '.....W...W.....',
  ];
  var FLAME_PAL = { Y:'#ffd23c', O:'#ff7a1e', R:'#e8283c', W:'#fff7d9' };
  var flameRows1 = [
    '..Y.Y..',
    '..YWY..',
    '..OWO..',
    '...O...',
    '...R...',
  ];
  var flameRows2 = [
    '..Y.Y..',
    '..YWY..',
    '..OWO..',
    '..O.O..',
    '..R.R..',
    '...R...',
  ];
  var A_PAL = { M:'#ff3fd1', W:'#ffffff', G:'#20e648', D:'#8a1070' };
  var crabA1 = [
    '..M.......M..',
    '...M.....M...',
    '..MMMMMMMMM..',
    '.MM.MMMMM.MM.',
    'MMM.MMMMM.MMM',
    'MMMMMMMMMMMMM',
    'M.MMMMMMMMM.M',
    'M.M.......M.M',
    '...MM...MM...',
    '..M..M.M..M..',
  ];
  var crabA2 = [
    '..M.......M..',
    '...M.....M...',
    '..MMMMMMMMM..',
    '.MM.MMMMM.MM.',
    'MMM.MMMMM.MMM',
    'MMMMMMMMMMMMM',
    '..MMMMMMMMM..',
    '.M.M.....M.M.',
    'M...MM.MM...M',
    '.M..M...M..M.',
  ];
  var crabEyes = [
    '.............',
    '.............',
    '.............',
    '....W...W....',
    '....W...W....',
    '.............',
    '.............',
    '.............',
    '.............',
    '.............',
  ];
  var B_PAL = { Y:'#ffdd33', R:'#ff2222', B:'#3355ff', W:'#ffffff', D:'#884400' };
  var hornB1 = [
    '.....RRR.....',
    '....RRRRR....',
    '.Y..RWRWR..Y.',
    '.YY.RRRRR.YY.',
    '.YYYBBBBBYYY.',
    'YYBBBYBYBBBYY',
    'YB.BBBBBBB.BY',
    'Y..BYYYYYB..Y',
    '....Y...Y....',
    '...Y.....Y...',
  ];
  var hornB2 = [
    '.....RRR.....',
    '....RRRRR....',
    '....RWRWR....',
    '.Y..RRRRR..Y.',
    '.YYYBBBBBYYY.',
    '.YBBBYBYBBBY.',
    'YYB.BBBBB.BYY',
    'Y...BYYYB...Y',
    '.....Y.Y.....',
    '....Y...Y....',
  ];
  var C_PAL = { G:'#20e648', W:'#ffffff', D:'#0a6622', R:'#ff2222' };
  var skulC1 = [
    '...GGGGGGG...',
    '..GGGGGGGGG..',
    '.GGWWGGGWWGG.',
    '.GGWRGGGRWGG.',
    '.GGGGGGGGGGG.',
    '..GGG.G.GGG..',
    '...GGGGGGG...',
    '..G.G.G.G.G..',
    '.G..G...G..G.',
    '....G...G....',
  ];
  var skulC2 = [
    '...GGGGGGG...',
    '..GGGGGGGGG..',
    '.GGWWGGGWWGG.',
    '.GGRWGGGWRGG.',
    '.GGGGGGGGGGG.',
    '..GGG.G.GGG..',
    '...GGGGGGG...',
    '..G..G.G..G..',
    '.G...G.G...G.',
    '...G.....G...',
  ];
  var PB_PAL = { C:'#39d5ff', W:'#ffffff' };
  var playerBoltRows = [
    '.W.',
    'WCW',
    'WCW',
    '.C.',
    '.C.',
  ];
  var EB_PAL = { R:'#ff3355', Y:'#ffdd33', W:'#fff' };
  var enemyBoltRows = [
    '.R.',
    'RYR',
    '.R.',
    'R.R',
    '.R.',
  ];

  // pre-render all shared sprites once (shared across instances)
  var sprPlayer = makeSprite(playerRows, P_PAL, PXS);
  var sprFlame1 = makeSprite(flameRows1, FLAME_PAL, PXS);
  var sprFlame2 = makeSprite(flameRows2, FLAME_PAL, PXS);
  var sprCrab = [makeSprite(crabA1, A_PAL, PXS), makeSprite(crabA2, A_PAL, PXS)];
  var sprCrabEyes = makeSprite(crabEyes, A_PAL, PXS);
  var sprHorn = [makeSprite(hornB1, B_PAL, PXS), makeSprite(hornB2, B_PAL, PXS)];
  var sprSkul = [makeSprite(skulC1, C_PAL, PXS), makeSprite(skulC2, C_PAL, PXS)];
  var sprPBolt = makeSprite(playerBoltRows, PB_PAL, PXS);
  var sprEBolt = makeSprite(enemyBoltRows, EB_PAL, PXS);

  function base64ToBytes(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  // ============================================================
  // SOUND — synthesised, no audio files and nothing to license.
  //
  // This title shipped silent. Sound was the first item on its own roadmap and
  // the eight games built after it each grew a synthesiser of their own, so it
  // ended up the one quiet cabinet in the arcade. What it was missing was never
  // really the eighty lines below: it was the event counters in game.wat,
  // because a sound has to know *that* something happened, and this widget used
  // to find out by watching flags change — which cannot tell a kill from a ram,
  // and hears two kills in one frame as one.
  //
  // The AudioContext is created on the first sound, because browsers refuse to
  // start audio outside a user gesture — and the first sound is always the
  // player's own shot, which is a gesture.
  // ============================================================
  function createSound() {
    var ctx = null, muted = false;
    // Bots fire often, and thirty-odd of them late on is a lot of oscillators
    // for a sound nobody needs to hear individually. One enemy shot every
    // 110ms is plenty to know the screen is hostile.
    var lastEnemy = 0;

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
      // One per round. A burst is three of these 90ms apart, which is what
      // makes the burst audible as a burst rather than as a single press.
      shot: function () { tone(980, 420, 0.05, 'square', 0.028); },
      enemyShot: function (now) {
        if (now - lastEnemy < 110) return;
        lastEnemy = now;
        tone(300, 190, 0.07, 'triangle', 0.018);
      },
      kill: function () { noise(0.14, 0.06); tone(520, 140, 0.16, 'square', 0.04); },
      rock: function () { noise(0.2, 0.08); tone(160, 60, 0.2, 'sawtooth', 0.04); },
      hurt: function () { noise(0.35, 0.11); tone(240, 50, 0.4, 'sawtooth', 0.07); },
      // A wave cleared is a rising three-note figure: the one moment in this
      // game that is good news, so it is the one sound that goes up.
      wave: function () {
        tone(392, 392, 0.1, 'square', 0.04);
        tone(523, 523, 0.1, 'square', 0.04, 0.1);
        tone(784, 784, 0.18, 'square', 0.04, 0.2);
      },
      over: function () { tone(260, 40, 1.0, 'sawtooth', 0.085); },
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
    if (!container) throw new Error('PixelWave.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'ss-root';
    root.innerHTML =
      '<div class="ss-hud">' +
        '<span>SCORE <b class="ss-c" data-ss="score">0</b></span>' +
        '<span>LIVES <b class="ss-r" data-ss="lives">3</b></span>' +
        '<span>LEVEL <b class="ss-y" data-ss="level">1</b></span>' +
        '<span>ENEMIES <b data-ss="bots">0</b></span>' +
        '<button type="button" class="ss-mute" data-ss="mute">SOUND ON</button>' +
      '</div>' +
      '<div class="ss-stage">' +
        '<canvas class="ss-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="ss-overlay ss-msg" data-ss="msg">GAME OVER<small data-ss="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="ss-overlay ss-levelbanner" data-ss="banner">LEVEL 1</div>' +
        '<div class="ss-touch">' +
          // Left half is one big capture zone; the ring inside it re-anchors to
          // wherever the thumb lands, so the stick is never somewhere you have
          // to look for.
          '<div class="ss-stickzone" data-ss="stickzone">' +
            '<div class="ss-stick" data-ss="stick">' +
              '<div class="ss-stick-knob" data-ss="knob"></div>' +
            '</div>' +
          '</div>' +
          '<div class="ss-btn ss-btn-thrust" data-ss="btnT">THRUST</div>' +
          '<div class="ss-btn ss-btn-fire" data-ss="btnF">FIRE</div>' +
        '</div>' +
      '</div>' +
      '<div class="ss-help" data-ss="help">[W] THRUST &nbsp; [A]/[D] ROTATE &nbsp; [SPACE] FIRE &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-ss="' + name + '"]'); };
    var stage = root.querySelector('.ss-stage');
    var canvas = root.querySelector('canvas');
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level'), hudBots = q('bots');
    var msgEl = q('msg'), bannerEl = q('banner'), helpEl = q('help');
    var muteBtn = q('mute');

    // ---------- control mode ----------
    // Driven by what the player actually touches, not by what the hardware is
    // capable of. The old check OR'd in `'ontouchstart' in window`, which is true
    // on any machine that merely HAS a touchscreen \u2014 Windows touch laptops,
    // touch Chromebooks \u2014 so mouse-and-keyboard players got the on-screen
    // controls parked over the arena. It also ran once at mount, so an iPad that
    // gained or lost a keyboard kept whatever it guessed on load.
    //
    // `(pointer: coarse)` is the correct question (is the PRIMARY input coarse)
    // and only seeds the initial guess; the first real touch or keypress after
    // that corrects it, in either direction, for as long as the game is up.
    var touchMode = null;

    function setTouchMode(on) {
      if (touchMode === on) return;
      touchMode = on;
      root.classList.toggle('ss-is-touch', on);
      helpEl.textContent = on
        ? 'DRAG LEFT TO AIM \u2022 THRUST + FIRE RIGHT \u2022 TAP GAME OVER TO RESTART'
        : '[W] THRUST \u00a0 [A]/[D] ROTATE \u00a0 [SPACE] FIRE \u00a0 [R] RESTART \u00a0 [M] MUTE';
      q('msgsmall').textContent = on ? 'TAP TO RESTART' : 'PRESS R TO RESTART';
      // Switching away from touch has to drop anything the on-screen controls
      // were holding, or a hidden button stays latched on forever.
      if (!on) releaseAllPointers();
    }

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var running = false, destroyed = false;
    var tGlobal = 0;
    var input = { left: false, right: false, thrust: false, fire: false };
    // Thumbstick: `angle` is the heading being asked for in screen space, which
    // is the same convention the engine stores heading in, so it feeds through
    // without conversion. `mag` scales the turn rate — a nudge turns gently.
    var stick = { active: false, angle: 0, mag: 0, originX: 0, originY: 0 };
    var explosions = [];
    var prevBotAlive = new Array(MAX_BOTS).fill(0);
    var prevAstActive = new Array(MAX_AST).fill(0);
    // The engine's event counters as of last frame. These replaced watching
    // the lives float and the level number for changes — see pollEvents().
    var prev = { shots: 0, enemyShots: 0, kills: 0, rocks: 0, hurts: 0, waves: 0 };
    var screenFlash = 0;
    var sound = createSound();
    var muted = false;
    var rafId = 0;

    // ---------- keyboard ----------
    // Any recognised game key is proof a keyboard is in use, so it hands control
    // back from the on-screen stick. Scoped to the game's own keys so a browser
    // shortcut or assistive-tech keypress does not flip the mode.
    function isGameKey(k) {
      return k === 'a' || k === 'd' || k === 'w' || k === 'r' || k === 'R' || k === ' ' ||
             k === 'm' || k === 'M' ||
             k === 'ArrowLeft' || k === 'ArrowRight' || k === 'ArrowUp';
    }
    // Every key the game claims is also swallowed. Arrow keys and space scroll
    // the host page otherwise, which on an embedded widget means the arena
    // walks off the top of the screen the moment anyone plays. Only the keys
    // listed above are taken; everything else still reaches the page.
    function onKeyDown(e) {
      if (!isGameKey(e.key)) return;
      setTouchMode(false);
      if (e.key === 'a' || e.key === 'ArrowLeft') input.left = true;
      if (e.key === 'd' || e.key === 'ArrowRight') input.right = true;
      if (e.key === 'w' || e.key === 'ArrowUp') input.thrust = true;
      if (e.key === ' ') input.fire = true;
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
      e.preventDefault();
    }
    function onKeyUp(e) {
      if (!isGameKey(e.key)) return;
      if (e.key === 'a' || e.key === 'ArrowLeft') input.left = false;
      if (e.key === 'd' || e.key === 'ArrowRight') input.right = false;
      if (e.key === 'w' || e.key === 'ArrowUp') input.thrust = false;
      if (e.key === ' ') input.fire = false;
      e.preventDefault();
    }
    // Alt-tabbing away never delivers the keyup, so without this the ship
    // keeps thrusting and firing while the tab is in the background and the
    // player comes back to a wreck. Every other title in games/ does this; this
    // one predates the convention.
    function releaseAll() {
      input.left = input.right = input.thrust = input.fire = false;
    }
    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);
    global.addEventListener('blur', releaseAll);

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });

    // ---------- touch: one stick, two buttons ----------
    // Everything routes through a single set of listeners on the stage, keyed by
    // pointerId. The old version bound touch* AND pointer* per button, which meant
    // a second finger on one button released it for the first, a cancelled
    // gesture could leave thrust latched on, and sliding between the two rotate
    // buttons dropped input entirely. One registry, one release path, no latching.
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');
    var btnT = q('btnT'), btnF = q('btnF');

    // Below this fraction of the ring radius the thumb is treated as centred, so
    // resting on the pad holds heading instead of jittering it.
    var STICK_DEADZONE = 0.18;
    // Heading error (radians) at which rotation saturates. Inside it the turn
    // rate eases off proportionally, which is what stops the ship overshooting
    // the angle you asked for and hunting around it.
    var STICK_SNAP = 0.40;

    var pointers = new Map();   // pointerId -> { kind:'stick' } | { kind:'btn', el, prop }

    // Places the ring so its centre sits under the thumb, clamped to stay inside
    // the zone rather than hanging off the edge of the arena.
    function anchorStick(cx, cy) {
      var zr = stickZone.getBoundingClientRect();
      var r = stickEl.offsetWidth / 2;
      var x = Math.max(r, Math.min(zr.width - r, cx - zr.left));
      var y = Math.max(r, Math.min(zr.height - r, cy - zr.top));
      stick.originX = zr.left + x;
      stick.originY = zr.top + y;
      stickEl.style.left = x + 'px';
      stickEl.style.top = y + 'px';
      stickEl.classList.add('ss-active');
    }

    function moveStick(cx, cy) {
      var r = stickEl.offsetWidth / 2 || 1;
      var dx = cx - stick.originX, dy = cy - stick.originY;
      var dist = Math.sqrt(dx * dx + dy * dy);
      stick.mag = Math.min(1, dist / r);
      if (dist > 0.0001) stick.angle = Math.atan2(dy, dx);
      var k = Math.min(1, r / (dist || 1));
      knobEl.style.transform = 'translate(-50%,-50%) translate(' + (dx * k) + 'px,' + (dy * k) + 'px)';
    }

    function releaseStick() {
      stick.active = false;
      stick.mag = 0;
      stickEl.classList.remove('ss-active');
      stickEl.style.left = '';
      stickEl.style.top = '';
      knobEl.style.transform = 'translate(-50%,-50%)';
    }

    // Clears every held input. Used when the controls are taken away mid-hold.
    function releaseAllPointers() {
      pointers.forEach(function (p) {
        if (p.kind === 'stick') releaseStick();
        else { input[p.prop] = false; p.el.classList.remove('ss-active'); }
      });
      pointers.clear();
    }

    // Hit-tests by geometry rather than by event target, so the touch that turns
    // the controls on can also be the touch that starts steering — the zone was
    // still display:none when the event fired, so it was never the target.
    function inside(el, x, y) {
      var r = el.getBoundingClientRect();
      return r.width > 0 && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    }

    function onPointerDown(e) {
      if (e.pointerType === 'touch') setTouchMode(true);

      // Game-over text is tappable (touch has no R key) and sits above the zone.
      if (msgEl.style.display === 'block' && msgEl.contains(e.target)) {
        e.preventDefault();
        restart();
        return;
      }
      if (!touchMode) return;

      var btn = inside(btnT, e.clientX, e.clientY) ? btnT
              : inside(btnF, e.clientX, e.clientY) ? btnF : null;
      if (btn) {
        var prop = btn === btnT ? 'thrust' : 'fire';
        e.preventDefault();
        pointers.set(e.pointerId, { kind: 'btn', el: btn, prop: prop });
        input[prop] = true;
        btn.classList.add('ss-active');
        return;
      }
      if (!stick.active && inside(stickZone, e.clientX, e.clientY)) {
        e.preventDefault();
        pointers.set(e.pointerId, { kind: 'stick' });
        stick.active = true;
        anchorStick(e.clientX, e.clientY);
        moveStick(e.clientX, e.clientY);
      }
    }

    function onPointerMove(e) {
      var p = pointers.get(e.pointerId);
      if (!p || p.kind !== 'stick') return;
      e.preventDefault();
      moveStick(e.clientX, e.clientY);
    }

    // Covers pointerup, pointercancel and the browser stealing the pointer.
    // Buttons stay held while the thumb slides off them — only a real release
    // clears them, which is far more forgiving mid-firefight.
    function stillHeld(prop) {
      var held = false;
      pointers.forEach(function (p) { if (p.kind === 'btn' && p.prop === prop) held = true; });
      return held;
    }

    function onPointerUp(e) {
      var p = pointers.get(e.pointerId);
      if (!p) return;
      pointers.delete(e.pointerId);
      if (p.kind === 'stick') {
        releaseStick();
      } else if (!stillHeld(p.prop)) {
        // Only the last finger off a button releases it. Two thumbs land on FIRE
        // more often than you'd think, and lifting one used to stop the shooting.
        input[p.prop] = false;
        p.el.classList.remove('ss-active');
      }
    }

    // Only the press is scoped to the stage. Move and release live on the window
    // so a thumb that wanders outside the arena still steers, and so a release
    // that happens anywhere at all still clears the input it started.
    stage.addEventListener('pointerdown', onPointerDown);
    global.addEventListener('pointermove', onPointerMove);
    global.addEventListener('pointerup', onPointerUp);
    global.addEventListener('pointercancel', onPointerUp);

    // Seed the initial guess now that the release path it may call exists. From
    // here on, real input decides.
    setTouchMode(!!(global.matchMedia && global.matchMedia('(pointer: coarse)').matches));

    // ---------- pixel asteroids (per-instance cache) ----------
    var astSprites = new Map();
    function getAstSprite(idx, radius) {
      var key = idx + '_' + Math.round(radius);
      var s = astSprites.get(key);
      if (s) return s;
      var seed = idx * 977 + Math.round(radius * 13);
      function r() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed % 1000) / 1000; }
      var gridR = Math.max(4, Math.round(radius / PXS));
      var size = gridR * 2 + 1;
      var cv = document.createElement('canvas');
      cv.width = size * PXS; cv.height = size * PXS;
      var c = cv.getContext('2d');
      var lumps = [], nl = 8, i;
      for (i = 0; i < nl; i++) lumps.push(0.7 + r() * 0.4);
      function radAt(ang) {
        var t = ((ang / (Math.PI * 2)) * nl + nl) % nl;
        var i0 = Math.floor(t) % nl, i1 = (i0 + 1) % nl, fr = t - Math.floor(t);
        return gridR * (lumps[i0] * (1 - fr) + lumps[i1] * fr);
      }
      var craters = [];
      for (i = 0; i < 3; i++) {
        var a = r() * Math.PI * 2, d = r() * gridR * 0.5;
        craters.push([gridR + Math.cos(a) * d, gridR + Math.sin(a) * d, 1 + r() * gridR * 0.3]);
      }
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          var dx = x - gridR, dy = y - gridR;
          var dd = Math.sqrt(dx * dx + dy * dy);
          var ang2 = Math.atan2(dy, dx);
          if (dd > radAt(ang2)) continue;
          var col = '#7a6a54';
          var lit = (dx * -0.7 + dy * -0.7) / gridR;
          if (lit > 0.35) col = '#a89577';
          else if (lit < -0.35) col = '#4a4034';
          for (var k = 0; k < craters.length; k++) {
            var cd = Math.sqrt((x - craters[k][0]) * (x - craters[k][0]) + (y - craters[k][1]) * (y - craters[k][1]));
            if (cd < craters[k][2]) col = '#332b22';
            else if (cd < craters[k][2] + 0.9 && lit <= 0.35) col = '#5a4e3e';
          }
          if (((x + y) & 1) === 0 && r() < 0.12) col = '#6a5c48';
          c.fillStyle = col;
          c.fillRect(x * PXS, y * PXS, PXS, PXS);
        }
      }
      astSprites.set(key, cv);
      return cv;
    }

    // ---------- explosions ----------
    function spawnExplosion(x, y, big, col) {
      var parts = [];
      var n = big ? 26 : 14;
      for (var i = 0; i < n; i++) {
        var a = Math.random() * Math.PI * 2;
        var sp = 40 + Math.random() * (big ? 190 : 130);
        parts.push({ x: x, y: y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, life: 0.45 + Math.random() * 0.3 });
      }
      explosions.push({ parts: parts, t: 0, col: col });
    }
    function updateDrawExplosions(dt) {
      for (var i = explosions.length - 1; i >= 0; i--) {
        var ex = explosions[i];
        ex.t += dt;
        var alive = false;
        for (var j = 0; j < ex.parts.length; j++) {
          var p = ex.parts[j];
          if (ex.t > p.life) continue;
          alive = true;
          p.x += p.vx * dt; p.y += p.vy * dt;
          var fade = 1 - ex.t / p.life;
          ctx.fillStyle = fade > 0.55 ? '#ffffff' : (fade > 0.3 ? ex.col : '#883311');
          var s = fade > 0.5 ? PXS + 1 : PXS;
          ctx.fillRect(Math.round(p.x), Math.round(p.y), s, s);
        }
        if (!alive) explosions.splice(i, 1);
      }
    }

    // ---------- starfield ----------
    var stars = [];
    (function () {
      var seed = 424242;
      function r() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed % 10000) / 10000; }
      for (var i = 0; i < 150; i++) {
        var big = r() < 0.15;
        stars.push({
          x: Math.floor(r() * WORLD_W), y: Math.floor(r() * WORLD_H), s: big ? 3 : 2,
          col: r() < 0.12 ? '#7fb4ff' : (r() < 0.2 ? '#ffd9a0' : '#cfd8e8'),
          tw: r() * 6.28, spd: 0.6 + r() * 1.8
        });
      }
    })();
    function drawStars() {
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        var a = 0.3 + 0.55 * (0.5 + 0.5 * Math.sin(tGlobal * s.spd + s.tw));
        ctx.globalAlpha = a;
        ctx.fillStyle = s.col;
        ctx.fillRect(s.x, s.y, s.s, s.s);
      }
      ctx.globalAlpha = 1;
    }

    // ---------- CRT overlay ----------
    var scanCv = document.createElement('canvas');
    scanCv.width = WORLD_W; scanCv.height = WORLD_H;
    (function () {
      var c = scanCv.getContext('2d');
      c.fillStyle = 'rgba(0,0,0,0.16)';
      for (var y = 0; y < WORLD_H; y += 3) c.fillRect(0, y, WORLD_W, 1);
      var g = c.createRadialGradient(WORLD_W / 2, WORLD_H / 2, 300, WORLD_W / 2, WORLD_H / 2, 760);
      g.addColorStop(0, 'rgba(0,0,0,0)');
      g.addColorStop(1, 'rgba(0,0,0,0.35)');
      c.fillStyle = g;
      c.fillRect(0, 0, WORLD_W, WORLD_H);
    })();

    // ---------- wasm memory readers ----------
    function readPlayer() {
      return { x: f32[0], y: f32[1], heading: f32[4], alive: f32[5] };
    }
    function readBot(i) {
      var o = (BOTS_OFF + i * BOT_STRIDE) / 4;
      return { x: f32[o], y: f32[o + 1], alive: f32[o + 5] };
    }
    function readBullet(i) {
      var o = (BULLETS_OFF + i * BULLET_STRIDE) / 4;
      return { x: f32[o], y: f32[o + 1], vx: f32[o + 2], vy: f32[o + 3], owner: f32[o + 4], active: f32[o + 5] };
    }
    function readAsteroid(i) {
      var o = (AST_OFF + i * AST_STRIDE) / 4;
      return { x: f32[o], y: f32[o + 1], radius: f32[o + 4], active: f32[o + 5] };
    }

    function drawSpriteRot(spr, x, y, ang) {
      ctx.save();
      ctx.translate(Math.round(x), Math.round(y));
      ctx.rotate(ang);
      ctx.drawImage(spr, -spr.width / 2, -spr.height / 2);
      ctx.restore();
    }
    function drawSprite(spr, x, y) {
      ctx.drawImage(spr, Math.round(x - spr.width / 2), Math.round(y - spr.height / 2));
    }

    function syncCounters() {
      var e = wasm.exports;
      prev.shots = e.get_shots(); prev.enemyShots = e.get_enemy_shots();
      prev.kills = e.get_kills(); prev.rocks = e.get_rocks();
      prev.hurts = e.get_hurts(); prev.waves = e.get_waves();
    }

    /**
     * What happened this frame, according to the engine's event counters.
     *
     * The explosions are still placed by watching each bot's and asteroid's
     * alive flag drop, because a counter says that something died and not
     * where. Everything that is a *decision* — what to play, when to flash,
     * when a wave is over — comes from here.
     */
    function pollEvents(now) {
      var e = wasm.exports, n;
      n = e.get_shots();
      if (n > prev.shots) { sound.shot(); prev.shots = n; }
      n = e.get_enemy_shots();
      if (n > prev.enemyShots) { sound.enemyShot(now); prev.enemyShots = n; }
      n = e.get_kills();
      if (n > prev.kills) { sound.kill(); prev.kills = n; }
      n = e.get_rocks();
      if (n > prev.rocks) { sound.rock(); prev.rocks = n; }
      n = e.get_hurts();
      if (n > prev.hurts) { sound.hurt(); screenFlash = 0.25; prev.hurts = n; }
      n = e.get_waves();
      if (n > prev.waves) { sound.wave(); showLevelBanner(); prev.waves = n; }
    }

    function showLevelBanner() {
      bannerEl.textContent = 'LEVEL ' + wasm.exports.get_level();
      bannerEl.style.opacity = '1';
      clearTimeout(showLevelBanner._t);
      showLevelBanner._t = setTimeout(function () { bannerEl.style.opacity = '0'; }, 1100);
    }

    function restart() {
      if (!wasm || destroyed) return;
      wasm.exports.init();
      msgEl.style.display = 'none';
      prevBotAlive.fill(0);
      prevAstActive.fill(0);
      syncCounters();
      explosions.length = 0;
      running = true;
    }

    // ---------- main loop ----------
    var lastT = performance.now();
    function loop(now) {
      if (destroyed) return;
      var dt = Math.min((now - lastT) / 1000, 0.05);
      lastT = now;
      tGlobal += dt;

      if (running) {
        // set_input takes rotation as an f32 and the engine applies it as
        // `heading += rot * ROT_SPEED * dt`, so anything in [-1,1] is valid —
        // keys just happen to only ever ask for the extremes.
        var rot = (input.right ? 1 : 0) - (input.left ? 1 : 0);
        if (stick.active && stick.mag > STICK_DEADZONE) {
          // Steer toward the angle the thumb is pointing at, along the shortest
          // arc, easing off as the ship lines up. Point-and-aim rather than
          // hold-to-turn — the whole reason the stick beats a d-pad here.
          var err = stick.angle - f32[4];
          err = Math.atan2(Math.sin(err), Math.cos(err));
          rot = Math.max(-1, Math.min(1, err / STICK_SNAP)) * stick.mag;
        }
        wasm.exports.set_input(rot, input.thrust ? 1 : 0, input.fire ? 1 : 0);
        wasm.exports.step(dt);
        f32 = new Float32Array(wasm.exports.memory.buffer);

        pollEvents(now);
        if (wasm.exports.is_game_over()) {
          running = false;
          msgEl.style.display = 'block';
          sound.over();
          var pp = readPlayer();
          spawnExplosion(pp.x, pp.y, true, '#39d5ff');
        }
      }

      // explosion triggers
      var i, o;
      for (i = 0; i < MAX_BOTS; i++) {
        o = (BOTS_OFF + i * BOT_STRIDE) / 4;
        var alive = f32[o + 5];
        if (prevBotAlive[i] > 0 && alive === 0 && running) {
          spawnExplosion(f32[o], f32[o + 1], false, ['#ff3fd1', '#ffdd33', '#20e648'][i % 3]);
        }
        prevBotAlive[i] = alive;
      }
      for (i = 0; i < MAX_AST; i++) {
        o = (AST_OFF + i * AST_STRIDE) / 4;
        var act = f32[o + 5];
        if (prevAstActive[i] > 0 && act === 0 && running && f32[o + 1] < WORLD_H - 5) {
          spawnExplosion(f32[o], f32[o + 1], true, '#a89577');
        }
        prevAstActive[i] = act;
      }
      var livesNow = wasm.exports.get_lives();

      // ---- render ----
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, WORLD_W, WORLD_H);
      drawStars();

      for (i = 0; i < MAX_AST; i++) {
        var ast = readAsteroid(i);
        if (ast.active > 0) {
          var aspr = getAstSprite(i, ast.radius);
          var rotStep = (Math.floor(tGlobal * 1.5 + i) % 4) * Math.PI / 2;
          drawSpriteRot(aspr, ast.x, ast.y, rotStep);
        }
      }

      var frame = Math.floor(tGlobal * 2.5) % 2;
      var botsAlive = 0;
      for (i = 0; i < MAX_BOTS; i++) {
        var b = readBot(i);
        if (b.alive > 0) {
          botsAlive++;
          var species = i % 3;
          var spr = species === 0 ? sprCrab[frame] : (species === 1 ? sprHorn[frame] : sprSkul[frame]);
          drawSprite(spr, b.x, b.y);
          if (species === 0) drawSprite(sprCrabEyes, b.x, b.y);
        }
      }

      for (i = 0; i < MAX_BULLETS; i++) {
        var bl = readBullet(i);
        if (bl.active > 0) {
          var bang = Math.atan2(bl.vy, bl.vx) + Math.PI / 2;
          drawSpriteRot(bl.owner === 0 ? sprPBolt : sprEBolt, bl.x, bl.y, bang);
        }
      }

      var p = readPlayer();
      if (p.alive > 0) {
        var pang = p.heading + Math.PI / 2;
        if (input.thrust && running) {
          var fl = (Math.floor(tGlobal * 14) % 2) ? sprFlame1 : sprFlame2;
          drawSpriteRot(fl, p.x - Math.cos(p.heading) * 34, p.y - Math.sin(p.heading) * 34, pang);
        }
        drawSpriteRot(sprPlayer, p.x, p.y, pang);
      }

      updateDrawExplosions(dt);

      if (screenFlash > 0) {
        ctx.fillStyle = 'rgba(255,40,60,' + (screenFlash * 1.6).toFixed(3) + ')';
        ctx.fillRect(0, 0, WORLD_W, WORLD_H);
        screenFlash -= dt;
      }

      ctx.drawImage(scanCv, 0, 0);

      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLives.textContent = Math.max(0, Math.round(livesNow));
      hudLevel.textContent = wasm.exports.get_level();
      hudBots.textContent = botsAlive;

      rafId = requestAnimationFrame(loop);
    }

    // ---------- boot ----------
    var wasmSource = opts.wasmBase64 || WASM_B64;
    var instantiate;
    if (opts.wasmUrl) {
      instantiate = fetch(opts.wasmUrl)
        .then(function (r) { return r.arrayBuffer(); })
        .then(function (buf) {
          return WebAssembly.instantiate(buf, { env: { sinf: Math.sin, cosf: Math.cos } });
        });
    } else {
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), { env: { sinf: Math.sin, cosf: Math.cos } });
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      f32 = new Float32Array(wasm.exports.memory.buffer);
      restart();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div style="color:#ff3355;padding:20px;font-family:monospace;">Failed to load game engine: ' + err + '</div>';
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
        global.removeEventListener('pointermove', onPointerMove);
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
          enemiesAlive: wasm.exports.bots_alive_count(),
          gameOver: !!wasm.exports.is_game_over()
        };
      }
    };
  }

  global.PixelWave = { mount: mount };

})(window);
