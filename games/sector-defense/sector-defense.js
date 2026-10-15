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
  var CARRIER_OFF = 2176;
  var MODULE_OFF = 2208;
  var LANDER_OFF = 2224;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[a + 6]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    player: { x: 0, y: 1, alive: 2 },
    enemy: { x: 0, y: 1, vx: 2, vy: 3, hp: 4, kind: 5, active: 6, phase: 7, cd: 8, targetX: 9 },
    pbullet: { x: 0, y: 1, vx: 2, vy: 3, life: 4, active: 5 },
    ebullet: { x: 0, y: 1, vx: 2, vy: 3, life: 4, active: 5 },
    carrier: { x: 0, y: 1, vx: 2, hp: 3, maxHp: 4, active: 5, bay: 6, flash: 7 },
    module: { x: 0, y: 1, vy: 2, active: 3 },
    lander: { x: 0, y: 1, landY: 2, hp: 3, active: 4, squad: 5, flash: 6, climbing: 7 },
  };
  var PLAYER_Y = 648;
  var PXS = 3;   // chunky pixel scale for the ASCII sprites
  // Drawn into a WORLD/LOW_SCALE buffer and blown up by this factor, the same
  // treatment asteroid-miner.js uses and for the same reason: everything
  // rasterises at the low resolution, so nothing on screen is finer than the
  // sprites are.
  var LOW_SCALE = 3;

  var WASM_B64 = "AGFzbQEAAAABWxBgAX8Bf2AAAX1gAn19AX1gA319fQF9YAN/f38Bf2AIfX19fX19fX0Bf2ABfwF9YAF9AGAAAX9gAABgA319fwBgAn19AGABfwBgAn19AX9gBH9/f38AYAJ9fwADV1YAAAABAQIDBAUBBgEHAQEIAQgGCAkKBwcJBwcLBwwHBwgICAkHDQgICAkHDQ4JCQwICQkPBwEIAQEBAQEBAQEBCAEBAQgICAgICAgICAgICAgICAgICAUDAQABBvEGfX8AQQALfwBBEAt/AEEoC38AQRgLfwBB0AcLfwBBGAt/AEEUC38AQbALC38AQRgLfwBBHgt/AEGAEQt/AEGgEQt/AEGwEQt9AEMAAHBEC30AQwAANEQLfQBD2w/JQAt9AEMAACJEC30AQwAAsEELfQBDAABgQQt9AEMAANdDC30AQ6RwPT4LfQBDAAAgRAt9AENmZqY/C30AQwAAgEALfQBDAIAsRAt9AUMAAMhCC30AQwAAkEELfQBDAAAgQQt9AEMAAMhCC30AQwAACEILfQBDAAAwQQt9AUNmZiZAC30AQwAAiEELfQBDAABgQQt9AEMAAMBBC30BQwAAsEELfQFDmplZQAt9AUMAAL5CC30AQwAAvkILfQBDAADgQAt9AEOamVlAC30AQwAAekMLfQBDAACAQAt9AEMAAKBAC30AQzMzkz8LfQFDKVwPPQt9AUN7FK4+C30AQwAAOEILfQBDmpkZQAt9AEMAAPBBC30AQwAAoEELfQBDAAAWQwt/AEEFC30AQwAAwEILfQBDAABwwgt9AEMAAPBCC30AQwAAtEILfQBDAACgQgt9AEMAAEBBC30AQwAAwEELfQBDAAAAQQt9AEMAAIBCC30AQwAAsEELfQBDAADwQQt9AEMAAJZDC30AQwAAIEILfwBBAwt9AEMAAEBAC30AQwAAvkMLfQBDAAAgwgt9AEMAABZDC30AQwAAXEMLfQBDAADAQAt9AEMAAABAC38AQQMLfwBBBQt9AEMAAPBBC30AQwAAgEELfQBDAAAWQwt9AEPNzEw9C30AQwAADEMLfQBDAABAQQt9AEMAAEhCC38BQQELfQFDmpkZQAt9AUMzM5NAC30BQwAAQD8LfwFBAQt/AUEAC30BQwAAcEELfwFBGgt/AUGzpqQqC38BQeWr6awBC38BQQELfwFBAAt9AUMAAAAAC30BQwAAyEILfQFDAADIQgt9AUMAAAAAC30BQwAAAAALfQFDAAAAAAt/AUEAC30BQwAAAAALfQFDAAAAAAt9AUMAAAAAC30BQwAAgL8LfQFDAAAAAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAsH2QQpBm1lbW9yeQIACGdldF9tdWx0AAsNZW5lbWllc19hbGl2ZQAgDnNldF9kaWZmaWN1bHR5AC8OZ2V0X2RpZmZpY3VsdHkAMARpbml0ADEJc2V0X2lucHV0ADMEc3RlcAA0CWdldF9zY29yZQA1CWdldF9sZXZlbAA2CmdldF9zaGllbGQANw5nZXRfc2hpZWxkX21heAA4CmdldF9zZWN0b3IAOQ5nZXRfc2VjdG9yX21heAA6DGdldF9zZWN0b3JfeQA7CWdldF9jb21ibwA8DmdldF9iZXN0X2NvbWJvAD0PZ2V0X2NvbWJvX3RpbWVyAD4QZ2V0X2NvbWJvX3dpbmRvdwA/DGdldF90b19zcGF3bgBADGdldF9wbGF5ZXJfeABBCGdldF9jYWxtAEIQZ2V0X3NoaWVsZF9kZWxheQBDDGlzX2dhbWVfb3ZlcgBECWdldF9zaG90cwBFCWdldF9raWxscwBGCWdldF9odXJ0cwBHCWdldF9sZWFrcwBIDGdldF9icmVhY2hlcwBJCWdldF93YXZlcwBKDGdldF9jYXJyaWVycwBLEGdldF9jYXJyaWVyX2hpdHMATBFnZXRfY2Fycmllcl9kb3ducwBNDWdldF9iYXlfZHJvcHMATgtnZXRfbGFuZGVycwBPD2dldF9sYW5kZXJfaGl0cwBQEGdldF9sYW5kZXJfZG93bnMAUQxnZXRfbGFuZGluZ3MAUgpnZXRfZGVuaWVkAFMQZ2V0X21vZHVsZV9kcm9wcwBUEmdldF9tb2R1bGVfY2F0Y2hlcwBVCockVgoAIwEgACMCbGoLCgAjBCAAIwVsagsKACMHIAAjCGxqCzMBAX8jWyEAIAAgAEENdHMhACAAIABBEXZzIQAgACAAQQV0cyEAIAAkWyAAs0MAAIBPlQszAQF/I1whACAAIABBDXRzIQAgACAAQRF2cyEA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";

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

  // The carrier: the attackers' pixel language at four times the size, with
  // the bay (the L cells) along its belly. The bay lights blink as a drop comes
  // due, and the whole hull goes white for a frame when a round lands, drawn
  // from a second sprite of the same silhouette so the flash never changes
  // its shape.
  var CARRIER_PAL = { A: '#c9b6ff', B: '#6a55b8', D: '#241a4a', L: '#3a2e66', Y: '#ffd166' };
  var carrierRows = [
    '..............AAAAAAAAAAAAAA..............',
    '..........AAAABBBBBBBBBBBBBBAAAA..........',
    '......AAAABBBBBBDDDDDDDDDDBBBBBBAAAA......',
    '...AAABBBBBBBBBDDYYDDDDYYDDBBBBBBBBBAAA...',
    '.AABBBBBBBBBBBBBDDDDDDDDDDBBBBBBBBBBBBBAA.',
    'ABBBBDDBBBBBBBBBBBBBBBBBBBBBBBBBBBBDDBBBBA',
    'ABBBDDDDBBBBBBBBBBBBBBBBBBBBBBBBBBDDDDBBBA',
    'ABBBBDDBBBBBBBBBBBBBBBBBBBBBBBBBBBBDDBBBBA',
    '.ABBBBBBBBBBLLLLLLLLLLLLLLLLLLBBBBBBBBBBA.',
    '..AABBBBBBBBLLLLLLLLLLLLLLLLLLBBBBBBBBAA..',
    '....AAABBBBBBBBBBBBBBBBBBBBBBBBBBBBAAA....',
    '.......AAAA...AA..........AA...AAAA.......',
    '..............A............A..............',
    '..............A............A..............',
  ];
  var CARRIER_WHITE = { A: '#ffffff', B: '#ffffff', D: '#ffffff', L: '#ffffff', Y: '#ffffff' };
  // The bay's lights when a drop is close: the same cells, lit.
  var CARRIER_BAY = { A: CARRIER_PAL.A, B: CARRIER_PAL.B, D: CARRIER_PAL.D, L: '#ff8fa3', Y: CARRIER_PAL.Y };

  // The lander: squat and hot-coloured, the one enemy craft in orange, because
  // it is the one that has to be noticed the moment it appears. Legs down, so
  // it reads as something that means to touch down.
  var LANDER_PAL = { A: '#ffb86b', B: '#c2571a', D: '#4a1d05', Y: '#ffe08a' };
  var landerRows = [
    '......AAAAAAAA......',
    '....AABBBBBBBBAA....',
    '..AABBBDDYYDDBBBAA..',
    'AABBBBBBBBBBBBBBBBAA',
    'ABBDDBBBBBBBBBBDDBBA',
    '.AABBBBBBBBBBBBBBAA.',
    '...A.AA......AA.A...',
    '..A...A......A...A..',
    '.A....A......A....A.',
  ];
  var LANDER_WHITE = { A: '#ffffff', B: '#ffffff', D: '#ffffff', Y: '#ffffff' };

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
      // The carrier's arrival is the one low, slow sound in the game; a round
      // on its hull is a dull knock, so hitting it is heard as progress
      // without being mistaken for a kill; a drop from the bay is a short,
      // falling thunk, heard as something arriving.
      carrierArrive: function () { tone(98, 98, 0.4, 'sawtooth', 0.06); tone(73, 73, 0.6, 'sawtooth', 0.05); },
      carrierHit:    function () { tone(200, 150, 0.05, 'square', 0.025); },
      bayDrop:       function () { tone(300, 120, 0.12, 'triangle', 0.04); },
      // A module is the shield's colour and the shield's sound: a soft
      // two-note chime when one falls, so it is heard even while you are
      // looking at the attackers, and a rising sweep when it lands on you.
      moduleDrop:    function () { tone(880, 880, 0.08, 'triangle', 0.03); tone(1320, 1320, 0.1, 'triangle', 0.025); },
      moduleCatch:   function () { tone(330, 990, 0.3, 'triangle', 0.06); },
      landerLaunch:  function () { tone(880, 330, 0.35, 'square', 0.035); },
      landerHit:     function () { tone(330, 260, 0.04, 'square', 0.025); },
      landing:       function () { noise(0.2, 0.08); tone(160, 110, 0.25, 'square', 0.05); },
      landerDown:    function () { noise(0.45, 0.11); tone(260, 60, 0.5, 'sawtooth', 0.06); },
      carrierDown:   function () { noise(0.8, 0.13); tone(140, 30, 1.0, 'sawtooth', 0.08); },
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
        '<button type="button" class="sd-mute sd-diff" data-sd="diff">NORMAL</button>' +
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
    // Which setting the next run asks for. Only the choice lives here; what a
    // setting does is the table at the top of game.wat.
    var DIFFICULTIES = ['easy', 'normal', 'hard'];
    var difficulty = DIFFICULTIES.indexOf(opts.difficulty);
    if (difficulty < 0) difficulty = 1;
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
    var prevCarriers = 0, prevCarrierHits = 0, prevCarrierDowns = 0, prevBayDrops = 0;
    var prevLanders = 0, prevLanderHits = 0, prevLanderDowns = 0, prevLandings = 0;
    var prevModDrops = 0, prevModCatches = 0;
    var bannerT = 0;
    // Remembered so a kill can throw particles from where the attacker was:
    // the engine deactivates the record, so by the time the counter is read
    // its position is gone.
    var lastEnemyPos = { x: WORLD_W / 2, y: 200 };

    // ---------- sprites ----------
    var sprPlayer = makeSprite(playerRows, PLAYER_PAL, PXS);
    var sprCarrier = makeSprite(carrierRows, CARRIER_PAL, PXS);
    var sprCarrierBay = makeSprite(carrierRows, CARRIER_BAY, PXS);
    var sprCarrierWhite = makeSprite(carrierRows, CARRIER_WHITE, PXS);
    var sprLander = makeSprite(landerRows, LANDER_PAL, PXS);
    var sprLanderWhite = makeSprite(landerRows, LANDER_WHITE, PXS);
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

    // ---------- difficulty ----------
    // The button cycles EASY -> NORMAL -> HARD and starts a fresh run at once,
    // because a score that was half Easy and half Hard is a number no
    // best-score list could file.
    var diffBtn = q('diff');
    diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
    diffBtn.addEventListener('click', function () {
      difficulty = (difficulty + 1) % DIFFICULTIES.length;
      diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
      restart();
      diffBtn.blur();
    });
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

    function drawCarrier() {
      var C = FIELD.carrier, c = CARRIER_OFF >> 2;
      if (f32[c + C.active] <= 0) return;
      var x = f32[c + C.x], y = f32[c + C.y];
      var spr = f32[c + C.flash] > 0 ? sprCarrierWhite
              : (f32[c + C.bay] < 0.6 && Math.floor(tGlobal * 10) % 2 ? sprCarrierBay : sprCarrier);
      drawSpriteAt(spr, x, y);
      // what is left of it, in a bar under the hull: the one number the
      // decision to keep shooting it turns on
      var w = 120, x0 = Math.round((x - w / 2) / LOW_SCALE) * LOW_SCALE;
      var y0 = Math.round((y + 30) / LOW_SCALE) * LOW_SCALE;
      g.fillStyle = '#241a4a';
      g.fillRect(x0, y0, w, LOW_SCALE * 2);
      g.fillStyle = '#c9b6ff';
      g.fillRect(x0, y0, Math.round(w * f32[c + C.hp] / f32[c + C.maxHp] / LOW_SCALE) * LOW_SCALE, LOW_SCALE * 2);
    }

    /**
     * The lander, and while it is still loaded, the spot it will land on:
     * four corner brackets at `landY`, blinking. The spot is the engine's
     * decision, made at launch, so the marker is a fact rather than a guess —
     * the player has the whole dive to choose between getting under it and
     * getting ready for what it brings. Its hits left show as pips, one a
     * round, because six to twelve is a count and not a proportion.
     */
    function drawLander() {
      var L = FIELD.lander, b = LANDER_OFF >> 2;
      if (f32[b + L.active] <= 0) return;
      var x = f32[b + L.x], y = f32[b + L.y], s = LOW_SCALE;
      if (f32[b + L.squad] > 0) {
        if (Math.floor(tGlobal * 6) % 2) {
          var lx = Math.round(x / s) * s, ly = Math.round((f32[b + L.landY] + 24) / s) * s;
          g.fillStyle = '#ffb86b';
          for (var cx = -1; cx <= 1; cx += 2) {
            for (var cy = -1; cy <= 1; cy += 2) {
              // corners 12 by 5 low-res pixels out from the spot
              var ox = lx + cx * 12 * s, oy = ly + cy * 5 * s;
              g.fillRect(ox - (cx > 0 ? s * 3 : 0), oy, s * 3, s);
              g.fillRect(ox - (cx > 0 ? s : 0), oy - (cy > 0 ? s * 2 : 0), s, s * 3);
            }
          }
        }
        var n = f32[b + L.hp] | 0, x0 = Math.round((x - n * s) / s) * s;
        var y0 = Math.round((y + 22) / s) * s;
        g.fillStyle = '#ffe08a';
        for (var k = 0; k < n; k++) g.fillRect(x0 + k * s * 2, y0, s, s);
      }
      drawSpriteAt(f32[b + L.flash] > 0 ? sprLanderWhite : sprLander, x, y);
    }

    /**
     * The shield module: a capsule in the shield's own cyan with a bright
     * core, and a tick on the defender's line directly below it. It falls
     * straight down, so the tick is exactly where it will land — the whole
     * decision is whether to be there, and that should not need guessing.
     */
    function drawModule() {
      var M = FIELD.module, m = MODULE_OFF >> 2;
      if (f32[m + M.active] <= 0) return;
      var x = Math.round(f32[m + M.x] / LOW_SCALE) * LOW_SCALE;
      var y = Math.round(f32[m + M.y] / LOW_SCALE) * LOW_SCALE;
      g.fillStyle = '#66e2ff';
      g.fillRect(x - LOW_SCALE * 3, y - LOW_SCALE * 4, LOW_SCALE * 6, LOW_SCALE * 8);
      g.fillStyle = '#1b5f73';
      g.fillRect(x - LOW_SCALE * 3, y - LOW_SCALE * 4, LOW_SCALE * 6, LOW_SCALE);
      g.fillRect(x - LOW_SCALE * 3, y + LOW_SCALE * 3, LOW_SCALE * 6, LOW_SCALE);
      g.fillStyle = Math.floor(tGlobal * 6) % 2 ? '#ffffff' : '#c9f6ff';
      g.fillRect(x - LOW_SCALE, y - LOW_SCALE * 2, LOW_SCALE * 2, LOW_SCALE * 4);
      g.fillStyle = 'rgba(102,226,255,0.55)';
      g.fillRect(x - LOW_SCALE * 3, Math.round((PLAYER_Y + 20) / LOW_SCALE) * LOW_SCALE, LOW_SCALE * 6, LOW_SCALE);
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
      // the pause comes from the engine: the difficulty table moves it
      var regen = wasm.exports.get_calm() > wasm.exports.get_shield_delay();
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

      // The carrier. Its arrival and the new wave land in the same frame, so
      // by the time the banner is written a carrier wave already has one.
      var carriers = e.get_carriers();
      if (carriers > prevCarriers) { sound.carrierArrive(); prevCarriers = carriers; }
      var cHits = e.get_carrier_hits();
      if (cHits > prevCarrierHits) { sound.carrierHit(); prevCarrierHits = cHits; }
      var drops = e.get_bay_drops();
      if (drops > prevBayDrops) { sound.bayDrop(); prevBayDrops = drops; }
      var md = e.get_module_drops();
      if (md > prevModDrops) { sound.moduleDrop(); prevModDrops = md; }
      var mc = e.get_module_catches();
      if (mc > prevModCatches) {
        sound.moduleCatch();
        burst(e.get_player_x(), PLAYER_Y - 10, 18, '#66e2ff', 160);
        prevModCatches = mc;
      }

      // The lander: launch, rounds, the landing, or the kill that denied it.
      var lnd = e.get_landers();
      if (lnd > prevLanders) {
        sound.landerLaunch();
        bannerEl.textContent = 'LANDER';
        bannerT = 1.0;
        prevLanders = lnd;
      }
      var lHits = e.get_lander_hits();
      if (lHits > prevLanderHits) { sound.landerHit(); prevLanderHits = lHits; }
      var lb = LANDER_OFF >> 2;
      var landings = e.get_landings();
      if (landings > prevLandings) {
        sound.landing();
        shake = Math.max(shake, 0.25);
        burst(f32[lb + FIELD.lander.x], f32[lb + FIELD.lander.y] + 24, 16, '#ffb86b', 140);
        prevLandings = landings;
      }
      var lDowns = e.get_lander_downs();
      if (lDowns > prevLanderDowns) {
        sound.landerDown();
        shake = Math.max(shake, 0.4);
        burst(f32[lb + FIELD.lander.x], f32[lb + FIELD.lander.y], 30, '#ffb86b', 230);
        burst(f32[lb + FIELD.lander.x], f32[lb + FIELD.lander.y], 16, '#ffe08a', 180);
        prevLanderDowns = lDowns;
      }

      var downs = e.get_carrier_downs();
      if (downs > prevCarrierDowns) {
        var cc = CARRIER_OFF >> 2;
        sound.carrierDown();
        shake = Math.max(shake, 0.6);
        burst(f32[cc + FIELD.carrier.x], f32[cc + FIELD.carrier.y], 40, '#c9b6ff', 260);
        burst(f32[cc + FIELD.carrier.x], f32[cc + FIELD.carrier.y], 24, '#ffd166', 200);
        prevCarrierDowns = downs;
      }

      var level = e.get_level();
      if (level !== prevLevel) {
        sound.wave();
        bannerEl.textContent = 'WAVE ' + level +
          (f32[(CARRIER_OFF >> 2) + FIELD.carrier.active] > 0 ? ' \u00b7 CARRIER' : '');
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
      drawCarrier();
      drawLander();
      drawModule();
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
      // set_difficulty only records the choice; init() is what applies it
      wasm.exports.set_difficulty(difficulty);
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
      prevCarriers = wasm.exports.get_carriers();
      prevCarrierHits = wasm.exports.get_carrier_hits();
      prevCarrierDowns = wasm.exports.get_carrier_downs();
      prevLanders = wasm.exports.get_landers();
      prevLanderHits = wasm.exports.get_lander_hits();
      prevLanderDowns = wasm.exports.get_lander_downs();
      prevLandings = wasm.exports.get_landings();
      prevModDrops = wasm.exports.get_module_drops();
      prevModCatches = wasm.exports.get_module_catches();
      prevBayDrops = wasm.exports.get_bay_drops();
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
          difficulty: DIFFICULTIES[wasm.exports.get_difficulty()],
        };
      },
    };
  }

  global.SectorDefense = { mount: mount };

})(window);
