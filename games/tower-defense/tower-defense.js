/* ============================================================
 * TOWER DEFENSE LITE — embeddable arcade widget
 * Engine: hand-written WebAssembly (see game.wat)
 * Renderer/Input/Sound: this file (canvas 2D, mouse + keyboard + touch)
 *
 * Usage:
 *   <link rel="stylesheet" href="tower-defense.css">
 *   <div id="game"></div>
 *   <script src="tower-defense.js"><\/script>
 *   <script>
 *     var game = TowerDefense.mount(document.getElementById('game'));
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
  var GRID_OFF = 0, CELL_STRIDE = 4, COLS = 16, ROWS = 12;
  var TOWERS_OFF = 768, TOWER_STRIDE = 40, MAX_TOWERS = 28;
  var ENEMIES_OFF = 1888, ENEMY_STRIDE = 40, MAX_ENEMIES = 40;
  var SHELLS_OFF = 3488, SHELL_STRIDE = 32, MAX_SHELLS = 24;
  var PATH_OFF = 4256, PATH_STRIDE = 8;
  // Field positions inside each record — bytes for a cell, f32 slots for the
  // rest — the `@fields` lines in game.wat, copied. Every read goes through
  // this table rather than a bare `f32[a + 5]`, so scripts/check-layout.mjs can
  // see a field that moved.
  var FIELD = {
    cell: { kind: 0, tower: 1, step: 2, tier: 3 },
    tower: { x: 0, y: 1, kind: 2, heat: 3, cd: 4, active: 5, aimX: 6, aimY: 7, tracer: 8, tripped: 9 },
    enemy: { x: 0, y: 1, hp: 2, maxHp: 3, kind: 4, active: 5, step: 6, t: 7, flash: 8, spare: 9 },
    shell: { x: 0, y: 1, vx: 2, vy: 3, tx: 4, ty: 5, active: 6, dmg: 7 },
    path: { px: 0, py: 1 },
  };
  var PXS = 3;         // chunky pixel scale for the ASCII sprites
  var LOW_SCALE = 3;   // 320x240 buffer, blown up — see asteroid-miner.js

  var WASM_B64 = "AGFzbQEAAAABchRgAn9/AX9gAX8Bf2AAAX9gAAF9YAJ9fQF9YAN9fX0BfWADf39/AX9gBH19fX0BfWABfwF9YAF9AGACf38BfWACf38AYAN/f38AYAAAYAF/AGACf30AYAN9fX0Bf2AFfX19fX0AYAN9fX0AYAR/f39/AANlZAABAQEBAgEDBAUGBwgIAAkIAQgKAAsMDQ0GDAsICAgIAgMCAQ0CDg8NCRAREgkEBAkDAg0DAw0NDRMNDgINDAkDAwMDAgIDAwICAgIDAggIAwMDAgICAgICAgICAgICAgICAgMFAwEAAQaGBWB/AEEAC38AQQQLfwBBEAt/AEEMC38AQYAGC38AQSgLfwBBHAt/AEHgDgt/AEEoC38AQSgLfwBBoBsLfwBBIAt/AEEYC38AQaAhC38AQQgLfwBB+AALfQBDAABwRAt9AEMAADREC30AQwAAcEILfQBDAACgQQt9AEMAADRCC30AQwAAcEELfQBDZmYmPwt9AEMAAARDC30AQwAAEEELfQBDuB6FPgt9AEMAAFBBC30AQwAAUkMLfQBDAADQQQt9AEMAAMA/C30AQwAABEILfQBDAAB4Qgt9AEMAAOZDC30AQwAAuEILfQBDAACgQQt9AEMAAMhCC30AQwAAIEILfQBDAAAQQQt9AEMpXI89C30AQwAAcEELfQBDAAARQwt9AEMAAKhBC38AQQULfQBDAADwQgt9AEMAAABBC30AQwAAYEILfQBDAAC0Qgt/AEECC30AQ5qZGT4LfQBDAACAQAt9AEMAAKBBC30AQwAAIEELfQFDAACgQQt9AUMAAL5CC30AQwAAYEELfQBDAAAAQQt9AEMAAEBAC30BQwAAwEELfQFDAAAAQAt9AEMAAEBBC30AQwAAFkMLfQBDAADIQQt/AUEBC30BQ7gehT4LfwFBn/WFogQLfwFBAAt9AUMAAAAAC30BQwAAvkILfQFDAACgQQt/AUEBC38BQQALfQFDAABgQQt/AUEAC30BQwAAAAALfwFBAAt/AUEBC38BQQALfQFDAAAAAAt9AUMAAAAAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAsHmgUxBm1lbW9yeQIAEGdldF91cGdyYWRlX2Nvc3QAEwtjYW5fdXBncmFkZQAUCWNhbl9idWlsZAAZDmlzX2xlYWRlcl93YXZlACMNZW5lbWllc19hbGl2ZQAlDmdldF9wdXJnZV9jb3N0ADEJY2FuX3B1cmdlADIOc2V0X2RpZmZpY3VsdHkAOw5nZXRfZGlmZmljdWx0eQA8BGluaXQAPQlzZXRfaW5wdXQAPgRzdGVwAD8JZ2V0X3Njb3JlAEAJZ2V0X3NjcmFwAEEIZ2V0X2NvcmUAQgxnZXRfY29yZV9tYXgAQwlnZXRfbGV2ZWwARAlnZXRfcGhhc2UARQtnZXRfcGhhc2VfdABGDmdldF9idWlsZF90aW1lAEcMZ2V0X3RvX3NwYXduAEgNZ2V0X3dhdmVfc2l6ZQBJCGdldF9jb2xzAEoIZ2V0X3Jvd3MASwhnZXRfY2VsbABMDGdldF9wYXRoX2xlbgBNCGdldF9jb3N0AE4JZ2V0X3JhbmdlAE8KZ2V0X3NwbGFzaABQDGdldF9oZWF0X21heABRDmdldF9lYXJseV9yYXRlAFIMaXNfZ2FtZV9vdmVyAFMKZ2V0X2J1aWxkcwBUCWdldF9zZWxscwBVCWdldF9zaG90cwBWCWdldF9ib29tcwBXCWdldF9raWxscwBYCWdldF9sZWFrcwBZCWdldF90cmlwcwBaCWdldF93YXZlcwBbC2dldF9yZWZ1c2VkAFwLZ2V0X2xlYWRlcnMAXRBnZXRfbGVhZGVyX2tpbGxzAF4KZ2V0X2NsaW5rcwBfCmdldF9wdXJnZXMAYAxnZXRfdXBncmFkZXMAYQ9nZXRfcHVyZ2VfcmVhZHkAYhBnZXRfbGVhZGVyX3JlYWNoAGMKrCZkEAAjACABIwJsIABqIwFsagsKACMEIAAjBWxqCwoAIwcgACMIbGoLCgAjCiAAIwtsagsKACMNIAAjDmxqCzMBAX8jQCEAIAAgAEENdHMhACAAIABBEXZzIQAgACAAQQV0cyEAIAAkQCAAQf////8HcQsHABAFIABwCwsAEAWzQwAAAE+VCw0AIAAQByABIACTlJILIgEBfSAAIQMgAyABXQRAIAEhAwsgAyACXgRAIAIhAwsgAwsiAQF/IAAhAyADIAFIBEAgASEDCyADIAJKBEAgAiEDCyADCx4BAn0gACACkyEEIAEgA5MhBSAEIASUIAUgBZSS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";

  // ============================================================
  // PIXEL SPRITES (ASCII grids -> offscreen canvases)
  // Each character is one pixel; '.' is transparent. Every row of a sprite
  // must be the same length.
  //
  // Everything on this board is a fixed size — a tower fills a cell, an enemy
  // is one creature — so unlike Circuit Runner's components or Starfield
  // Runner's rocks, all of it can be a hand-drawn grid. Only the range ring,
  // the heat bars and the tracers are procedural, because those are lengths
  // the engine chose rather than shapes.
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

  // ---- towers ----
  var PYLON_PAL = { W: '#ffe9a8', Y: '#ffd166', O: '#c08a2e', D: '#5c400f', G: '#8a8f9c', K: '#31353d' };
  var pylonRows = [
    '..GGGGGGGG..',
    '.GKKKKKKKKG.',
    '.GK.YYYY.KG.',
    'GKK.YWWY.KKG',
    'GK..YWWY..KG',
    'GK..YOOY..KG',
    'GKKKKOOKKKKG',
    'GKKKKOOKKKKG',
    '.GKKKKKKKKG.',
    '.GKDDDDDDKG.',
    '..GGGGGGGG..',
    '...GGGGGG...',
  ];
  var MORTAR_PAL = { W: '#e8dcc0', S: '#9aa4ad', D: '#4a525a', K: '#2a2f36', R: '#b8452f' };
  var mortarRows = [
    '...KSSSSK...',
    '..KSSSSSSK..',
    '.KSSWWWWSSK.',
    'KSSWDDDDWSSK',
    'KSSWDKKDWSSK',
    'KSSWDKKDWSSK',
    'KSSWDDDDWSSK',
    'KSSSSRRSSSSK',
    '.KSSSRRSSSK.',
    '.KDDDDDDDDK.',
    '..KDDDDDDK..',
    '...KKKKKK...',
  ];
  var VENT_PAL = { C: '#7cd8ff', B: '#2f7fb8', D: '#134058', K: '#20262c', W: '#e6f7ff' };
  var ventRows = [
    '..KKKKKKKK..',
    '.KDDDDDDDDK.',
    'KDCWCWCWCWDK',
    'KDWCWCWCWCDK',
    'KDCWCWCWCWDK',
    'KDWCWCWCWCDK',
    'KDCWCWCWCWDK',
    'KDWCWCWCWCDK',
    'KDCWCWCWCWDK',
    'KDDDDDDDDDDK',
    '.KBBBBBBBBK.',
    '..KKKKKKKK..',
  ];

  // ---- enemies ----
  var CRAWL_PAL = { G: '#7ac74f', D: '#2f5c1e', W: '#e8ffd8', K: '#16250d' };
  var crawlerRows = [
    '..GGGGGG..',
    '.GGDDDDGG.',
    'GGDWDDWDGG',
    'GGDDDDDDGG',
    'GGGGGGGGGG',
    '.GKGGGGKG.',
    'K.K.GG.K.K',
  ];
  var SPRINT_PAL = { Y: '#ffd166', O: '#e07a1e', W: '#fff3d0', K: '#4a2a06' };
  var sprinterRows = [
    '...YYYY...',
    '..YOOOOY..',
    '.YOWOOWOY.',
    '.YOOOOOOY.',
    '..YOOOOY..',
    '.K.YYYY.K.',
    'K...KK...K',
  ];
  var HAUL_PAL = { S: '#8a94a0', D: '#464e58', W: '#dce6f0', K: '#20252b', R: '#b8452f' };
  var haulerRows = [
    '.SSSSSSSSSS.',
    'SSDDDDDDDDSS',
    'SDWDDDDDDWDS',
    'SDDDDDDDDDDS',
    'SDDRRRRRRDDS',
    'SSDDDDDDDDSS',
    'KSSSSSSSSSSK',
    '.K.K.KK.K.K.',
  ];
  var DAMP_PAL = { P: '#c77aff', D: '#5b2f8a', W: '#f2e0ff', K: '#2a1240' };
  var damperRows = [
    '..PPPPPP..',
    '.PDDDDDDP.',
    'PDWDPPDWDP',
    'PDDPPPPDDP',
    'PDDPPPPDDP',
    '.PDDDDDDP.',
    '..KPPPPK..',
    '...K..K...',
  ];

  // The leader: half again the size of anything else on the route, in
  // riveted plate. Rust and brass rather than a new hue — it is armour, and
  // armour on this board is the hauler's grey-and-red made heavier.
  var LEAD_PAL = { S: '#9aa4ad', D: '#3e454d', W: '#e8dcc0', K: '#1c2026', R: '#c0452f', B: '#d9a441' };
  var leaderRows = [
    '...BBBBBBBB...',
    '..BSSSSSSSSB..',
    '.BSDDDDDDDDSB.',
    'BSDWDSSSSDWDSB',
    'BSDDDSRRSDDDSB',
    'BSSDDSRRSDDSSB',
    'BSDSDDDDDDSDSB',
    'BSDDSSSSSSDDSB',
    '.BSSDDDDDDSSB.',
    'KKBBSSSSSSBBKK',
    'K.K.K.KK.K.K.K',
  ];

  // Board palette. No glow anywhere — brightness is a brighter colour.
  var DIRT = '#16130d';
  var DIRT_ALT = '#191510';
  var TRACK = '#4a3d26';
  var TRACK_EDGE = '#6b5836';
  var CORE_COL = '#6ee7a8';
  var CORE_DARK = '#1e5c3f';

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
    // A tower firing four times a second across forty towers is a lot of
    // oscillators. The shot sound is rate-limited to one every 60ms, which is
    // below what anyone can pick apart and well above what the audio graph
    // starts choking on.
    var lastShot = 0;
    var lastClink = 0;

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
      shot: function (now) {
        if (now - lastShot < 60) return;
        lastShot = now;
        tone(880, 380, 0.035, 'square', 0.016);
      },
      // A pylon round on armour. Throttled harder than the shot, because a
      // leader under a row of pylons is struck a dozen times a second and
      // every one of them saying so is a buzz, not a clink.
      clink: function (now) {
        if (now - lastClink < 140) return;
        lastClink = now;
        tone(1900, 1500, 0.03, 'square', 0.012);
      },
      leader: function () { tone(110, 90, 0.5, 'sawtooth', 0.06); tone(165, 140, 0.5, 'square', 0.03); },
      felled: function () { noise(0.4, 0.1); tone(180, 50, 0.45, 'sawtooth', 0.06); tone(520, 1040, 0.3, 'triangle', 0.05); },
      boom: function () { noise(0.22, 0.07); tone(220, 60, 0.24, 'sawtooth', 0.05); },
      build: function () { tone(300, 620, 0.11, 'triangle', 0.05); },
      sell: function () { tone(620, 260, 0.11, 'triangle', 0.045); },
      refuse: function () { tone(180, 130, 0.09, 'square', 0.035); },
      trip: function () { tone(500, 150, 0.20, 'sawtooth', 0.05); },
      leak: function () { noise(0.28, 0.09); tone(150, 70, 0.3, 'sawtooth', 0.06); },
      wave: function () { tone(320, 520, 0.16, 'square', 0.05); },
      clear: function () { tone(520, 900, 0.22, 'triangle', 0.055); },
      over: function () { tone(230, 40, 1.0, 'sawtooth', 0.085); },
      // a long exhale: noise with the top rolled off, and a falling tone
      // up a fourth, then up a fifth: the second tier is heard as further
      upgrade: function (tier) {
        tone(440, 440 * (tier > 1 ? 1.5 : 1.335), 0.16, 'square', 0.04);
        tone(660, 660 * (tier > 1 ? 1.5 : 1.335), 0.2, 'triangle', 0.035);
      },
      purge: function () { noise(0.6, 0.1); tone(900, 180, 0.55, 'triangle', 0.05); },
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
    if (!container) throw new Error('TowerDefense.mount: container not found');

    // ---------- build DOM ----------
    var root = document.createElement('div');
    root.className = 'td-root';
    root.innerHTML =
      '<div class="td-hud">' +
        '<span>SCRAP <b class="td-a" data-td="scrap">0</b></span>' +
        '<span class="td-core">CORE <span class="td-core-bar" data-td="corebar"><i data-td="core"></i></span></span>' +
        '<span>WAVE <b data-td="level">1</b></span>' +
        '<span data-td="phase">BUILD 14s</span>' +
        '<button type="button" class="td-mute" data-td="mute">SOUND ON</button>' +
        '<button type="button" class="td-mute td-pause" data-td="pause">PAUSE</button>' +
        '<button type="button" class="td-mute td-diff" data-td="diff">NORMAL</button>' +
      '</div>' +
      '<div class="td-stage">' +
        '<canvas class="td-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="td-scan" aria-hidden="true"></div>' +
        '<div class="td-overlay td-note" data-td="note"></div>' +
        '<div class="td-overlay td-msg" data-td="msg">CORE LOST<small data-td="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="td-overlay td-msg td-paused" data-td="paused">PAUSED<small data-td="pausedsmall">PRESS P TO RESUME</small></div>' +
      '</div>' +
      '<div class="td-tools">' +
        '<button type="button" class="td-tool td-on" data-td="t0"><b>1 PYLON</b><span>20 · fast gun</span></button>' +
        '<button type="button" class="td-tool" data-td="t1"><b>2 MORTAR</b><span>45 · splash</span></button>' +
        '<button type="button" class="td-tool" data-td="t2"><b>3 VENT</b><span>15 · cools</span></button>' +
        '<button type="button" class="td-tool td-sell" data-td="t3"><b>4 SELL</b><span>65% back</span></button>' +
        '<button type="button" class="td-tool td-purge" data-td="purge"><b>5 PURGE</b><span data-td="purgecost">cools all</span></button>' +
        '<button type="button" class="td-tool td-go" data-td="go"><b>SPACE</b><span>call the wave</span></button>' +
      '</div>' +
      '<div class="td-help" data-td="help">' +
        'CLICK A SQUARE TO BUILD, OR A TOWER TO UPGRADE IT &nbsp; GUNS OVERHEAT — VENTS COOL THE EIGHT SQUARES AROUND THEM ' +
        '&nbsp; [P] PAUSE &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-td="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var screen = canvas.getContext('2d');
    screen.imageSmoothingEnabled = false;

    var low = document.createElement('canvas');
    low.width = WORLD_W / LOW_SCALE;
    low.height = WORLD_H / LOW_SCALE;
    var g = low.getContext('2d');
    g.imageSmoothingEnabled = false;

    var stage = root.querySelector('.td-stage');
    var hudScrap = q('scrap'), hudLevel = q('level'), hudPhase = q('phase');
    var coreBar = q('corebar'), coreFill = q('core');
    var msgEl = q('msg'), noteEl = q('note'), helpEl = q('help');
    var muteBtn = q('mute'), goBtn = q('go');
    var purgeBtn = q('purge'), purgeCost = q('purgecost');
    var toolEls = [q('t0'), q('t1'), q('t2'), q('t3')];
    // The build tools' labels, kept so the one relabelled "upgrade" while it
    // hovers a tower can be put back.
    var toolSpans = [0, 1, 2].map(function (i) { return toolEls[i].querySelector('span'); });
    var toolLabels = toolSpans.map(function (sp) { return sp.textContent; });

    function enableTouchUI() {
      if (root.classList.contains('td-is-touch')) return;
      root.classList.add('td-is-touch');
      helpEl.textContent =
        'PICK A TOOL, THEN TAP A SQUARE — OR A TOWER TO UPGRADE IT • GUNS OVERHEAT — VENTS COOL THE EIGHT SQUARES AROUND THEM • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
      q('pausedsmall').textContent = 'TAP TO RESUME';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null, u8 = null;
    var destroyed = false, paused = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    // Which setting the next run asks for. Only the choice lives here; what a
    // setting does is the table at the top of game.wat.
    var DIFFICULTIES = ['easy', 'normal', 'hard'];
    var difficulty = DIFFICULTIES.indexOf(opts.difficulty);
    if (difficulty < 0) difficulty = 1;
    // Gamepad, read once a frame rather than listened for: the Gamepad API only
    // refreshes its snapshots when getGamepads() is called, so a listener would
    // report whatever frame it happened to fire on.
    //
    // This game has a cursor rather than a steerable thing, so the pad drives
    // one square at a time with a key-repeat: a first step, a long wait, then a
    // faster run, the same rhythm a held arrow key has. Without the wait, one
    // flick of the stick crosses the board.
    var PAD_DEADZONE = 0.5;
    var PAD_REPEAT_FIRST = 0.30, PAD_REPEAT_NEXT = 0.10;
    var padCursor = { active: false, c: 0, r: 0, wait: 0, lastDir: 0 };
    var padPrev = { pause: false, restart: false, mute: false, build: false, sell: false, tool: false, go: false, purge: false };
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    var prevBuilds = 0, prevSells = 0, prevShots = 0, prevBooms = 0;
    var prevLeaks = 0, prevTrips = 0, prevWaves = 0, prevRefused = 0, prevOver = 0;
    var prevLevel = 1;
    var prevLeaders = 0, prevLeaderKills = 0, prevClinks = 0, prevPurges = 0, prevUpgrades = 0;
    var noteT = 0, noteText = '';
    // The selected tool. This is the one piece of state the widget owns, and
    // it is owned here on purpose: it is a property of the *pointer*, not of
    // the board. The engine is told a cell and a verb; it has no opinion about
    // which button is lit. 0-2 build, 3 sell.
    var tool = 0;
    // Hovered cell, in grid coordinates. -1,-1 when the pointer is off the
    // board or has never been on it (which is the case all the time on touch).
    var hoverC = -1, hoverR = -1;
    // The verb to send on the next step. Set by a click and cleared the moment
    // it is forwarded, because the engine consumes it once — a held mouse
    // button must not lay a row of towers.
    var pendingAction = 0;

    // ---------- sprites ----------
    var sprTower = [
      makeSprite(pylonRows, PYLON_PAL, PXS),
      makeSprite(mortarRows, MORTAR_PAL, PXS),
      makeSprite(ventRows, VENT_PAL, PXS),
    ];
    var sprEnemy = [
      makeSprite(crawlerRows, CRAWL_PAL, PXS),
      makeSprite(sprinterRows, SPRINT_PAL, PXS),
      makeSprite(haulerRows, HAUL_PAL, PXS),
      makeSprite(damperRows, DAMP_PAL, PXS),
      makeSprite(leaderRows, LEAD_PAL, PXS),
    ];

    // ---------- input ----------
    function setTool(t) {
      tool = t;
      for (var i = 0; i < toolEls.length; i++) toolEls[i].classList.toggle('td-on', i === t);
    }
    for (var ti = 0; ti < toolEls.length; ti++) {
      (function (i) {
        toolEls[i].addEventListener('click', function () { setTool(i); toolEls[i].blur(); });
      })(ti);
    }

    function onKeyDown(e) {
      if (e.key === '1') { setTool(0); e.preventDefault(); return; }
      if (e.key === '2') { setTool(1); e.preventDefault(); return; }
      if (e.key === '3') { setTool(2); e.preventDefault(); return; }
      if (e.key === '4') { setTool(3); e.preventDefault(); return; }
      if (e.key === ' ') { pendingAction = 5; e.preventDefault(); return; }
      if (e.key === '5') { pendingAction = 6; e.preventDefault(); return; }
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
      // A held key auto-repeats, and a toggle on every repeat would flicker.
      if ((e.key === 'p' || e.key === 'P' || e.key === 'Escape') && !e.repeat) {
        setPaused(!paused);
        e.preventDefault();
      }
    }

    // Is there a tower on (c,r)? A build tool on your own tower means
    // "upgrade it" — there is nothing else a build could mean there.
    function towerAt(c, r) {
      if (c < 0 || r < 0) return false;
      return u8[GRID_OFF + (r * COLS + c) * CELL_STRIDE + FIELD.cell.tower] !== 0;
    }

    function stageCell(e) {
      var r = canvas.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return [-1, -1];
      var x = (e.clientX - r.left) / r.width * WORLD_W;
      var y = (e.clientY - r.top) / r.height * WORLD_H;
      var c = Math.floor(x / (WORLD_W / COLS));
      var rr = Math.floor(y / (WORLD_H / ROWS));
      if (c < 0 || c >= COLS || rr < 0 || rr >= ROWS) return [-1, -1];
      return [c, rr];
    }

    function onPointerMove(e) {
      var cell = stageCell(e);
      hoverC = cell[0]; hoverR = cell[1];
    }
    function onPointerLeave() { hoverC = -1; hoverR = -1; }

    function onPointerDown(e) {
      if (e.pointerType !== 'mouse') enableTouchUI();
      var cell = stageCell(e);
      hoverC = cell[0]; hoverR = cell[1];
      if (hoverC < 0) return;
      // Right-click sells, whatever the toolbar says. A modifier is faster
      // than a round trip to the palette, and selling is the one verb you
      // reach for mid-thought.
      pendingAction = (e.button === 2 || tool === 3) ? 4 : (towerAt(hoverC, hoverR) ? 7 : tool + 1);
      e.preventDefault();
    }
    function onContextMenu(e) { e.preventDefault(); }

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }

    stage.addEventListener('pointermove', onPointerMove);
    stage.addEventListener('pointerleave', onPointerLeave);
    stage.addEventListener('pointerdown', onPointerDown);
    stage.addEventListener('contextmenu', onContextMenu);
    global.addEventListener('keydown', onKeyDown);
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });
    goBtn.addEventListener('click', function () { pendingAction = 5; goBtn.blur(); });
    purgeBtn.addEventListener('click', function () { pendingAction = 6; purgeBtn.blur(); });
    msgEl.addEventListener('click', function () { restart(); });
    // This title holds nothing down — you place things — so it never needed a
    // blur handler. It needs one now: losing focus pauses.
    function onBlur() { setPaused(true); }
    global.addEventListener('blur', onBlur);

    // ---------- pause ----------
    // Pause lives here and not in the engine, because it is a decision about the
    // clock rather than about the game: the engine advances by whatever dt it is
    // handed, so pausing is the loop no longer calling step(). The loop keeps
    // drawing, so the frozen board stays on screen. Chapter 15 makes the case.
    var pausedEl = q('paused'), pauseBtn = q('pause');
    function setPaused(on) {
      if (!wasm) return;
      if (on && wasm.exports.is_game_over()) return;   // nothing to pause once the core is lost
      paused = on;
      pausedEl.style.display = on ? 'block' : 'none';
      pauseBtn.textContent = on ? 'RESUME' : 'PAUSE';
      // A click queued on the frame everything stopped must not fire on the
      // frame it starts again.
      if (on) pendingAction = 0;
    }
    pauseBtn.addEventListener('click', function () { setPaused(!paused); pauseBtn.blur(); });

    // ---------- difficulty ----------
    // The button cycles EASY -> NORMAL -> HARD and starts a fresh run at once,
    // because a score that was half Easy and half Hard is a number no
    // best-score list could file. Here that means the board is lost too — a
    // restart is a fresh route and no towers, which is the honest price of
    // changing the rules under a defence built for the old ones.
    var diffBtn = q('diff');
    diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
    diffBtn.addEventListener('click', function () {
      difficulty = (difficulty + 1) % DIFFICULTIES.length;
      diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
      restart();
      diffBtn.blur();
    });
    // Paused, a press anywhere on the board resumes and does nothing else: a
    // click meant to unpause should not also build a tower.
    stage.addEventListener('pointerdown', function (e) {
      if (!paused) return;
      e.preventDefault();
      e.stopPropagation();
      setPaused(false);
    }, true);

    // ---------- gamepad ----------
    // Standard mapping, adapted to a game that builds rather than steers: left
    // stick or d-pad walks the cursor a square at a time, A builds with the
    // selected tool, B sells, X cycles the tool, Y starts the next wave (the GO
    // button), Start pauses, Back restarts, a shoulder button mutes.
    //
    // Restart is Back alone here, unlike the other titles, because Y is worth
    // more as "send the next wave" on a board where waiting is a decision.
    function pollGamepad(dt) {
      var nav = global.navigator;
      var pads = nav && nav.getGamepads ? nav.getGamepads() : null;
      if (!pads) return;
      var p = null, i;
      for (i = 0; i < pads.length; i++) if (pads[i] && pads[i].connected) { p = pads[i]; break; }
      if (!p) return;

      var buttons = p.buttons || [], axes = p.axes || [];
      var btn = function (n) { var b = buttons[n]; return !!(b && (b.pressed || b.value > 0.5)); };
      var ax = axes[0] || 0, ay = axes[1] || 0;
      var dc = 0, dr = 0;
      if (ax > PAD_DEADZONE || btn(15)) dc = 1;
      else if (ax < -PAD_DEADZONE || btn(14)) dc = -1;
      if (ay > PAD_DEADZONE || btn(13)) dr = 1;
      else if (ay < -PAD_DEADZONE || btn(12)) dr = -1;

      if (dc || dr) {
        // Start the cursor wherever the mouse left it, or in the middle.
        if (!padCursor.active) {
          padCursor.active = true;
          padCursor.c = hoverC >= 0 ? hoverC : (COLS >> 1);
          padCursor.r = hoverR >= 0 ? hoverR : (ROWS >> 1);
          padCursor.wait = 0;
        }
        var dir = dc * 3 + dr;
        if (dir !== padCursor.lastDir) padCursor.wait = 0;   // a new direction moves at once
        padCursor.lastDir = dir;
        if (padCursor.wait <= 0) {
          padCursor.c = Math.max(0, Math.min(COLS - 1, padCursor.c + dc));
          padCursor.r = Math.max(0, Math.min(ROWS - 1, padCursor.r + dr));
          padCursor.wait = padCursor.wait === 0 ? PAD_REPEAT_FIRST : PAD_REPEAT_NEXT;
        } else {
          padCursor.wait -= dt;
          if (padCursor.wait <= 0) padCursor.wait = 0.0001;   // fire on the next frame
        }
        hoverC = padCursor.c; hoverR = padCursor.r;
      } else {
        padCursor.wait = 0; padCursor.lastDir = 0;
      }

      var buildPress = btn(0), sellPress = btn(1), toolPress = btn(2), goPress = btn(3);
      var pausePress = btn(9), restartPress = btn(8), mutePress = btn(4) || btn(5);
      var purgePress = btn(6);
      if (!paused && purgePress && !padPrev.purge) pendingAction = 6;
      padPrev.purge = purgePress;
      if (!paused && buildPress && !padPrev.build && hoverC >= 0) {
        pendingAction = tool === 3 ? 4 : (towerAt(hoverC, hoverR) ? 7 : tool + 1);
      }
      if (!paused && sellPress && !padPrev.sell && hoverC >= 0) pendingAction = 4;
      if (toolPress && !padPrev.tool) setTool((tool + 1) % toolEls.length);
      if (!paused && goPress && !padPrev.go) pendingAction = 5;
      if (pausePress && !padPrev.pause) setPaused(!paused);
      if (restartPress && !padPrev.restart) restart();
      if (mutePress && !padPrev.mute) toggleMute();
      padPrev.build = buildPress; padPrev.sell = sellPress; padPrev.tool = toolPress; padPrev.go = goPress;
      padPrev.pause = pausePress; padPrev.restart = restartPress; padPrev.mute = mutePress;
    }

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
      if (particles.length > 320) particles.splice(0, particles.length - 320);
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

    function drawSpriteAt(spr, x, y) {
      g.drawImage(spr, snap(x - spr.width / 2), snap(y - spr.height / 2));
    }

    function cellSize() { return WORLD_W / COLS; }

    /** The board: dirt, the enemies' track, and the core at the end of it. */
    function drawBoard() {
      var CS = cellSize();
      for (var r = 0; r < ROWS; r++) {
        for (var c = 0; c < COLS; c++) {
          var a = GRID_OFF + (r * COLS + c) * CELL_STRIDE;
          var kind = u8[a + FIELD.cell.kind];
          var x = snap(c * CS), y = snap(r * CS), w = snap((c + 1) * CS) - x, h = snap((r + 1) * CS) - y;
          if (kind === 0) {
            g.fillStyle = ((c + r) & 1) ? DIRT : DIRT_ALT;
            g.fillRect(x, y, w, h);
          } else if (kind === 1) {
            g.fillStyle = TRACK;
            g.fillRect(x, y, w, h);
            // gravel, keyed off the cell so it does not crawl between frames
            g.fillStyle = TRACK_EDGE;
            for (var k = 0; k < 3; k++) {
              var gx = x + ((c * 37 + r * 17 + k * 53) % 15) * LOW_SCALE;
              var gy = y + ((c * 11 + r * 41 + k * 29) % 15) * LOW_SCALE;
              g.fillRect(gx, gy, LOW_SCALE, LOW_SCALE);
            }
          } else {
            // the core: a reactor block that pulses on its own clock
            var pulse = 0.5 + 0.5 * Math.sin(tGlobal * 3);
            g.fillStyle = CORE_DARK;
            g.fillRect(x, y, w, h);
            g.fillStyle = CORE_COL;
            var inset = LOW_SCALE * (2 + Math.round(pulse * 2));
            g.fillRect(x + inset, y + inset, w - inset * 2, h - inset * 2);
            g.fillStyle = '#eafff5';
            g.fillRect(x + w / 2 - LOW_SCALE * 2, y + h / 2 - LOW_SCALE * 2,
                       LOW_SCALE * 4, LOW_SCALE * 4);
          }
        }
      }
      // a thin grid, so the player can see where a tower would land
      g.fillStyle = 'rgba(255,255,255,0.045)';
      for (var gc = 1; gc < COLS; gc++) g.fillRect(snap(gc * CS), 0, LOW_SCALE, WORLD_H);
      for (var gr = 1; gr < ROWS; gr++) g.fillRect(0, snap(gr * CS), WORLD_W, LOW_SCALE);

      drawRut();
    }

    /**
     * A worn rut down the middle of the track, joining consecutive path cells
     * in the order the engine stored them.
     *
     * Colouring the track squares alone is not enough: where the route doubles
     * back through neighbouring columns the squares abut, and eight of them in
     * a two-by-four block read as an open yard rather than a road. The rut is
     * the *sequence*, which is the thing the enemies actually follow, so it
     * makes the route legible without the generator having to make duller
     * routes to be readable.
     */
    function drawRut() {
      var n = wasm.exports.get_path_len();
      g.fillStyle = '#7d6842';
      for (var i = 0; i + 1 < n; i++) {
        var pa = (PATH_OFF + i * PATH_STRIDE) >> 2, pb = pa + (PATH_STRIDE >> 2);
        var ax = f32[pa + FIELD.path.px], ay = f32[pa + FIELD.path.py];
        var bx = f32[pb + FIELD.path.px], by = f32[pb + FIELD.path.py];
        var lo, hi;
        if (ay === by) {
          lo = Math.min(ax, bx); hi = Math.max(ax, bx);
          g.fillRect(snap(lo), snap(ay) - LOW_SCALE, snap(hi) - snap(lo), LOW_SCALE * 2);
        } else {
          lo = Math.min(ay, by); hi = Math.max(ay, by);
          g.fillRect(snap(ax) - LOW_SCALE, snap(lo), LOW_SCALE * 2, snap(hi) - snap(lo));
        }
      }
    }

    function ringAt(cx, cy, rad, steps) {
      for (var i = 0; i < steps; i++) {
        var a = (i / steps) * Math.PI * 2;
        g.fillRect(snap(cx + Math.cos(a) * rad), snap(cy + Math.sin(a) * rad),
                   LOW_SCALE, LOW_SCALE);
      }
    }

    function drawTowers() {
      var heatMax = wasm.exports.get_heat_max();
      for (var i = 0; i < MAX_TOWERS; i++) {
        var a = (TOWERS_OFF + i * TOWER_STRIDE) >> 2;
        var T = FIELD.tower;
        if (f32[a + T.active] <= 0) continue;
        var x = f32[a + T.x], y = f32[a + T.y], kind = f32[a + T.kind] | 0;
        var heat = f32[a + T.heat], tracer = f32[a + T.tracer], tripped = f32[a + T.tripped];

        drawSpriteAt(sprTower[kind], x, y);

        // Tiers, as pips on the top edge in gold: two squares, one per
        // upgrade, so a board's investment reads at a glance.
        var tier = u8[GRID_OFF + (Math.floor(y / cellSize()) * COLS + Math.floor(x / cellSize())) * CELL_STRIDE + FIELD.cell.tier];
        for (var tp = 0; tp < tier; tp++) {
          g.fillStyle = '#ffd166';
          g.fillRect(snap(x) - LOW_SCALE * 3 + tp * LOW_SCALE * 4, snap(y) - LOW_SCALE * 12,
                     LOW_SCALE * 2, LOW_SCALE * 2);
        }

        // The tracer. The engine set its countdown on the frame it applied the
        // damage, so a line on screen always means a hit landed.
        if (tracer > 0) {
          g.fillStyle = '#fff3c4';
          var tx = f32[a + T.aimX], ty = f32[a + T.aimY];
          var n = 9;
          for (var s = 1; s < n; s++) {
            g.fillRect(snap(x + (tx - x) * (s / n)), snap(y + (ty - y) * (s / n)),
                       LOW_SCALE, LOW_SCALE);
          }
        }

        // Heat, as a bar under the tower. A vent has none and gets none — it
        // would read as a gun with a permanently cold barrel.
        if (kind !== 2) {
          var bw = LOW_SCALE * 12;
          var bx = snap(x) - bw / 2, by = snap(y) + LOW_SCALE * 7;
          g.fillStyle = '#241d10';
          g.fillRect(bx, by, bw, LOW_SCALE * 2);
          g.fillStyle = tripped > 0 ? '#ff5470' : (heat / heatMax > 0.7 ? '#ffa03c' : '#6ee7a8');
          g.fillRect(bx, by, Math.round(bw * Math.min(1, heat / heatMax)), LOW_SCALE * 2);
          if (tripped > 0 && Math.sin(tGlobal * 22) > 0) {
            g.fillStyle = '#ff5470';
            g.fillRect(snap(x) - LOW_SCALE, snap(y) - LOW_SCALE * 9, LOW_SCALE * 2, LOW_SCALE * 2);
          }
        }
      }
    }

    function drawEnemies() {
      for (var i = 0; i < MAX_ENEMIES; i++) {
        var a = (ENEMIES_OFF + i * ENEMY_STRIDE) >> 2;
        var E = FIELD.enemy;
        if (f32[a + E.active] <= 0) continue;
        var x = f32[a + E.x], y = f32[a + E.y], hp = f32[a + E.hp], maxHp = f32[a + E.maxHp];
        var kind = f32[a + E.kind] | 0, flash = f32[a + E.flash];

        if (kind === 4) {
          // the escort: everything inside this ring walks at the leader's
          // pace, and the ring is the radius the engine checks
          g.globalAlpha = 0.16;
          g.fillStyle = '#d9a441';
          ringAt(x, y, wasm.exports.get_leader_reach(), 22);
          g.globalAlpha = 1;
        }
        if (kind === 3) {
          // the damper's field, drawn at the radius the engine actually uses
          g.globalAlpha = 0.18 + 0.07 * Math.sin(tGlobal * 5);
          g.fillStyle = '#c77aff';
          ringAt(x, y, 145, 26);
          g.globalAlpha = 1;
        }

        if (flash > 0 && Math.sin(flash * 90) > 0) {
          g.globalAlpha = 0.85;
          g.fillStyle = '#ffffff';
          g.fillRect(snap(x) - LOW_SCALE * 5, snap(y) - LOW_SCALE * 4,
                     LOW_SCALE * 10, LOW_SCALE * 8);
          g.globalAlpha = 1;
        } else {
          drawSpriteAt(sprEnemy[kind], x, y);
        }

        // The leader's bar is always up and twice as wide: it is the one
        // number on the board a player is racing.
        if (hp < maxHp || kind === 4) {
          var bw = LOW_SCALE * (kind === 4 ? 20 : 10);
          var bx = snap(x) - bw / 2, by = snap(y) - LOW_SCALE * (kind === 4 ? 10 : 7);
          g.fillStyle = '#2a1015';
          g.fillRect(bx, by, bw, LOW_SCALE);
          g.fillStyle = hp / maxHp > 0.45 ? '#6ee7a8' : '#ff5470';
          g.fillRect(bx, by, Math.round(bw * Math.max(0, hp / maxHp)), LOW_SCALE);
        }
      }
    }

    function drawShells() {
      for (var i = 0; i < MAX_SHELLS; i++) {
        var a = (SHELLS_OFF + i * SHELL_STRIDE) >> 2;
        var S = FIELD.shell;
        if (f32[a + S.active] <= 0) continue;
        g.fillStyle = '#e8dcc0';
        g.fillRect(snap(f32[a + S.x]) - LOW_SCALE, snap(f32[a + S.y]) - LOW_SCALE,
                   LOW_SCALE * 2, LOW_SCALE * 2);
        // where it is going to land, so the splash is a promise rather than a
        // surprise — the engine detonates at exactly this point
        g.globalAlpha = 0.5;
        g.fillStyle = '#b8452f';
        ringAt(f32[a + S.tx], f32[a + S.ty], 8, 8);
        g.globalAlpha = 1;
      }
    }

    /**
     * The cursor. Green if the engine says this cell can be built on, red if
     * not — and it asks the engine rather than working it out, so what the
     * cursor promises and what a click does are the same sentence.
     */
    function drawCursor() {
      if (hoverC < 0 || wasm.exports.is_game_over()) return;
      var CS = cellSize();
      var x = snap(hoverC * CS), y = snap(hoverR * CS);
      var w = snap((hoverC + 1) * CS) - x, h = snap((hoverR + 1) * CS) - y;
      var cx = (hoverC + 0.5) * CS, cy = (hoverR + 0.5) * CS;
      var a = GRID_OFF + (hoverR * COLS + hoverC) * CELL_STRIDE;
      var hasTower = u8[a + FIELD.cell.tower] !== 0;

      var ok = tool === 3
        ? hasTower
        : (hasTower ? !!wasm.exports.can_upgrade(hoverC, hoverR)
                    : !!wasm.exports.can_build(hoverC, hoverR, tool));
      g.fillStyle = ok ? 'rgba(110,231,168,0.22)' : 'rgba(255,84,112,0.20)';
      g.fillRect(x, y, w, h);
      g.fillStyle = ok ? '#6ee7a8' : '#ff5470';
      g.fillRect(x, y, w, LOW_SCALE);
      g.fillRect(x, y + h - LOW_SCALE, w, LOW_SCALE);
      g.fillRect(x, y, LOW_SCALE, h);
      g.fillRect(x + w - LOW_SCALE, y, LOW_SCALE, h);

      // The reach of what is about to be placed, or of what is already there.
      var showKind = -1;
      if (tool !== 3 && ok) showKind = tool;
      else if (hasTower) {
        // the cell stores its tower's pool index plus one, so zero can mean "none"
        var ta = (TOWERS_OFF + (u8[a + FIELD.cell.tower] - 1) * TOWER_STRIDE) >> 2;
        showKind = f32[ta + FIELD.tower.kind] | 0;
      }
      if (showKind >= 0) {
        g.globalAlpha = 0.4;
        g.fillStyle = showKind === 2 ? '#7cd8ff' : '#ffd166';
        ringAt(cx, cy, wasm.exports.get_range(showKind), 40);
        g.globalAlpha = 1;
      }
    }

    // ---------- engine events ----------
    function pollEvents(now) {
      var e = wasm.exports;

      var b = e.get_builds();
      if (b > prevBuilds) { sound.build(); prevBuilds = b; }
      var s = e.get_sells();
      if (s > prevSells) { sound.sell(); prevSells = s; }
      var rf = e.get_refused();
      if (rf > prevRefused) { sound.refuse(); prevRefused = rf; }

      var sh = e.get_shots();
      if (sh > prevShots) { sound.shot(now); prevShots = sh; }

      var bo = e.get_booms();
      if (bo > prevBooms) {
        sound.boom();
        // The shell that just went off is gone from the pool, so the burst is
        // drawn at the enemy furthest along instead — close enough, and it
        // avoids keeping a second copy of the blast position around.
        burst(lastBoomX, lastBoomY, 14, '#ffa03c', 190);
        prevBooms = bo;
      }

      var lk = e.get_leaks();
      if (lk > prevLeaks) {
        sound.leak();
        shake = Math.max(shake, 0.45);
        flash = 0.45;
        prevLeaks = lk;
      }

      var cl = e.get_clinks();
      if (cl > prevClinks) { sound.clink(now); prevClinks = cl; }

      var ld = e.get_leaders();
      if (ld > prevLeaders) { sound.leader(); noteText = 'LEADER'; noteT = 1.4; prevLeaders = ld; }

      var lkill = e.get_leader_kills();
      if (lkill > prevLeaderKills) {
        sound.felled();
        shake = Math.max(shake, 0.35);
        burst(lastLeaderX, lastLeaderY, 26, '#d9a441', 220);
        noteText = 'LEADER DOWN';
        noteT = 1.4;
        prevLeaderKills = lkill;
      }

      var ug = e.get_upgrades();
      if (ug > prevUpgrades) {
        var uTier = hoverC >= 0 ? u8[GRID_OFF + (hoverR * COLS + hoverC) * CELL_STRIDE + FIELD.cell.tier] : 1;
        sound.upgrade(uTier);
        if (hoverC >= 0) burst((hoverC + 0.5) * cellSize(), (hoverR + 0.5) * cellSize(), 10, '#ffd166', 120);
        prevUpgrades = ug;
      }

      var pg = e.get_purges();
      if (pg > prevPurges) {
        sound.purge();
        // every gun vents where it stands, so the relief is seen where it lands
        for (var ti2 = 0; ti2 < MAX_TOWERS; ti2++) {
          var ta2 = (TOWERS_OFF + ti2 * TOWER_STRIDE) >> 2;
          if (f32[ta2 + FIELD.tower.active] > 0 && (f32[ta2 + FIELD.tower.kind] | 0) !== 2) {
            burst(f32[ta2 + FIELD.tower.x], f32[ta2 + FIELD.tower.y], 6, '#7cd8ff', 110);
          }
        }
        noteText = 'PURGE';
        noteT = 0.9;
        prevPurges = pg;
      }

      var tr = e.get_trips();
      if (tr > prevTrips) { sound.trip(); prevTrips = tr; }

      var w = e.get_waves();
      if (w > prevWaves) { sound.wave(); noteText = 'WAVE ' + e.get_level(); noteT = 1.1; prevWaves = w; }

      var lv = e.get_level();
      if (lv > prevLevel) {
        sound.clear();
        noteText = 'WAVE CLEARED';
        noteT = 1.3;
        prevLevel = lv;
      }

      var over = e.is_game_over();
      if (over && !prevOver) { sound.over(); msgEl.style.display = 'block'; }
      prevOver = over;
    }

    // Where the leader was last seen, so its fall has somewhere to burst — it
    // is gone from the pool by the frame the counter says so.
    var lastLeaderX = WORLD_W / 2, lastLeaderY = WORLD_H / 2;
    function trackLeader() {
      for (var i = 0; i < MAX_ENEMIES; i++) {
        var a = (ENEMIES_OFF + i * ENEMY_STRIDE) >> 2;
        if (f32[a + FIELD.enemy.active] <= 0 || (f32[a + FIELD.enemy.kind] | 0) !== 4) continue;
        lastLeaderX = f32[a + FIELD.enemy.x]; lastLeaderY = f32[a + FIELD.enemy.y];
      }
    }

    // The last shell position seen, so a detonation has somewhere to spark.
    var lastBoomX = WORLD_W / 2, lastBoomY = WORLD_H / 2;
    function trackShells() {
      for (var i = 0; i < MAX_SHELLS; i++) {
        var a = (SHELLS_OFF + i * SHELL_STRIDE) >> 2;
        if (f32[a + FIELD.shell.active] <= 0) continue;
        lastBoomX = f32[a + FIELD.shell.tx]; lastBoomY = f32[a + FIELD.shell.ty];
      }
    }

    // ---------- HUD ----------
    function drawHud() {
      var e = wasm.exports;
      var scrap = Math.floor(e.get_scrap());
      hudScrap.textContent = scrap;
      hudLevel.textContent = e.get_level();
      var frac = e.get_core() / e.get_core_max();
      coreFill.style.width = Math.max(0, frac * 100) + '%';
      coreBar.classList.toggle('td-crit', frac <= 0.3);

      if (e.get_phase() === 0) {
        // A leader is announced while there is still time to build for it —
        // the engine says which waves bring one, so this is never a guess.
        hudPhase.textContent = 'BUILD ' + Math.max(0, Math.ceil(e.get_phase_t())) + 's' +
          (e.is_leader_wave(e.get_level()) ? ' \u00b7 LEADER' : '');
        goBtn.classList.add('td-armed');
      } else {
        hudPhase.textContent = 'INCOMING ' +
          (e.get_wave_size() - e.get_to_spawn()) + '/' + e.get_wave_size();
        goBtn.classList.remove('td-armed');
      }
      for (var i = 0; i < 3; i++) {
        toolEls[i].classList.toggle('td-poor', scrap < e.get_cost(i));
      }
      // Over one of your towers, the selected build tool is an upgrade tool,
      // and its label says so and what it costs — the engine's price, since
      // it depends on the tower and its tier.
      var label = toolLabels[tool] || '';
      if (tool < 3 && towerAt(hoverC, hoverR)) {
        var uc = e.get_upgrade_cost(hoverC, hoverR);
        label = uc < 0 ? 'fully upgraded' : 'upgrade \u00b7 ' + Math.ceil(uc);
      }
      if (tool < 3 && toolSpans[tool].textContent !== label) toolSpans[tool].textContent = label;
      for (i = 0; i < 3; i++) {
        if (i !== tool && toolSpans[i].textContent !== toolLabels[i]) toolSpans[i].textContent = toolLabels[i];
      }
      // The price is the engine's, and it rises with the wave. The button is
      // lit only when a press would work — spent this wave, between waves, or
      // short of scrap all read the same, as "not now".
      purgeCost.textContent = Math.ceil(e.get_purge_cost()) +
        (e.get_purge_ready() ? ' \u00b7 cools all' : ' \u00b7 used');
      purgeBtn.classList.toggle('td-poor', !e.can_purge());
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      var dt = Math.max(0, Math.min((now - lastT) / 1000, 0.05));
      lastT = now;
      // Polled with the real dt, before the pause gate: Start has to be able to
      // unpause, Back to restart from the game-over screen, and the cursor's
      // key-repeat needs a clock that is still running.
      pollGamepad(dt);
      // Paused stops the animation clock too, so particles and shake hold still
      // with the wave instead of playing on over it. lastT still advances, so
      // the first frame back is one frame long.
      if (paused) dt = 0;
      tGlobal += dt;

      if (!paused) {
        wasm.exports.set_input(hoverC, hoverR, pendingAction);
        pendingAction = 0;
        trackShells();
        trackLeader();
        wasm.exports.step(dt);
        pollEvents(now);
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

      drawBoard();
      drawCursor();
      drawTowers();
      drawShells();
      drawEnemies();
      stepParticles(dt);

      g.setTransform(Z, 0, 0, Z, 0, 0);
      if (flash > 0) {
        g.fillStyle = 'rgba(255,60,90,' + (flash * 0.6).toFixed(3) + ')';
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
      // set_difficulty only records the choice; init() is what applies it
      wasm.exports.set_difficulty(difficulty);
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      u8 = new Uint8Array(wasm.exports.memory.buffer);
      particles.length = 0;
      shake = 0; flash = 0; noteT = 0;
      pendingAction = 0;
      setTool(0);
      setPaused(false);
      prevBuilds = wasm.exports.get_builds();
      prevSells = wasm.exports.get_sells();
      prevShots = wasm.exports.get_shots();
      prevBooms = wasm.exports.get_booms();
      prevLeaks = wasm.exports.get_leaks();
      prevTrips = wasm.exports.get_trips();
      prevWaves = wasm.exports.get_waves();
      prevRefused = wasm.exports.get_refused();
      prevLevel = wasm.exports.get_level();
      prevLeaders = wasm.exports.get_leaders();
      prevLeaderKills = wasm.exports.get_leader_kills();
      prevClinks = wasm.exports.get_clinks();
      prevPurges = wasm.exports.get_purges();
      prevUpgrades = wasm.exports.get_upgrades();
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
      // No imports: every distance here is an f32.sqrt, which is an instruction.
      instantiate = WebAssembly.instantiate(base64ToBytes(wasmSource), {});
    }
    instantiate.then(function (result) {
      if (destroyed) return;
      wasm = result.instance;
      restart();
      lastT = performance.now();
      rafId = requestAnimationFrame(loop);
    }).catch(function (err) {
      root.innerHTML = '<div class="td-fail">Failed to load game engine: ' + err + '</div>';
    });

    // ---------- public API ----------
    return {
      restart: restart,
      destroy: function () {
        destroyed = true;
        cancelAnimationFrame(rafId);
        global.removeEventListener('keydown', onKeyDown);
        global.removeEventListener('blur', onBlur);
        sound.close();
        root.remove();
      },
      getState: function () {
        if (!wasm) return null;
        return {
          score: wasm.exports.get_score(),
          scrap: wasm.exports.get_scrap(),
          core: wasm.exports.get_core(),
          level: wasm.exports.get_level(),
          phase: wasm.exports.get_phase() === 0 ? 'build' : 'wave',
          kills: wasm.exports.get_kills(),
          leaks: wasm.exports.get_leaks(),
          gameOver: !!wasm.exports.is_game_over(),
          paused: paused,
          difficulty: DIFFICULTIES[wasm.exports.get_difficulty()],
        };
      },
    };
  }

  global.TowerDefense = { mount: mount };

})(window);
