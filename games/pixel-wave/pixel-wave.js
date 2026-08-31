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
      '</div>' +
      '<div class="ss-stage">' +
        '<canvas class="ss-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="ss-overlay ss-msg" data-ss="msg">GAME OVER<small data-ss="msgsmall">PRESS R TO RESTART</small></div>' +
        '<div class="ss-overlay ss-levelbanner" data-ss="banner">LEVEL 1</div>' +
        '<div class="ss-touch">' +
          '<div class="ss-btn ss-btn-left"  data-ss="btnL">&#9664;</div>' +
          '<div class="ss-btn ss-btn-right" data-ss="btnR">&#9654;</div>' +
          '<div class="ss-btn ss-btn-thrust" data-ss="btnT">THRUST</div>' +
          '<div class="ss-btn ss-btn-fire" data-ss="btnF">FIRE</div>' +
        '</div>' +
      '</div>' +
      '<div class="ss-help" data-ss="help">[W] THRUST &nbsp; [A]/[D] ROTATE &nbsp; [SPACE] FIRE &nbsp; [R] RESTART</div>';
    container.appendChild(root);

    var q = function (name) { return root.querySelector('[data-ss="' + name + '"]'); };
    var canvas = root.querySelector('canvas');
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    var hudScore = q('score'), hudLives = q('lives'), hudLevel = q('level'), hudBots = q('bots');
    var msgEl = q('msg'), bannerEl = q('banner'), helpEl = q('help');

    // ---------- touch detection ----------
    var isTouch = (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) ||
                  ('ontouchstart' in global);
    if (isTouch) {
      root.classList.add('ss-is-touch');
      helpEl.textContent = 'HOLD BUTTONS TO MOVE \u2022 TAP GAME OVER TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
    }

    // ---------- per-instance state ----------
    var wasm = null, f32 = null;
    var running = false, destroyed = false;
    var lastLevel = 1, tGlobal = 0;
    var input = { left: false, right: false, thrust: false, fire: false };
    var explosions = [];
    var prevBotAlive = new Array(MAX_BOTS).fill(0);
    var prevAstActive = new Array(MAX_AST).fill(0);
    var prevLives = 3, screenFlash = 0;
    var rafId = 0;

    // ---------- keyboard ----------
    function onKeyDown(e) {
      if (e.key === 'a' || e.key === 'ArrowLeft') input.left = true;
      if (e.key === 'd' || e.key === 'ArrowRight') input.right = true;
      if (e.key === 'w' || e.key === 'ArrowUp') input.thrust = true;
      if (e.key === ' ') { input.fire = true; e.preventDefault(); }
      if (e.key === 'r' || e.key === 'R') restart();
    }
    function onKeyUp(e) {
      if (e.key === 'a' || e.key === 'ArrowLeft') input.left = false;
      if (e.key === 'd' || e.key === 'ArrowRight') input.right = false;
      if (e.key === 'w' || e.key === 'ArrowUp') input.thrust = false;
      if (e.key === ' ') input.fire = false;
    }
    global.addEventListener('keydown', onKeyDown);
    global.addEventListener('keyup', onKeyUp);

    // ---------- touch buttons ----------
    // Each button independently tracks pointers so multi-touch works
    // (e.g. holding THRUST + FIRE + rotating simultaneously).
    function bindHold(el, prop) {
      function down(e) {
        e.preventDefault();
        input[prop] = true;
        el.classList.add('ss-active');
      }
      function up(e) {
        e.preventDefault();
        input[prop] = false;
        el.classList.remove('ss-active');
      }
      el.addEventListener('touchstart', down, { passive: false });
      el.addEventListener('touchend', up, { passive: false });
      el.addEventListener('touchcancel', up, { passive: false });
      // pointer events as well: covers stylus + lets you test with a mouse
      el.addEventListener('pointerdown', down);
      el.addEventListener('pointerup', up);
      el.addEventListener('pointerleave', up);
    }
    bindHold(q('btnL'), 'left');
    bindHold(q('btnR'), 'right');
    bindHold(q('btnT'), 'thrust');
    bindHold(q('btnF'), 'fire');

    // tap game-over text to restart (mobile has no R key)
    msgEl.addEventListener('click', function () { restart(); });
    msgEl.addEventListener('touchstart', function (e) { e.preventDefault(); restart(); }, { passive: false });

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
      lastLevel = 1;
      prevBotAlive.fill(0);
      prevAstActive.fill(0);
      prevLives = 3;
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
        var rot = (input.right ? 1 : 0) - (input.left ? 1 : 0);
        wasm.exports.set_input(rot, input.thrust ? 1 : 0, input.fire ? 1 : 0);
        wasm.exports.step(dt);
        f32 = new Float32Array(wasm.exports.memory.buffer);

        var lvl = wasm.exports.get_level();
        if (lvl !== lastLevel) { lastLevel = lvl; showLevelBanner(); }
        if (wasm.exports.is_game_over()) {
          running = false;
          msgEl.style.display = 'block';
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
      if (livesNow < prevLives) screenFlash = 0.25;
      prevLives = livesNow;

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
