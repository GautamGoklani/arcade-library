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
  var PICKUPS_OFF = 5664, PICKUP_STRIDE = 24, MAX_PICKUPS = 8;
  var BOSS_OFF = 5856, PARTS_OFF = 5888, PART_STRIDE = 28, MAX_PARTS = 5;
  // Field positions inside each record, in f32 slots — the `@fields` lines in
  // game.wat, copied. Every read goes through this table rather than a bare
  // `f32[o + 5]`, so scripts/check-layout.mjs can see a field that moved.
  var FIELD = {
    player: { x: 0, y: 1, vx: 2, vy: 3, heading: 4, alive: 5 },
    bot: { x: 0, y: 1, vx: 2, vy: 3, heading: 4, alive: 5, cooldown: 6, wanderTimer: 7, targetX: 8, targetY: 9 },
    bullet: { x: 0, y: 1, vx: 2, vy: 3, owner: 4, active: 5 },
    ast: { x: 0, y: 1, vx: 2, vy: 3, radius: 4, active: 5 },
    pickup: { x: 0, y: 1, vy: 2, kind: 3, life: 4, active: 5 },
    boss: { x: 0, y: 1, vx: 2, state: 3, timer: 4, pattern: 5, active: 6, number: 7 },
    part: { dx: 0, dy: 1, hp: 2, maxHp: 3, alive: 4, flash: 5, windup: 6 },
  };
  var PXS = 3; // chunky pixel scale
  var LOW_SCALE = 3;  // 1/3-size buffer, blown up — see the retro adapter in mount()

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

  // Power-ups: one capsule per kind, in the order of the engine's kind field
  // (0 rapid, 1 spread, 2 shield, 3 life). The frame colour is the kind, and the
  // HUD's effect pips use the same colours, so a pickup and what it gave you
  // read as the same thing.
  var PU_COLOURS = ['#ffd23c', '#39d5ff', '#6b8cff', '#e8283c'];
  var puRows = [
    [ // rapid: R
      '.FFFFFFF.', 'F.......F', 'F.GGG...F', 'F.G..G..F', 'F.GGG...F',
      'F.G.G...F', 'F.G..G..F', 'F.......F', '.FFFFFFF.' ],
    [ // spread: three rounds leaving one gun
      '.FFFFFFF.', 'F.......F', 'F.G.G.G.F', 'F.G.G.G.F', 'F..GGG..F',
      'F...G...F', 'F...G...F', 'F.......F', '.FFFFFFF.' ],
    [ // shield
      '.FFFFFFF.', 'F.......F', 'F.GGGGG.F', 'F.G...G.F', 'F.G...G.F',
      'F..G.G..F', 'F...G...F', 'F.......F', '.FFFFFFF.' ],
    [ // life: a heart
      '.FFFFFFF.', 'F.......F', 'F.GG.GG.F', 'F.GGGGG.F', 'F.GGGGG.F',
      'F..GGG..F', 'F...G...F', 'F.......F', '.FFFFFFF.' ],
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
  // The boss: one sprite per kind of part, drawn wherever the engine says each
  // part is. Steel and plate, with red where it hurts. The core has two faces:
  // plated while any section stands, bare once they are gone, so the moment it
  // can be hurt is the moment it looks different.
  var BOSS_PAL = { D: '#3e4756', G: '#8a93a6', P: '#7a6aa8', R: '#e8283c', Y: '#ffd23c', W: '#f2f6ff', O: '#ff7a1e' };
  var coreArmourRows = [
    '.....DDDDDDDD.....', '...DDGGGGGGGGDD...', '..DGGGDDDDDDGGGD..', '.DGGDDGGGGGGDDGGD.',
    '.DGDDGGGRRGGGDDGD.', 'DGGDGGGRRRRGGGDGGD', 'DGDGGGRRWWRRGGGDGD', 'DGDGGGRRWWRRGGGDGD',
    'DGDGGGRRRRRRGGGDGD', 'DGGDGGGRRRRGGGDGGD', '.DGDDGGGRRGGGDDGD.', '.DGGDDGGGGGGDDGGD.',
    '..DGGGDDDDDDGGGD..', '...DDGGGGGGGGDD...', '.....DDDDDDDD.....' ];
  var coreBareRows = [
    '......RRRRRR......', '....RRYYYYYYRR....', '...RYYYOOOOYYYR...', '..RYYOOOOOOOOYYR..',
    '..RYOOOWWWWOOOYR..', '.RYYOOWWWWWWOOYYR.', '.RYOOWWWWWWWWOOYR.', '.RYOOWWWWWWWWOOYR.',
    '.RYYOOWWWWWWOOYYR.', '..RYOOOWWWWOOOYR..', '..RYYOOOOOOOOYYR..', '...RYYYOOOOYYYR...',
    '....RRYYYYYYRR....', '......RRRRRR......' ];
  var wingRows = [
    'DDDDDDDDD.............', 'DGGGGGGGGDDDD.........', 'DGPPPPPPGGGGGDDDD.....',
    'DGPRRPPPPPPPPGGGGDDD..', 'DGPPPPPPPPPPPPPPPGGGDD', 'DGPRRPPPPPPPPPPPPPPGGD',
    'DGGGGGGGGGGGGGGGGGGGGD', '.DDDDDDDDDDDDDDDDDDDD.' ];
  var gunRows = [
    '..DDDDDDDD..', '.DGGGGGGGGD.', 'DGGPPPPPPGGD', 'DGPPRRRRPPGD', 'DGPPRYYRPPGD',
    'DGPPRRRRPPGD', 'DGGPPPPPPGGD', '.DGGGGGGGGD.', '..DDGGGGDD..', '....DGGD....',
    '....DGGD....', '....DGGD....', '....DRRD....', '.....DD.....' ];
  function mirrorRows(rows) { return rows.map(function (r) { return r.split('').reverse().join(''); }); }
  // A part flashes white when hit, and while it is winding up an attack: the
  // same silhouette in one colour, so the flash never changes its shape.
  var WHITE_PAL = { D: '#ffffff', G: '#ffffff', P: '#ffffff', R: '#ffffff', Y: '#ffffff', W: '#ffffff', O: '#ffffff' };
  function partPair(rows) { return [makeSprite(rows, BOSS_PAL, PXS), makeSprite(rows, WHITE_PAL, PXS)]; }
  // index by part: 0 core (plated / bare), 1 left wing, 2 right wing, 3 and 4 guns
  var sprCoreArmour = partPair(coreArmourRows), sprCoreBare = partPair(coreBareRows);
  var sprPart = [null, partPair(mirrorRows(wingRows)), partPair(wingRows), partPair(gunRows), partPair(gunRows)];

  var sprPickup = puRows.map(function (rows, k) {
    return makeSprite(rows, { F: PU_COLOURS[k], G: k === 3 ? '#ff8a9a' : '#ffffff' }, PXS);
  });

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
      // A wave cleared is a rising three-note figure. Good news goes up in this
      // game; a pickup is the only other good news, and gets two notes to the
      // wave's three so the two are never mistaken for each other.
      wave: function () {
        tone(392, 392, 0.1, 'square', 0.04);
        tone(523, 523, 0.1, 'square', 0.04, 0.1);
        tone(784, 784, 0.18, 'square', 0.04, 0.2);
      },
      grab: function () {
        tone(659, 659, 0.07, 'square', 0.04);
        tone(988, 988, 0.12, 'square', 0.04, 0.07);
      },
      // The shield taking a hit: a hard, high knock, where a lost life is a low
      // one. It has to be heard as "that would have hurt".
      block: function () { tone(1400, 900, 0.12, 'triangle', 0.06); },
      // The boss. Its arrival is the one low, slow sound in the game; its
      // wind-up rises, so the ear hears an attack coming the way the eye sees
      // the parts flash; and a round on the plated core is a dry tick, which is
      // the only way the game tells you that shot was wasted.
      bossArrive: function () {
        tone(110, 110, 0.35, 'sawtooth', 0.06);
        tone(82, 82, 0.6, 'sawtooth', 0.06, 0.35);
      },
      warn: function () { tone(300, 700, 0.25, 'square', 0.03); },
      clink: function () { tone(2200, 1800, 0.04, 'triangle', 0.025); },
      partDown: function () { noise(0.4, 0.12); tone(180, 40, 0.5, 'sawtooth', 0.07); },
      bossDown: function () { noise(0.8, 0.14); tone(120, 30, 1.0, 'sawtooth', 0.08); },
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
        '<span>LIVES <b class="ss-r" data-ss="lives">3</b>' +
        '<span class="ss-fx" data-ss="fx">' +
          '<i class="ss-fx-r" data-ss="fxr" title="Rapid fire"></i>' +
          '<i class="ss-fx-s" data-ss="fxs" title="Spread shot"></i>' +
          '<i class="ss-fx-d" data-ss="fxd" title="Shield"></i>' +
        '</span></span>' +
        '<span>LEVEL <b class="ss-y" data-ss="level">1</b></span>' +
        '<span>ENEMIES <b data-ss="bots">0</b></span>' +
        '<button type="button" class="ss-mute" data-ss="mute">SOUND ON</button>' +
        '<button type="button" class="ss-mute ss-pause" data-ss="pause">PAUSE</button>' +
        '<button type="button" class="ss-mute ss-diff" data-ss="diff">NORMAL</button>' +
      '</div>' +
      '<div class="ss-stage">' +
        '<canvas class="ss-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="ss-scan" aria-hidden="true"></div>' +
        '<div class="ss-overlay ss-msg" data-ss="msg">GAME OVER' +
          '<dl class="ss-stats" data-ss="stats"></dl>' +
          '<small data-ss="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="ss-overlay ss-msg ss-paused" data-ss="paused">PAUSED<small data-ss="pausedsmall">PRESS P TO RESUME</small></div>' +
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
      '<div class="ss-help" data-ss="help">[W] THRUST &nbsp; [A]/[D] ROTATE &nbsp; [SPACE] FIRE &nbsp; [P] PAUSE &nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-ss="' + name + '"]'); };
    var stage = root.querySelector('.ss-stage');
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
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level'), hudBots = q('bots');
    var msgEl = q('msg'), bannerEl = q('banner'), helpEl = q('help'), statsEl = q('stats');
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
        : '[W] THRUST \u00a0 [A]/[D] ROTATE \u00a0 [SPACE] FIRE \u00a0 [P] PAUSE \u00a0 [R] RESTART \u00a0 [M] MUTE';
      q('msgsmall').textContent = on ? 'TAP TO RESTART' : 'PRESS R TO RESTART';
      q('pausedsmall').textContent = on ? 'TAP TO RESUME' : 'PRESS P TO RESUME';
      // Switching away from touch has to drop anything the on-screen controls
      // were holding, or a hidden button stays latched on forever.
      if (!on) releaseAllPointers();
    }

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var running = false, destroyed = false, paused = false;
    // Which setting the next run asks for. Only the choice lives here; what a
    // setting does is the table at the top of game.wat.
    var DIFFICULTIES = ['easy', 'normal', 'hard'];
    var difficulty = DIFFICULTIES.indexOf(opts.difficulty);
    if (difficulty < 0) difficulty = 1;
    var tGlobal = 0;
    var input = { left: false, right: false, thrust: false, fire: false };
    // Thumbstick: `angle` is the heading being asked for in screen space, which
    // is the same convention the engine stores heading in, so it feeds through
    // without conversion. `mag` scales the turn rate — a nudge turns gently.
    var stick = { active: false, angle: 0, mag: 0, originX: 0, originY: 0 };
    // Gamepad, read once a frame rather than listened for: the Gamepad API only
    // refreshes its snapshots when you call getGamepads(), so a listener would
    // report the state of whatever frame it happened to fire on.
    //
    // `pad` is this frame's steering, thrust and fire; `padStick` is the left
    // stick as a heading, the same point-and-aim the touch stick feeds. Both are
    // rebuilt every poll, so nothing can latch on the way a missed keyup can.
    var PAD_DEADZONE = 0.28;   // a resting stick reads up to about 0.15 on a worn pad
    var pad = { rot: 0, thrust: false, fire: false };
    var padStick = { active: false, angle: 0, mag: 0 };
    // Buttons that do something once per press rather than while held, so they
    // need last frame's state to find the edge — the same reason the engine
    // keeps $prevFiring.
    var padPrev = { pause: false, restart: false, mute: false };
    var explosions = [];
    var prevBotAlive = new Array(MAX_BOTS).fill(0);
    var prevAstActive = new Array(MAX_AST).fill(0);
    var prevPartAlive = new Array(MAX_PARTS).fill(0);
    // The engine's event counters as of last frame. These replaced watching
    // the lives float and the level number for changes — see pollEvents().
    var prev = { shots: 0, enemyShots: 0, kills: 0, rocks: 0, hurts: 0, waves: 0, grabs: 0, blocks: 0,
                 bosses: 0, warns: 0, clinks: 0, bossParts: 0, bossDowns: 0 };
    var screenFlash = 0, shieldFlash = 0;
    // Screen shake, in seconds of it left; the loop turns it into an offset of
    // whole low-res pixels. Set with Math.max, never added, so two hits in one
    // frame are one big shake rather than a violent one.
    var shake = 0;
    // Someone who has asked the system for less motion gets the flashes and no
    // shake, the same call the CSS makes about the scanlines. Read live, so
    // changing the setting mid-game takes effect on the next hit.
    var reducedMotion = global.matchMedia ? global.matchMedia('(prefers-reduced-motion: reduce)') : null;
    // Hit-stop: seconds of frozen simulation left. See the loop.
    var hitStop = 0, fireDuringStop = false;
    var fxR = q('fxr'), fxS = q('fxs'), fxD = q('fxd');
    var sound = createSound();
    var muted = false;
    var rafId = 0;

    // ---------- keyboard ----------
    // Any recognised game key is proof a keyboard is in use, so it hands control
    // back from the on-screen stick. Scoped to the game's own keys so a browser
    // shortcut or assistive-tech keypress does not flip the mode.
    function isGameKey(k) {
      return k === 'a' || k === 'd' || k === 'w' || k === 'r' || k === 'R' || k === ' ' ||
             k === 'm' || k === 'M' || k === 'p' || k === 'P' || k === 'Escape' ||
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
      // A held key auto-repeats, and a toggle on every repeat would flicker.
      if ((e.key === 'p' || e.key === 'P' || e.key === 'Escape') && !e.repeat) setPaused(!paused);
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
    // Losing focus pauses as well: whoever alt-tabbed away was not planning to
    // come back to a wave already in progress.
    function onBlur() { releaseAll(); setPaused(true); }
    global.addEventListener('blur', onBlur);

    function toggleMute() {
      muted = !muted;
      sound.setMuted(muted);
      muteBtn.textContent = muted ? 'SOUND OFF' : 'SOUND ON';
    }
    muteBtn.addEventListener('click', function () { toggleMute(); muteBtn.blur(); });

    // ---------- pause ----------
    // Pause lives here and not in the engine, because it is a decision about the
    // clock rather than about the game. The engine has no clock — it advances by
    // whatever dt it is handed — so pausing is the loop no longer handing it one,
    // which is the argument chapter 15 makes. The loop keeps drawing, so the
    // frozen frame stays on screen.
    var pausedEl = q('paused'), pauseBtn = q('pause');
    function setPaused(on) {
      if (on && !running) return;   // nothing to pause on the game-over screen
      paused = on;
      pausedEl.style.display = on ? 'block' : 'none';
      pauseBtn.textContent = on ? 'RESUME' : 'PAUSE';
      // Anything held when play stopped must not still be held when it resumes:
      // the same latch releaseAll() exists to prevent on blur.
      if (on) { releaseAll(); releaseAllPointers(); }
    }
    pauseBtn.addEventListener('click', function () { setPaused(!paused); pauseBtn.blur(); });

    // ---------- difficulty ----------
    // The button cycles EASY -> NORMAL -> HARD and starts a fresh run at once. It
    // does not wait for the next run, because a score that was half Easy and
    // half Hard is a number no best-score list could file.
    var diffBtn = q('diff');
    diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
    diffBtn.addEventListener('click', function () {
      difficulty = (difficulty + 1) % DIFFICULTIES.length;
      diffBtn.textContent = DIFFICULTIES[difficulty].toUpperCase();
      restart();
      diffBtn.blur();
    });

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
      // Paused, any press on the arena resumes and does nothing else: a thumb
      // that lands on the stick zone should not also start steering.
      if (paused) {
        e.preventDefault();
        setPaused(false);
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

    // The CRT overlay that used to be painted onto the canvas every frame now
    // lives in CSS as .ss-scan, at true display resolution: drawn into the
    // low-res buffer, one-pixel scanlines would have become three-pixel bars.

    // ---------- wasm memory readers ----------
    function readPlayer() {
      var P = FIELD.player;
      return { x: f32[P.x], y: f32[P.y], heading: f32[P.heading], alive: f32[P.alive] };
    }
    function readBot(i) {
      var o = (BOTS_OFF + i * BOT_STRIDE) / 4, B = FIELD.bot;
      return { x: f32[o + B.x], y: f32[o + B.y], alive: f32[o + B.alive] };
    }
    function readBullet(i) {
      var o = (BULLETS_OFF + i * BULLET_STRIDE) / 4, B = FIELD.bullet;
      return { x: f32[o + B.x], y: f32[o + B.y], vx: f32[o + B.vx], vy: f32[o + B.vy],
               owner: f32[o + B.owner], active: f32[o + B.active] };
    }
    function bossActive() { return f32[BOSS_OFF / 4 + FIELD.boss.active] > 0; }
    function readPart(i) {
      var o = (PARTS_OFF + i * PART_STRIDE) / 4, K = FIELD.part, b = BOSS_OFF / 4;
      return { x: f32[b + FIELD.boss.x] + f32[o + K.dx], y: f32[b + FIELD.boss.y] + f32[o + K.dy],
               hp: f32[o + K.hp], maxHp: f32[o + K.maxHp], alive: f32[o + K.alive], flash: f32[o + K.flash],
               windup: f32[o + K.windup] };
    }
    function drawBoss() {
      var sections = false, hp = 0, maxHp = 0, i;
      for (i = 1; i < MAX_PARTS; i++) if (readPart(i).alive > 0) sections = true;
      var blink = Math.floor(tGlobal * 12) % 2;
      for (i = 0; i < MAX_PARTS; i++) {
        var part = readPart(i);
        maxHp += part.maxHp;
        if (part.alive <= 0) continue;
        hp += part.hp;
        var pair = i === 0 ? (sections ? sprCoreArmour : sprCoreBare) : sprPart[i];
        // the engine marks the parts about to fire; the widget only flashes them
        var white = part.flash > 0 || (part.windup > 0 && blink);
        drawSprite(pair[white ? 1 : 0], part.x, part.y);
      }
      // one bar across the top for the whole boss, in low-res pixels: a frame,
      // then what is left of it
      var w = 600, x0 = (WORLD_W - w) / 2;
      ctx.fillStyle = '#3e4756';
      ctx.fillRect(x0 - 3, 9, w + 6, 12);
      ctx.fillStyle = '#e8283c';
      ctx.fillRect(x0, 12, Math.round(w * (maxHp > 0 ? hp / maxHp : 0) / 3) * 3, 6);
    }
    function readPickup(i) {
      var o = (PICKUPS_OFF + i * PICKUP_STRIDE) / 4, K = FIELD.pickup;
      return { x: f32[o + K.x], y: f32[o + K.y], kind: f32[o + K.kind],
               life: f32[o + K.life], active: f32[o + K.active] };
    }
    // Shown for as long as the engine says an effect has left, blinking over
    // its last two seconds so running out is never a surprise.
    function setPip(el, t) {
      el.style.display = t > 0 ? 'inline-block' : 'none';
      el.style.visibility = (t > 0 && t < 2 && Math.floor(tGlobal * 8) % 2) ? 'hidden' : 'visible';
    }
    // The shield, drawn as a ring of low-res pixels rather than a stroked
    // circle: a one-pixel stroke drawn into the one-third buffer comes out as a
    // smear (see the retro adapter), and this is the same fillRect-on-the-grid
    // answer the other hairlines here got.
    function drawShieldRing(x, y) {
      ctx.fillStyle = PU_COLOURS[2];
      for (var k = 0; k < 40; k++) {
        var a = k / 40 * Math.PI * 2;
        ctx.fillRect(snap(x + Math.cos(a) * 36) - 1, snap(y + Math.sin(a) * 36) - 1, 3, 3);
      }
    }
    function readAsteroid(i) {
      var o = (AST_OFF + i * AST_STRIDE) / 4, A = FIELD.ast;
      return { x: f32[o + A.x], y: f32[o + A.y], radius: f32[o + A.radius], active: f32[o + A.active] };
    }

    function drawSpriteRot(spr, x, y, ang) {
      ctx.save();
      ctx.translate(snap(x), snap(y));
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
      prev.grabs = e.get_grabs(); prev.blocks = e.get_blocks();
      prev.bosses = e.get_bosses(); prev.warns = e.get_warns(); prev.clinks = e.get_clinks();
      prev.bossParts = e.get_boss_parts(); prev.bossDowns = e.get_boss_downs();
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
      if (n > prev.hurts) { sound.hurt(); screenFlash = 0.25; kick(0.5, 0.11); prev.hurts = n; }
      n = e.get_waves();
      if (n > prev.waves) { sound.wave(); showLevelBanner(); prev.waves = n; }
      n = e.get_grabs();
      if (n > prev.grabs) { sound.grab(); prev.grabs = n; }
      n = e.get_blocks();
      if (n > prev.blocks) { sound.block(); shieldFlash = 0.2; kick(0.15, 0); prev.blocks = n; }
      n = e.get_bosses();
      if (n > prev.bosses) { sound.bossArrive(); prev.bosses = n; }
      n = e.get_warns();
      if (n > prev.warns) { sound.warn(); prev.warns = n; }
      n = e.get_clinks();
      if (n > prev.clinks) { sound.clink(); prev.clinks = n; }
      n = e.get_boss_parts();
      if (n > prev.bossParts) { sound.partDown(); kick(0.3, 0.05); prev.bossParts = n; }
      n = e.get_boss_downs();
      if (n > prev.bossDowns) { sound.bossDown(); screenFlash = 0.15; kick(0.7, 0.2); prev.bossDowns = n; }
    }

    /**
     * Shake and hit-stop for one event: seconds of each. Both take the larger
     * of what is running and what is asked, so a second hit inside the first's
     * stop extends it to the longer of the two and never stacks them.
     *
     * What gets them was measured, not guessed. Over 72 bench games a kill came
     * 0.73 s after the last at the median and within 0.1 s one time in ten, so
     * a kill gets neither: a stop there is a stutter, not weight. A lost life
     * (median 5.2 s apart) gets the full treatment. A boss section (median 2.7 s
     * apart, four a fight) gets a stop short enough to feel and not to tire,
     * and the boss itself the longest, because it happens once in ten levels.
     * A shield block shakes lightly and does not stop: nothing was lost, and a
     * freeze would say otherwise.
     */
    function kick(shakeFor, stopFor) {
      if (!(reducedMotion && reducedMotion.matches)) shake = Math.max(shake, shakeFor);
      hitStop = Math.max(hitStop, stopFor);
    }

    function showLevelBanner() {
      // the waves counter and the boss's arrival tick in the same frame, so by
      // the time this runs a boss level already has its boss
      bannerEl.textContent = 'LEVEL ' + wasm.exports.get_level() + (bossActive() ? ' \u00b7 BOSS' : '');
      bannerEl.style.opacity = '1';
      clearTimeout(showLevelBanner._t);
      showLevelBanner._t = setTimeout(function () { bannerEl.style.opacity = '0'; }, 1100);
    }

    function restart() {
      if (!wasm || destroyed) return;
      // set_difficulty only records the choice; init() is what applies it
      wasm.exports.set_difficulty(difficulty);
      wasm.exports.init();
      msgEl.style.display = 'none';
      prevBotAlive.fill(0);
      prevAstActive.fill(0);
      prevPartAlive.fill(0);
      syncCounters();
      explosions.length = 0;
      screenFlash = shieldFlash = shake = hitStop = 0;
      fireDuringStop = false;
      setPaused(false);
      running = true;
    }

    // The run, as the engine counted it. Every figure is a counter the engine
    // keeps anyway, read once when the run ends, so nothing here is tallied by
    // the widget. Accuracy is rounds that struck something over rounds that
    // flew — not kills over presses, which a spread volley takes past 100% and
    // which counts every round into a boss section as a miss (see get_hits in
    // game.wat).
    function showRunStats() {
      var e = wasm.exports;
      var rounds = e.get_rounds();
      var rows = [
        ['WAVES SURVIVED', e.get_waves()],
        ['ENEMIES DOWN', e.get_kills()],
        ['ASTEROIDS', e.get_rocks()],
        ['BOSSES', e.get_boss_downs() + ' / ' + e.get_bosses()],
        ['POWER-UPS', e.get_grabs()],
        ['ACCURACY', rounds ? Math.round(100 * e.get_hits() / rounds) + '%' : '—'],
      ];
      // A boss count reads as a taunt before anyone has met one.
      if (!e.get_bosses()) rows.splice(3, 1);
      var html = '';
      for (var i = 0; i < rows.length; i++) html += '<dt>' + rows[i][0] + '</dt><dd>' + rows[i][1] + '</dd>';
      statsEl.innerHTML = html;
    }

    // Standard mapping, and both a face button and a trigger for each of thrust
    // and fire, so a pad with worn triggers still plays: left stick or d-pad
    // steers, A / RT / d-pad up thrusts, X / LT / B fires, Start pauses, Back or
    // Y restarts, a shoulder button mutes.
    function pollGamepad() {
      pad.rot = 0; pad.thrust = false; pad.fire = false; padStick.active = false;
      var nav = global.navigator;
      var pads = nav && nav.getGamepads ? nav.getGamepads() : null;
      if (!pads) return;
      var p = null, i;
      for (i = 0; i < pads.length; i++) if (pads[i] && pads[i].connected) { p = pads[i]; break; }
      if (!p) return;

      var buttons = p.buttons || [];
      var axes = p.axes || [];
      // A trigger reports an analog value and may never set `pressed`.
      var btn = function (n) { var b = buttons[n]; return !!(b && (b.pressed || b.value > 0.5)); };
      var ax = axes[0] || 0, ay = axes[1] || 0;
      var mag = Math.sqrt(ax * ax + ay * ay);
      if (mag > PAD_DEADZONE) {
        padStick.active = true;
        padStick.angle = Math.atan2(ay, ax);
        // Rescale past the deadzone, so the first millimetre of real movement
        // is a gentle turn rather than a jump to a third of full rate.
        padStick.mag = Math.min(1, (mag - PAD_DEADZONE) / (1 - PAD_DEADZONE));
      } else if (btn(14) || btn(15)) {
        pad.rot = btn(15) ? 1 : -1;
      }
      pad.thrust = btn(0) || btn(7) || btn(12);
      pad.fire = btn(2) || btn(6) || btn(1);

      var pausePress = btn(9), restartPress = btn(8) || btn(3), mutePress = btn(4) || btn(5);
      if (pausePress && !padPrev.pause) setPaused(!paused);
      if (restartPress && !padPrev.restart) restart();
      if (mutePress && !padPrev.mute) toggleMute();
      padPrev.pause = pausePress; padPrev.restart = restartPress; padPrev.mute = mutePress;

      // Any real pad input means this is not a touch session, the same way a
      // recognised keypress does.
      if (padStick.active || pad.rot || pad.thrust || pad.fire || pausePress || restartPress) setTouchMode(false);
    }

    // ---------- main loop ----------
    var lastT = performance.now();
    function loop(now) {
      if (destroyed) return;
      // Before the running check: Start has to be able to unpause, and Back to
      // restart from the game-over screen.
      pollGamepad();
      var dt = Math.min((now - lastT) / 1000, 0.05);
      lastT = now;
      // Paused stops the animation clock too, so explosions and sprite frames
      // hold still with the world instead of playing on over it. lastT still
      // advances, so the first frame back is one frame long, not the whole pause.
      if (paused) dt = 0;
      // Shake runs on the real clock, so a stopped frame still judders: the
      // freeze is the world holding still, not the screen.
      var shakeDt = dt;
      // Hit-stop is pause's short cousin and lives beside it, for the same
      // reason: the engine advances by whatever dt it is handed, so a moment of
      // frozen simulation is the loop not handing it one (chapter 15). The
      // animation clock stops with it, so explosions and sprites freeze too.
      var stopped = false;
      if (hitStop > 0 && running && !paused) {
        hitStop = Math.max(0, hitStop - dt);
        dt = 0;
        stopped = true;
        // A tap that starts and ends inside a stop would never reach the
        // engine, which only sees a press as fire going 0 -> 1 between two
        // steps. Held here and delivered on the first frame back, where a
        // release on the frame after makes it the edge the engine looks for.
        if (input.fire || pad.fire) fireDuringStop = true;
      }
      tGlobal += dt;

      if (running && !paused && !stopped) {
        // set_input takes rotation as an f32 and the engine applies it as
        // `heading += rot * ROT_SPEED * dt`, so anything in [-1,1] is valid —
        // keys just happen to only ever ask for the extremes.
        var rot = (input.right ? 1 : 0) - (input.left ? 1 : 0);
        if (!rot) rot = pad.rot;
        // Steer toward the angle the thumb — or the pad's left stick — is
        // pointing at, along the shortest arc, easing off as the ship lines up.
        // Point-and-aim rather than hold-to-turn, which is the whole reason a
        // stick beats a d-pad here. A finger on the touch stick wins, so a pad
        // resting just inside its deadzone cannot fight one.
        var aim = (stick.active && stick.mag > STICK_DEADZONE) ? stick
                : (padStick.active ? padStick : null);
        if (aim) {
          var err = aim.angle - f32[FIELD.player.heading];
          err = Math.atan2(Math.sin(err), Math.cos(err));
          rot = Math.max(-1, Math.min(1, err / STICK_SNAP)) * aim.mag;
        }
        wasm.exports.set_input(rot, (input.thrust || pad.thrust) ? 1 : 0,
                               (input.fire || pad.fire || fireDuringStop) ? 1 : 0);
        fireDuringStop = false;
        wasm.exports.step(dt);
        f32 = new Float32Array(wasm.exports.memory.buffer);

        pollEvents(now);
        if (wasm.exports.is_game_over()) {
          running = false;
          showRunStats();
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
        var alive = f32[o + FIELD.bot.alive];
        if (prevBotAlive[i] > 0 && alive === 0 && running) {
          spawnExplosion(f32[o + FIELD.bot.x], f32[o + FIELD.bot.y], false,
                         ['#ff3fd1', '#ffdd33', '#20e648'][i % 3]);
        }
        prevBotAlive[i] = alive;
      }
      for (i = 0; i < MAX_AST; i++) {
        o = (AST_OFF + i * AST_STRIDE) / 4;
        var act = f32[o + FIELD.ast.active];
        if (prevAstActive[i] > 0 && act === 0 && running && f32[o + FIELD.ast.y] < WORLD_H - 5) {
          spawnExplosion(f32[o + FIELD.ast.x], f32[o + FIELD.ast.y], true, '#a89577');
        }
        prevAstActive[i] = act;
      }
      for (i = 0; i < MAX_PARTS; i++) {
        var pt = readPart(i);
        if (prevPartAlive[i] > 0 && pt.alive === 0 && running) {
          spawnExplosion(pt.x, pt.y, true, i === 0 ? '#ffd23c' : '#e8283c');
          if (i === 0) {   // the core goes up twice, a beat apart in space
            spawnExplosion(pt.x - 30, pt.y + 12, true, '#ff7a1e');
            spawnExplosion(pt.x + 30, pt.y - 12, true, '#e8283c');
          }
        }
        prevPartAlive[i] = pt.alive;
      }
      var livesNow = wasm.exports.get_lives();

      // ---- render ----
      ctx.setTransform(Z, 0, 0, Z, 0, 0);
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, WORLD_W, WORLD_H);
      // Shake after the clear, so the whole buffer is still wiped and a shaken
      // frame cannot leave a strip of the last one along an edge. The offset is
      // in the buffer's own pixels and rounded, so it is always a whole low-res
      // pixel: a fractional one would resample the frame and smear it.
      if (shake > 0) {
        var m = shake * 4;
        ctx.setTransform(Z, 0, 0, Z,
          Math.round((Math.random() * 2 - 1) * m),
          Math.round((Math.random() * 2 - 1) * m));
        shake = Math.max(0, shake - shakeDt * 1.7);
      }
      drawStars();

      for (i = 0; i < MAX_AST; i++) {
        var ast = readAsteroid(i);
        if (ast.active > 0) {
          var aspr = getAstSprite(i, ast.radius);
          var rotStep = (Math.floor(tGlobal * 1.5 + i) % 4) * Math.PI / 2;
          drawSpriteRot(aspr, ast.x, ast.y, rotStep);
        }
      }

      // pickups, under the ships: something to fly into, not something that
      // hides a bot. They blink as they fade, like the effects they give.
      for (i = 0; i < MAX_PICKUPS; i++) {
        var pk = readPickup(i);
        if (pk.active > 0 && !(pk.life < 2.5 && Math.floor(tGlobal * 8) % 2)) {
          drawSprite(sprPickup[pk.kind | 0], pk.x, pk.y);
        }
      }

      if (bossActive()) drawBoss();

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
        var sh = wasm.exports.get_shield_t();
        if (sh > 0 && !(sh < 2 && Math.floor(tGlobal * 8) % 2)) drawShieldRing(p.x, p.y);
      }

      updateDrawExplosions(dt);

      // the flashes cover the whole field, and should not shake with it
      ctx.setTransform(Z, 0, 0, Z, 0, 0);
      if (screenFlash > 0) {
        ctx.fillStyle = 'rgba(255,40,60,' + (screenFlash * 1.6).toFixed(3) + ')';
        ctx.fillRect(0, 0, WORLD_W, WORLD_H);
        screenFlash -= dt;
      }
      // a blocked hit flashes the shield's colour, not the hurt red: the point
      // is that nothing was lost
      if (shieldFlash > 0) {
        ctx.fillStyle = 'rgba(107,140,255,' + (shieldFlash * 1.4).toFixed(3) + ')';
        ctx.fillRect(0, 0, WORLD_W, WORLD_H);
        shieldFlash -= dt;
      }

      screen.setTransform(1, 0, 0, 1, 0, 0);
      screen.imageSmoothingEnabled = false;
      screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);

      hudScore.textContent = Math.round(wasm.exports.get_score());
      hudLives.textContent = Math.max(0, Math.round(livesNow));
      hudLevel.textContent = wasm.exports.get_level();
      hudBots.textContent = bossActive() ? 'BOSS' : botsAlive;
      setPip(fxR, wasm.exports.get_rapid_t());
      setPip(fxS, wasm.exports.get_spread_t());
      setPip(fxD, wasm.exports.get_shield_t());

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
        global.removeEventListener('blur', onBlur);
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
          gameOver: !!wasm.exports.is_game_over(),
          paused: paused,
          difficulty: DIFFICULTIES[wasm.exports.get_difficulty()]
        };
      }
    };
  }

  global.PixelWave = { mount: mount };

})(window);
