/* ============================================================
 * SECTOR DEFENSE — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="sector-defense.css">
 *   <div id="game"></div>
 *   <script src="sector-defense.js"><\/script>
 *   <script>
 *     var game = SectorDefense.mount(document.getElementById('game'));
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
  var PLAYER_OFF = 0;
  var ENEMIES_OFF = 16, ENEMY_STRIDE = 40, MAX_ENEMIES = 24;
  var PB_OFF = 976, PB_STRIDE = 24, MAX_PB = 20;
  var EB_OFF = 1456, EB_STRIDE = 24, MAX_EB = 30;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[a + 6]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    player: { x: 0, y: 1, alive: 2 },
    enemy: { x: 0, y: 1, vx: 2, vy: 3, hp: 4, kind: 5, active: 6, phase: 7, cd: 8, targetX: 9 },
    pbullet: { x: 0, y: 1, vx: 2, vy: 3, life: 4, active: 5 },
    ebullet: { x: 0, y: 1, vx: 2, vy: 3, life: 4, active: 5 },
  };
  var PLAYER_Y = 648;
  var PXS = 3;   // chunky pixel scale for the ASCII sprites
  // Drawn into a WORLD/LOW_SCALE buffer and blown up by this factor, the same
  // treatment asteroid-miner.js uses and for the same reason: everything
  // rasterises at the low resolution, so nothing on screen is finer than the
  // sprites are.
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

  var PLAYER_PAL = { C: '#a8f0ff', B: '#3aa8d8', D: '#14536e', Y: '#ffd166' };
  var playerRows = [
    '......YY......',
    '......YY......',
    '.....CCCC.....',
    '....CCBBCC....',
    '..CCBBBBBBCC..',
    '.CBBBBBBBBBBC.',
    'CBBDDBBBBDDBBC',
    'CDD..CCCC..DDC',
  ];

  // One silhouette per attacker kind, so a player can tell what is coming by
  // shape and not only by colour — which also means the game still reads on a
  // display with the colour turned down, and to a colour-blind player.
  var DRIFTER_PAL = { A: '#ff8fa3', B: '#c33b55', D: '#5c0f20' };
  var drifterRows = [
    '..AAAAAA..',
    '.ABBBBBBA.',
    'ABBDDDDBBA',
    'ABBBBBBBBA',
    '.ABBBBBBA.',
    '..A.AA.A..',
  ];

  var WEAVER_PAL = { A: '#ffd166', B: '#d18f22', D: '#5c3a05' };
  var weaverRows = [
    '.A......A.',
    'AAA.DD.AAA',
    '.ABBBBBBA.',
    '..ABBBBA..',
    '.A.ABBA.A.',
    'A...AA...A',
  ];

  var DIVER_PAL = { A: '#b98cff', B: '#7a4fd8', D: '#2c0f5c' };
  var diverRows = [
    'A........A',
    'AB......BA',
    'ABBB..BBBA',
    '.ABBDDBBA.',
    '..ABBBBA..',
    '...ABBA...',
  ];

  var HULK_PAL = { A: '#9fe8b0', B: '#3f9c5c', D: '#123a20' };
  var hulkRows = [
    '.AAAAAAAAAAAA.',
    'ABBBBBBBBBBBBA',
    'ABBDDBBBBDDBBA',
    'ABBBBBBBBBBBBA',
    'ABBBBBBBBBBBBA',
    '.AABBBBBBBBAA.',
    '..A.A.AA.A.A..',
  ];

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
      shot: function () { tone(640, 220, 0.06, 'square', 0.03); },
      // A kill's pitch rises with the combo, so a streak is audible before the
      // number on the HUD is read.
      kill: function (combo) {
        var n = Math.min(combo, 20);
        tone(330 + n * 22, 120 + n * 14, 0.11, 'square', 0.045);
        noise(0.08, 0.05);
      },
      shield: function () { tone(520, 300, 0.13, 'triangle', 0.05); },
      leak:   function () { noise(0.26, 0.1); tone(220, 60, 0.28, 'sawtooth', 0.06); },
      breach: function () { tone(160, 50, 0.42, 'sawtooth', 0.075); noise(0.3, 0.09); },
      wave:   function () { tone(520, 1040, 0.3, 'triangle', 0.06); },
      over:   function () { tone(240, 50, 0.95, 'sawtooth', 0.085); },
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
    if (!container) throw new Error('SectorDefense.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'sd-root';
    root.innerHTML =
      '<div class="sd-hud">' +
        '<span>SCORE <b class="sd-a" data-sd="score">0</b></span>' +
        '<span>WAVE <b class="sd-v" data-sd="level">1</b></span>' +
        '<span class="sd-gauge">SHD <span class="sd-bar sd-shield" data-sd="shieldbar"><i data-sd="shield"></i></span></span>' +
        '<span class="sd-gauge">SEC <span class="sd-bar sd-sector" data-sd="sectorbar"><i data-sd="sector"></i></span></span>' +
        '<span>COMBO <b class="sd-c" data-sd="combo">x1.0</b></span>' +
        '<button type="button" class="sd-mute" data-sd="mute">SOUND ON</button>' +
        '<button type="button" class="sd-mute sd-pause" data-sd="pause">PAUSE</button>' +
      '</div>' +
      '<div class="sd-stage">' +
        '<canvas class="sd-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="sd-touch" aria-hidden="true">' +
          '<div class="sd-stickzone" data-sd="stickzone">' +
            '<div class="sd-stick" data-sd="stick">' +
              '<div class="sd-stick-knob" data-sd="knob"></div>' +
            '</div>' +
          '</div>' +
          '<div class="sd-btn sd-btn-fire" data-sd="btnFire">FIRE</div>' +
        '</div>' +
        '<div class="sd-scan" aria-hidden="true"></div>' +
        '<div class="sd-overlay sd-note" data-sd="note">SECTOR CRITICAL</div>' +
        '<div class="sd-overlay sd-banner" data-sd="banner">WAVE 1</div>' +
        '<div class="sd-overlay sd-msg" data-sd="msg">SECTOR LOST<small data-sd="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="sd-overlay sd-msg sd-paused" data-sd="paused">PAUSED<small data-sd="pausedsmall">PRESS P TO RESUME</small></div>' +
      '</div>' +
      '<div class="sd-help" data-sd="help">' +
        '[&larr;][&rarr;] MOVE &nbsp; [SPACE] FIRE &nbsp; ' +
        'NOTHING GETS PAST THE LINE &nbsp; [P] PAUSE &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-sd="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    // The low-resolution buffer. See asteroid-miner.js for the full reasoning;
    // in short, the draw code below works in 960x720 world units and the 1/3
    // transform is the entire adapter.
    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;

    var stage = root.querySelector('.sd-stage');
    var hudScore = q('score'), hudLevel = q('level'), hudCombo = q('combo');
    var shieldBar = q('shieldbar'), shieldFill = q('shield');
    var sectorBar = q('sectorbar'), sectorFill = q('sector');
    var msgEl = q('msg'), bannerEl = q('banner'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute');
    var stickZone = q('stickzone'), stickEl = q('stick'), knobEl = q('knob');
    var btnFire = q('btnFire');

    function enableTouchUI() {
      if (root.classList.contains('sd-is-touch')) return;
      root.classList.add('sd-is-touch');
      helpEl.textContent = 'LEFT STICK MOVES • FIRE BUTTON RIGHT • NOTHING GETS PAST THE LINE • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
      q('pausedsmall').textContent = 'TAP TO RESUME';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var destroyed = false, paused = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var keys = { left: false, right: false, fire: false };
    // Gamepad, read once a frame rather than listened for: the Gamepad API only
    // refreshes its snapshots when getGamepads() is called, so a listener would
    // report whatever frame it happened to fire on. Rebuilt every poll, so
    // nothing latches the way a missed keyup can.
    var PAD_DEADZONE = 0.28;   // a resting stick reads up to about 0.15 on a worn pad
    var pad = { move: 0, fire: false };
    var padPrev = { pause: false, restart: false, mute: false };
    var stick = { active: false, ox: 0, dir: 0 };
    var touch = { fire: false };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    var prevLevel = 1, prevShots = 0, prevKills = 0, prevHurts = 0;
    var prevLeaks = 0, prevBreaches = 0, prevOver = 0;
    var bannerT = 0;
    // Remembered so a kill can throw particles from where the attacker was:
    // the engine deactivates the record, so by the time the counter is read
    // its position is gone.
    var lastEnemyPos = { x: WORLD_W / 2, y: 200 };

    // ---------- sprites ----------
    var sprPlayer = makeSprite(playerRows, PLAYER_PAL, PXS);
    var sprEnemy = [
      makeSprite(drifterRows, DRIFTER_PAL, PXS),
      makeSprite(weaverRows, WEAVER_PAL, PXS),
      makeSprite(diverRows, DIVER_PAL, PXS),
      makeSprite(hulkRows, HULK_PAL, PXS),
    ];

    // A fixed starfield, from a small LCG rather than Math.random so a reload
    // looks like the same sky. Snapped to the low-res grid.
    var stars = (function () {
      var out = [], seed = 20260908;
      for (var i = 0; i < 120; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        var x = (seed / 0x7fffffff) * WORLD_W;
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        var y = (seed / 0x7fffffff) * (WORLD_H - 90);
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        out.push({
          x: Math.round(x / LOW_SCALE) * LOW_SCALE,
          y: Math.round(y / LOW_SCALE) * LOW_SCALE,
          c: (seed % 5 === 0) ? '#c9d6ee' : '#4d5b78',
        });
      }
      return out;
    })();

    // ---------- input ----------
    var KEY_MAP = {
      ArrowLeft: 'left', a: 'left', A: 'left',
      ArrowRight: 'right', d: 'right', D: 'right',
      ' ': 'fire', Spacebar: 'fire',
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

    // A held key or a thumb still on the glass when the tab loses focus never
    // sends its release, and the defender would slide on unattended.
    function releaseAll() {
      keys.left = keys.right = keys.fire = false;
      touch.fire = false;
      btnFire.classList.remove('sd-active');
      releaseStick();
    }

    function releaseStick() {
      stick.active = false;
      stick.dir = 0;
      stickEl.classList.remove('sd-active');
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
      stickEl.classList.add('sd-active');
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
      // Analog, and horizontal only: the defender has one axis, so a knob that
      // slid vertically would promise control that does not exist. `set_input`
      // takes the value as an f32 and applies it as a fraction of PLAYER_SPEED,
      // so a nudge walks and a full push sprints.
      stick.dir = Math.abs(k) < 0.12 ? 0 : k;
      e.preventDefault();
    }

    btnFire.addEventListener('pointerdown', function (e) {
      if (e.pointerType === 'mouse') return;
      enableTouchUI();
      touch.fire = true;
      btnFire.classList.add('sd-active');
      if (btnFire.setPointerCapture) { try { btnFire.setPointerCapture(e.pointerId); } catch (err) {} }
      e.preventDefault();
    });
    var fireUp = function (e) {
      if (e && e.pointerType === 'mouse') return;
      touch.fire = false;
      btnFire.classList.remove('sd-active');
    };
    btnFire.addEventListener('pointerup', fireUp);
    btnFire.addEventListener('pointercancel', fireUp);
    btnFire.addEventListener('pointerleave', fireUp);

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
    // Losing focus also pauses: whoever alt-tabbed away was not planning to come
    // back to a wave already descending.
    function onBlur() { releaseAll(); setPaused(true); }
    global.addEventListener('blur', onBlur);

    // ---------- pause ----------
    // Pause lives here and not in the engine, because it is a decision about the
    // clock rather than about the game: the engine advances by whatever dt it is
    // handed, so pausing is the loop no longer calling step(). The loop keeps
    // drawing, so the frozen frame stays on screen. Chapter 15 makes the case.
    var pausedEl = q('paused'), pauseBtn = q('pause');
    function setPaused(on) {
      if (!wasm) return;
      if (on && wasm.exports.is_game_over()) return;   // nothing to pause once the sector is lost
      paused = on;
      pausedEl.style.display = on ? 'block' : 'none';
      pauseBtn.textContent = on ? 'RESUME' : 'PAUSE';
      // Anything held when play stopped must not still be held when it resumes:
      // the same latch releaseAll() exists to prevent on blur.
      if (on) releaseAll();
    }
    pauseBtn.addEventListener('click', function () { setPaused(!paused); pauseBtn.blur(); });
    // Paused, a press anywhere on the sector resumes and does nothing else: a
    // thumb landing to unpause should not also start sliding the defender.
    stage.addEventListener('pointerdown', function (e) {
      if (!paused) return;
      e.preventDefault();
      e.stopPropagation();
      setPaused(false);
    }, true);

    // ---------- gamepad ----------
    // Standard mapping, and both a face button and a trigger for fire, so a pad
    // with worn triggers still plays: left stick or d-pad moves along the line,
    // A / X / either trigger fires, Start pauses, Back or Y restarts, a shoulder
    // button mutes.
    function pollGamepad() {
      pad.move = 0; pad.fire = false;
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
      if (Math.abs(ax) > PAD_DEADZONE) {
        // Rescale past the deadzone: the engine takes an f32, so a half push
        // should walk the defender rather than sprint it.
        pad.move = (ax > 0 ? 1 : -1) * Math.min(1, (Math.abs(ax) - PAD_DEADZONE) / (1 - PAD_DEADZONE));
      } else if (btn(14) || btn(15)) {
        pad.move = btn(15) ? 1 : -1;
      }
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
          life: 0.3 + Math.random() * 0.45, age: 0, color: color,
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
    function drawSpriteAt(spr, x, y) {
      g.drawImage(spr,
        Math.round((x - spr.width / 2) / LOW_SCALE) * LOW_SCALE,
        Math.round((y - spr.height / 2) / LOW_SCALE) * LOW_SCALE);
    }

    function drawStars() {
      for (var i = 0; i < stars.length; i++) {
        g.fillStyle = stars[i].c;
        g.fillRect(stars[i].x, stars[i].y, LOW_SCALE, LOW_SCALE);
      }
    }

    // The line being defended. It is the only piece of level geometry in the
    // game, so it is drawn as a hazard stripe rather than a hairline: the
    // player has to read its position at a glance while looking elsewhere.
    function drawSectorLine() {
      var y = wasm.exports.get_sector_y();
      var frac = wasm.exports.get_sector() / wasm.exports.get_sector_max();
      var lit = frac > 0.34 ? '#7dff9a' : '#ff5470';
      var dim = frac > 0.34 ? '#1c4a2b' : '#4a121f';
      var shift = Math.floor(tGlobal * 26) % 8;
      for (var x = -8; x < WORLD_W; x += LOW_SCALE * 4) {
        var px = Math.round((x + shift * LOW_SCALE) / LOW_SCALE) * LOW_SCALE;
        g.fillStyle = ((px / (LOW_SCALE * 4)) | 0) % 2 ? lit : dim;
        g.fillRect(px, y, LOW_SCALE * 4, LOW_SCALE * 2);
      }
      g.fillStyle = dim;
      g.fillRect(0, y + LOW_SCALE * 2, WORLD_W, WORLD_H - y - LOW_SCALE * 2);
    }

    function drawEnemies() {
      for (var i = 0; i < MAX_ENEMIES; i++) {
        var a = (ENEMIES_OFF + i * ENEMY_STRIDE) >> 2;
        var E = FIELD.enemy;
        if (f32[a + E.active] <= 0) continue;
        var kind = f32[a + E.kind] | 0;
        var spr = sprEnemy[kind] || sprEnemy[0];
        // `phase` is the engine's unused-by-simulation field: a per-attacker
        // constant, so a group spawned together does not bob in lockstep.
        var bob = Math.round(Math.sin(tGlobal * 4 + f32[a + E.phase]) * 1.2) * LOW_SCALE;
        var x = f32[a + E.x], y = f32[a + E.y];
        lastEnemyPos.x = x; lastEnemyPos.y = y;
        // A hulk that has taken one hit is drawn dimmer, so "this one needs
        // another" is visible rather than remembered.
        if (kind === 3 && f32[a + E.hp] <= 1) g.globalAlpha = 0.55;
        drawSpriteAt(spr, x, y + bob);
        g.globalAlpha = 1;
      }
    }

    function drawBullets() {
      for (var i = 0; i < MAX_PB; i++) {
        var a = (PB_OFF + i * PB_STRIDE) >> 2;
        if (f32[a + FIELD.pbullet.active] <= 0) continue;
        var x = Math.round(f32[a + FIELD.pbullet.x] / LOW_SCALE) * LOW_SCALE;
        var y = Math.round(f32[a + FIELD.pbullet.y] / LOW_SCALE) * LOW_SCALE;
        g.fillStyle = '#ffd166';
        g.fillRect(x - LOW_SCALE, y - LOW_SCALE * 2, LOW_SCALE * 2, LOW_SCALE * 4);
        g.fillStyle = '#fff6d6';
        g.fillRect(x - LOW_SCALE, y - LOW_SCALE * 2, LOW_SCALE, LOW_SCALE * 2);
      }
      for (i = 0; i < MAX_EB; i++) {
        var b = (EB_OFF + i * EB_STRIDE) >> 2;
        if (f32[b + FIELD.ebullet.active] <= 0) continue;
        var bx = Math.round(f32[b + FIELD.ebullet.x] / LOW_SCALE) * LOW_SCALE;
        var by = Math.round(f32[b + FIELD.ebullet.y] / LOW_SCALE) * LOW_SCALE;
        g.fillStyle = '#ff5470';
        g.fillRect(bx - LOW_SCALE, by - LOW_SCALE, LOW_SCALE * 2, LOW_SCALE * 3);
        g.fillStyle = '#ffd0d8';
        g.fillRect(bx - LOW_SCALE, by - LOW_SCALE, LOW_SCALE, LOW_SCALE);
      }
    }

    function drawPlayer() {
      var x = wasm.exports.get_player_x();
      drawSpriteAt(sprPlayer, x, PLAYER_Y);

      // The shield, drawn as a bracket over the defender whose brightness is
      // the meter. It is the same number as the HUD bar, in the place the
      // player is actually looking.
      var sh = wasm.exports.get_shield() / wasm.exports.get_shield_max();
      if (sh <= 0) return;
      var regen = wasm.exports.get_calm() > 2.6;
      g.globalAlpha = 0.3 + sh * 0.55;
      g.fillStyle = regen ? '#a8f0ff' : '#66e2ff';
      var w = 30, px = Math.round((x - w) / LOW_SCALE) * LOW_SCALE;
      var py = Math.round((PLAYER_Y - 26) / LOW_SCALE) * LOW_SCALE;
      g.fillRect(px, py, w * 2, LOW_SCALE);
      g.fillRect(px, py, LOW_SCALE, LOW_SCALE * 3);
      g.fillRect(px + w * 2 - LOW_SCALE, py, LOW_SCALE, LOW_SCALE * 3);
      g.globalAlpha = 1;
    }

    // ---------- engine events ----------
    function pollEvents() {
      var e = wasm.exports;

      var shots = e.get_shots();
      if (shots > prevShots) { sound.shot(); prevShots = shots; }

      var kills = e.get_kills();
      if (kills > prevKills) {
        sound.kill(e.get_combo());
        burst(lastEnemyPos.x, lastEnemyPos.y, 14, '#ff8fa3', 190);
        prevKills = kills;
      }

      var hurts = e.get_hurts();
      if (hurts > prevHurts) {
        sound.shield();
        shake = Math.max(shake, 0.16);
        burst(e.get_player_x(), PLAYER_Y - 20, 10, '#66e2ff', 150);
        prevHurts = hurts;
      }

      var leaks = e.get_leaks();
      if (leaks > prevLeaks) {
        sound.leak();
        shake = Math.max(shake, 0.42);
        flash = 0.45;
        prevLeaks = leaks;
      }

      var breaches = e.get_breaches();
      if (breaches > prevBreaches) {
        sound.breach();
        shake = Math.max(shake, 0.5);
        flash = 0.5;
        burst(lastEnemyPos.x, e.get_sector_y(), 26, '#ff5470', 220);
        prevBreaches = breaches;
      }

      var level = e.get_level();
      if (level !== prevLevel) {
        sound.wave();
        bannerEl.textContent = 'WAVE ' + level;
        bannerT = 1.3;
        prevLevel = level;
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
      var dt = Math.min((now - lastT) / 1000, 0.05);
      lastT = now;
      // Paused stops the animation clock too, so the particles and the shake
      // hold still with the wave instead of playing on over it. lastT still
      // advances, so the first frame back is one frame long.
      if (paused) dt = 0;
      tGlobal += dt;

      if (!paused) {
        // Keys are the digital case of the same analog input the stick supplies:
        // -1, 0 or 1 where the stick can say 0.3. A pad's stick says it the same
        // way. The engine takes an f32 either way and never learns which
        // produced it.
        var move = stick.dir;
        if (pad.move) move = pad.move;
        if (keys.left || keys.right) move = (keys.right ? 1 : 0) - (keys.left ? 1 : 0);
        wasm.exports.set_input(move, (keys.fire || touch.fire || pad.fire) ? 1 : 0);
        wasm.exports.step(dt);
        pollEvents();
      }

      var Z = 1 / LOW_SCALE;
      g.setTransform(Z, 0, 0, Z, 0, 0);
      g.fillStyle = '#060a12';
      g.fillRect(0, 0, WORLD_W, WORLD_H);

      if (shake > 0) {
        // Whole low-res pixels only — a sub-pixel shake resamples the whole
        // field every frame and undoes the point of the buffer.
        var m = shake * 4;
        g.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m),
          Math.round((Math.random() * 2 - 1) * m));
        shake = Math.max(0, shake - dt * 1.7);
      }

      drawStars();
      drawSectorLine();
      drawEnemies();
      drawBullets();
      drawPlayer();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.7).toFixed(3) + ')';
        g.fillRect(0, 0, WORLD_W, WORLD_H);
        flash = Math.max(0, flash - dt * 1.8);
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      // Overlays.
      if (bannerT > 0) { bannerT -= dt; bannerEl.style.opacity = bannerT > 0 ? '1' : '0'; }
      var sectorFrac = wasm.exports.get_sector() / wasm.exports.get_sector_max();
      noteEl.style.opacity =
        (sectorFrac <= 0.34 && sectorFrac > 0 && !wasm.exports.is_game_over()) ? '1' : '0';

      // HUD.
      var shieldFrac = wasm.exports.get_shield() / wasm.exports.get_shield_max();
      var combo = wasm.exports.get_combo();
      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLevel.textContent = wasm.exports.get_level();
      hudCombo.textContent = 'x' + wasm.exports.get_mult().toFixed(1) +
        (combo > 0 ? ' (' + combo + ')' : '');
      shieldFill.style.width = Math.max(0, shieldFrac * 100) + '%';
      sectorFill.style.width = Math.max(0, sectorFrac * 100) + '%';
      if (wasm.exports.get_calm() > 2.6 && shieldFrac < 1) shieldBar.classList.add('sd-regen');
      else shieldBar.classList.remove('sd-regen');
      if (shieldFrac <= 0) shieldBar.classList.add('sd-crit');
      else shieldBar.classList.remove('sd-crit');
      if (sectorFrac <= 0.34) sectorBar.classList.add('sd-crit');
      else sectorBar.classList.remove('sd-crit');

      rafId = requestAnimationFrame(loop);
    }

    function restart() {
      if (!wasm) return;
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      particles.length = 0;
      shake = 0; flash = 0; bannerT = 0;
      releaseAll();
      prevLevel = wasm.exports.get_level();
      prevShots = wasm.exports.get_shots();
      prevKills = wasm.exports.get_kills();
      prevHurts = wasm.exports.get_hurts();
      prevLeaks = wasm.exports.get_leaks();
      prevBreaches = wasm.exports.get_breaches();
      setPaused(false);
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
      root.innerHTML = '<div class="sd-fail">Failed to load game engine: ' + err + '</div>';
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
        global.removeEventListener('pointerup', onWindowPointerUp);
        global.removeEventListener('pointercancel', onWindowPointerCancel);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          level: wasm.exports.get_level(),
          shield: wasm.exports.get_shield(),
          sector: wasm.exports.get_sector(),
          combo: wasm.exports.get_combo(),
          multiplier: wasm.exports.get_mult(),
          bestCombo: wasm.exports.get_best_combo(),
          gameOver: !!wasm.exports.is_game_over(),
          paused: paused,
        };
      },
    };
  }

  global.SectorDefense = { mount: mount };

})(window);
