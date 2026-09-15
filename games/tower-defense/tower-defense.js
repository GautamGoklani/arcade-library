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
    cell: { kind: 0, tower: 1, step: 2, spare: 3 },
    tower: { x: 0, y: 1, kind: 2, heat: 3, cd: 4, active: 5, aimX: 6, aimY: 7, tracer: 8, tripped: 9 },
    enemy: { x: 0, y: 1, hp: 2, maxHp: 3, kind: 4, active: 5, step: 6, t: 7, flash: 8, spare: 9 },
    shell: { x: 0, y: 1, vx: 2, vy: 3, tx: 4, ty: 5, active: 6, dmg: 7 },
    path: { px: 0, py: 1 },
  };
  var PXS = 3;         // chunky pixel scale for the ASCII sprites
  var LOW_SCALE = 3;   // 320x240 buffer, blown up — see asteroid-miner.js

  var WASM_B64 = "AGFzbQEAAAABbBNgAn9/AX9gAX8Bf2AAAX9gAAF9YAJ9fQF9YAN9fX0BfWADf39/AX9gBH19fX0BfWABfwF9YAF9AGADf39/AGAAAGACf38AYAF/AGACf30AYAN9fX0Bf2AFfX19fX0AYAN9fX0AYAR/f39/AANRUAABAQEBAgEDBAUGBwgIAAkICgsLBgoMCAgICAIDAgsCDQ4JDxARCQQECQMDCwsLEgsKCQMDAwMCAgMDAgICAgMCCAgDAwMCAgICAgICAgICBQMBAAEG/ANLfwBBAAt/AEEEC38AQRALfwBBDAt/AEGABgt/AEEoC38AQRwLfwBB4A4LfwBBKAt/AEEoC38AQaAbC38AQSALfwBBGAt/AEGgIQt/AEEIC38AQfgAC30AQwAAcEQLfQBDAAA0RAt9AEMAAHBCC30AQwAAoEELfQBDAAA0Qgt9AEMAAHBBC30AQ2ZmJj8LfQBDAAAEQwt9AEMAABBBC30AQ7gehT4LfQBDAABQQQt9AEMAAFJDC30AQwAA0EELfQBDAADAPwt9AEMAAARCC30AQwAAeEILfQBDAADmQwt9AEMAALhCC30AQwAAoEELfQBDAADIQgt9AEMAACBCC30AQwAAEEELfQBDKVyPPQt9AEMAAHBBC30AQwAAEUMLfQBDAACoQQt9AEMAAKBBC30AQwAAvkILfQBDAABgQQt9AEMAAABBC30AQwAAQEALfQBDAADAQQt9AEMAAABAC30AQwAAQEELfQBDAAAWQwt9AEMAAMhBC38BQZ/1haIEC38BQQALfQFDAAAAAAt9AUMAAL5CC30BQwAAoEELfwFBAQt/AUEAC30BQwAAYEELfwFBAAt9AUMAAAAAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALfwFBAAt/AUEAC38BQQALB7oDIwZtZW1vcnkCAAljYW5fYnVpbGQAFA1lbmVtaWVzX2FsaXZlAB8EaW5pdAAwCXNldF9pbnB1dAAxBHN0ZXAAMglnZXRfc2NvcmUAMwlnZXRfc2NyYXAANAhnZXRfY29yZQA1DGdldF9jb3JlX21heAA2CWdldF9sZXZlbAA3CWdldF9waGFzZQA4C2dldF9waGFzZV90ADkOZ2V0X2J1aWxkX3RpbWUAOgxnZXRfdG9fc3Bhd24AOw1nZXRfd2F2ZV9zaXplADwIZ2V0X2NvbHMAPQhnZXRfcm93cwA+CGdldF9jZWxsAD8MZ2V0X3BhdGhfbGVuAEAIZ2V0X2Nvc3QAQQlnZXRfcmFuZ2UAQgpnZXRfc3BsYXNoAEMMZ2V0X2hlYXRfbWF4AEQOZ2V0X2Vhcmx5X3JhdGUARQxpc19nYW1lX292ZXIARgpnZXRfYnVpbGRzAEcJZ2V0X3NlbGxzAEgJZ2V0X3Nob3RzAEkJZ2V0X2Jvb21zAEoJZ2V0X2tpbGxzAEsJZ2V0X2xlYWtzAEwJZ2V0X3RyaXBzAE0JZ2V0X3dhdmVzAE4LZ2V0X3JlZnVzZWQATwr3HlAQACMAIAEjAmwgAGojAWxqCwoAIwQgACMFbGoLCgAjByAAIwhsagsKACMKIAAjC2xqCwoAIw0gACMObGoLMwEBfyM0IQAgACAAQQ10cyEAIAAgAEERdnMhACAAIABBBXRzIQAgACQ0IABB/////wdxCwcAEAUgAHALCwAQBbNDAAAAT5ULDQAgABAHIAEgAJOUkgsiAQF9IAAhAyADIAFdBEAgASEDCyADIAJeBEAgAiEDCyADCyIBAX8gACEDIAMgAUgEQCABIQMLIAMgAkoEQCACIQMLIAMLHgECfSAAIAKTIQQgASADkyEFIAQgBJQgBSAFlJKRCw4AIACyQwAAAD+SIxKUCw4AIACyQwAAAD+SIxKUCxkAIABBAE4gACMCSHEgAUEATiABIwNIcXELCQAjNiAAkiQ2CxoAIABBAUYEfSMUBSAAQQJGBH0jFQUjEwsLCzABAX8gACABEAAhAyADQQE6AAAgAyACOgACIAIQBCAAEAw4AgAgAhAEIAEQDTgCBAvOAQEGf0ECIwNBBGsQBmohAUEAIQBBACEFQQIQBkUEf0F/BUEBCyECAkADQCAAIAEgBRARIAVBAWohBUEDEAYhA0EEEAZFBEBBACACayECCyACRQRAQQEhAgtBACEEAkADQCAEIANODQEgASACakEBSA0BIAEgAmojA0ECa0oNASABIAJqIQEgACABIAUQESAFQQFqIQUgBEEBaiEEDAALCyAAIwJBAWtODQEgBSMPQQhrTg0BIABBAWohAAwACwsgBSQ+IAAgARAAQQI6AAALLgEBf0EAIQACQANAIAAjAiMDbE4NASMAIAAjAWxqQQA2AgAgAEEBaiEADAALCwtEAQF/IAAgARAORQRAQQAPCyAAIAEQACEDIAMtAABBAEcEQEEADwsgAy0AAUEARwRAQQAPCyM3IAIQEF0EQEEADwtBAQvUAQEDfyAAIAEgAhAURQRAI0pBAWokSg8LQQAhAwJAA0AgAyMGTg0BIAMQASEEIAQqAhRDAAAAAFsEQCAEIAAQDDgCACAEIAEQDTgCBCAEIAKyOAIIIARDAAAAADgCDCAEQwAAAAA4AhAgBEMAAIA/OAIUIAQgABAMOAIYIAQgARANQwAAIEKTOAIcIARDAAAAADgCICAEQwAAAAA4AiQgACABEAAhBSAFIANBAWo6AAEjNyACEBCTJDcjQkEBaiRCDwsgA0EBaiEDDAALCyNKQQFqJEoLXQEDfyAAIAEQDkUEQA8LIAAgARAAIQIgAi0AASEDIANFBEAjSkEBaiRKDwsgA0EBaxABIQQjNyAEKgIIqBAQIxaUkiQ3IARDAAAAADgCFCACQQA6AAEjQ0EBaiRDCzEAIABBAUYEfUMAAIBBBSAAQQJGBH1DAAC4QgUgAEEDRgR9QwAAOEIFQwAA0EELCwsLMQAgAEEBRgR9QwAALEMFIABBAkYEfUMAAHhCBSAAQQNGBH1DAACoQgVDAADAQgsLCwsjACAAQQJGBH1DAABAQAUgAEEDRgR9QwAAAEAFQwAAgD8LCwsxACAAQQJGBH1DAADAQAUgAEEDRgR9QwAAoEAFIABBAUYEfUMAAABABUMAAEBACwsLC3ABAX8jOUECSARAQQAPC0HkABAGIQAjOUEESARAIABBHkgEf0EBBUEACw8LIzlBBkgEQCAAQRpIBH9BAQUgAEEsSAR/QQIFQQALCw8LIABBGEgEQEEBDwsgAEEsSARAQQIPCyAAQTxIBEBBAw8LQQALFABDAACAPyM5QQFrskO4HoU+lJILEwBBBSM5QQFrQQJsakEFQSIQCguiAQIDfwF9EBshAiACEBcQHJQhA0EAIQACQANAIAAjCU4NASAAEAIhASABKgIUQwAAAABbBEAgAUEAEAQqAgA4AgAgAUEAEAQqAgQ4AgQgASADOAIIIAEgAzgCDCABIAKyOAIQIAFDAACAPzgCFCABQwAAAAA4AhggAUMAAAAAOAIcIAFDAAAAADgCICABQwAAAAA4AiQPCyAAQQFqIQAMAAsLCzcBAn9BACEAAkADQCAAIwlODQEgABACKgIUQwAAAABeBEAgAUEBaiEBCyAAQQFqIQAMAAsLIAELJAAgAEMAAAAAOAIUI0ZBAWokRiM3IAAqAhCoEBqSJDcjMRAPCysAIAAgACoCCCABkzgCCCAAQ4/C9T04AiAgACoCCEMAAAAAXwRAIAAQIAsLhQMCA38HfUEAIQECQANAIAEjCU4NASABEAIhAiACKgIUQwAAAABeBEAgAioCIEMAAAAAXgRAIAIgAioCICAAkzgCIAsgAioCGKghAyACKgIcIQQgAioCEKgQGCEFAkADQCADIz5BAWtODQEgAxAEKgIAIQcgAxAEKgIEIQggA0EBahAEKgIAIQkgA0EBahAEKgIEIQogByAIIAkgChALIQYgBkMAAIA/XQRAIANBAWohAwwBCyAEIAUgAJQgBpWSIQQgBEMAAIA/XQ0BIARDAACAP5MhBCADQQFqIQMMAAsLIAMjPkEBa04EQCM4IAIqAhCoEBmTJDgjR0EBaiRHIAJDAAAAADgCFCM4QwAAAABfBEBDAAAAACQ4QQEkNQsFIAMQBCoCACEHIAMQBCoCBCEIIANBAWoQBCoCACEJIANBAWoQBCoCBCEKIAIgByAJIAeTIASUkjgCACACIAggCiAIkyAElJI4AgQgAiADsjgCGCACIAQ4AhwLCyABQQFqIQEMAAsLC3QCA38CfUF/IQVDAACAvyEGQQAhAwJAA0AgAyMJTg0BIAMQAiEEIAQqAhRDAAAAAF4EQCAAIAEgBCoCACAEKgIEEAsgAl8EQCAEKgIYIAQqAhySIQcgByAGXgRAIAchBiADIQULCwsgA0EBaiEDDAALCyAFC5QBAgJ/AX0gACABIAIgAxALQ28SgzqXIQdBACEFAkADQCAFIwxODQEgBRADIQYgBioCGEMAAAAAWwRAIAYgADgCACAGIAE4AgQgBiACIACTIAeVIyCUOAIIIAYgAyABkyAHlSMglDgCDCAGIAI4AhAgBiADOAIUIAZDAACAPzgCGCAGIAQ4AhwPCyAFQQFqIQUMAAsLC1UBAn8jRUEBaiRFQQAhAwJAA0AgAyMJTg0BIAMQAiEEIAQqAhRDAAAAAF4EQCAAIAEgBCoCACAEKgIEEAsjH18EQCAEIAIQIQsLIANBAWohAwwACwsLxgECAn8CfUEAIQECQANAIAEjDE4NASABEAMhAiACKgIYQwAAAABeBEAgAioCACACKgIIIACUkiEDIAIqAgQgAioCDCAAlJIhBCACIAM4AgAgAiAEOAIEIAMgBCACKgIQIAIqAhQQC0MAAGBBXwRAIAJDAAAAADgCGCADIAQgAioCHBAlCyADQwAAIMJdIAMjEEMAACBCkl5yIARDAAAgwl0gBCMRQwAAIEKSXnJyBEAgAkMAAAAAOAIYCwsgAUEBaiEBDAALCwtfAgJ/AX1BACECAkADQCACIwZODQEgAhABIQMgAyoCFEMAAAAAXiADKgIIQwAAAEBbcQRAIAAgASADKgIAIAMqAgQQCyMhXwRAIAQjIpIhBAsLIAJBAWohAgwACwsgBAtfAgJ/AX1BACECAkADQCACIwlODQEgAhACIQMgAyoCFEMAAAAAXiADKgIQQwAAQEBbcQRAIAAgASADKgIAIAMqAgQQCyMoXwRAIAQjKZIhBAsLIAJBAWohAgwACwsgBAunAwQDfwN9An8CfUEAIQECQANAIAEjBk4NASABEAEhAiACKgIUQwAAAABeBEAgAioCACEFIAIqAgQhBiACKgIIqCEDIAIqAgwhBCACKgIgQwAAAABeBEAgAiACKgIgIACTOAIgCyADQQJHBEAgBCAFIAYQKCAAlJIhBCAEIyUgBSAGECeSIACUkyEEIARDAAAAACMjEAkhBCAEIyNgBEAgAioCJEMAAAAAWwRAI0hBAWokSAsgAkMAAIA/OAIkCyACKgIkQwAAAABcIAQjJF9xBEAgAkMAAAAAOAIkCyACKgIQIACTIQogAioCJEMAAAAAWyAKQwAAAABfcQRAIANBAUYEfSMbBSMXCyEJIAUgBiAJECMhByAHQQBOBEAgBxACIQggAiAIKgIAOAIYIAIgCCoCBDgCHCNEQQFqJEQgA0EBRgRAIAUgBiAIKgIAIAgqAgQjHBAkIx0hCiAEIx6SIQQFIAgjGBAhIAIjJjgCICMZIQogBCMakiEECwsLIAIgBEMAAAAAIyMQCTgCDCACIApDAACAv5c4AhALCyABQQFqIQEMAAsLCxcAIywjOUEBa7JDAAAAP5STIy0jLBAJCx0AQ83MDD8jObJDQmBlPJSTQ+xROD5DzcwMPxAJCxgAQQEkOhAdJDxDMzOzPiQ9I0lBAWokSQstACM6QQBHBEAPCyM3IztDAAAAAJcjLpSSJDcjO0MAAAAAl0MAAMBAlBAPECwLIwBBACQ6IzcjLyM5siMwlJKSJDcjMhAPIzlBAWokORAqJDsLMQEBf0EAIQQCQANAIAQgAk4NASAAIAQgAWxqIANqQwAAAAA4AgAgBEEBaiEEDAALCwuGAQBBn/WFogQkNEEAJDVDAAAAACQ2IyskNyMqJDhBASQ5QQAkOiMsJDtBACQ8QwAAAAAkPUF/JD9BfyRAQQAkQUEAJEJBACRDQQAkREEAJEVBACRGQQAkR0EAJEhBACRJQQAkSiMEIwUjBkEUEC8jByMIIwlBFBAvIwojCyMMQRgQLxATEBILDgAgACQ/IAEkQCACJEELwwECAX0BfyM1QQBHBEAPCyAAQwAAAABDzcxMPRAJIQEjQSECQQAkQSACQQFOIAJBA0xxBEAjPyNAIAJBAWsQFQsgAkEERgRAIz8jQBAWCyACQQVGBEAQLQsjOkUEQCM7IAGTJDsjO0MAAAAAXwRAECwLBSM8QQBKBEAjPSABkyQ9Iz1DAAAAAF8EQBAeIzxBAWskPBArJD0LCwsgARAiIzVBAEcEQA8LIAEQKSABECYjOkEBRiM8QQBMEB9FcXEEQBAuCwsKACM2IzgjM5SSCwQAIzcLBAAjOAsEACMqCwQAIzkLBAAjOgsEACM7CwQAECoLBAAjPAsEABAdCwQAIwILBAAjAwsEACMSCwQAIz4LBgAgABAQCxoAIABBAUYEfSMbBSAAQQJGBH0jIQUjFwsLCwQAIx8LBAAjIwsEACMuCwQAIzULBAAjQgsEACNDCwQAI0QLBAAjRQsEACNGCwQAI0cLBAAjSAsEACNJCwQAI0oL";

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
      boom: function () { noise(0.22, 0.07); tone(220, 60, 0.24, 'sawtooth', 0.05); },
      build: function () { tone(300, 620, 0.11, 'triangle', 0.05); },
      sell: function () { tone(620, 260, 0.11, 'triangle', 0.045); },
      refuse: function () { tone(180, 130, 0.09, 'square', 0.035); },
      trip: function () { tone(500, 150, 0.20, 'sawtooth', 0.05); },
      leak: function () { noise(0.28, 0.09); tone(150, 70, 0.3, 'sawtooth', 0.06); },
      wave: function () { tone(320, 520, 0.16, 'square', 0.05); },
      clear: function () { tone(520, 900, 0.22, 'triangle', 0.055); },
      over: function () { tone(230, 40, 1.0, 'sawtooth', 0.085); },
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
      '</div>' +
      '<div class="td-stage">' +
        '<canvas class="td-canvas" width="' + WORLD_W + '" height="' + WORLD_H + '"></canvas>' +
        '<div class="td-scan" aria-hidden="true"></div>' +
        '<div class="td-overlay td-note" data-td="note"></div>' +
        '<div class="td-overlay td-msg" data-td="msg">CORE LOST<small data-td="msgsmall">PRESS R TO RESTART</small></div>' +
      '</div>' +
      '<div class="td-tools">' +
        '<button type="button" class="td-tool td-on" data-td="t0"><b>1 PYLON</b><span>20 · fast gun</span></button>' +
        '<button type="button" class="td-tool" data-td="t1"><b>2 MORTAR</b><span>45 · splash</span></button>' +
        '<button type="button" class="td-tool" data-td="t2"><b>3 VENT</b><span>15 · cools</span></button>' +
        '<button type="button" class="td-tool td-sell" data-td="t3"><b>4 SELL</b><span>65% back</span></button>' +
        '<button type="button" class="td-tool td-go" data-td="go"><b>SPACE</b><span>call the wave</span></button>' +
      '</div>' +
      '<div class="td-help" data-td="help">' +
        'CLICK A SQUARE TO BUILD &nbsp; GUNS OVERHEAT — VENTS COOL THE EIGHT SQUARES AROUND THEM ' +
        '&nbsp; [R] RESTART &nbsp; [M] MUTE</div>';
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
    var toolEls = [q('t0'), q('t1'), q('t2'), q('t3')];

    function enableTouchUI() {
      if (root.classList.contains('td-is-touch')) return;
      root.classList.add('td-is-touch');
      helpEl.textContent =
        'PICK A TOOL, THEN TAP A SQUARE • GUNS OVERHEAT — VENTS COOL THE EIGHT SQUARES AROUND THEM • TAP TO RESTART';
      q('msgsmall').textContent = 'TAP TO RESTART';
    }
    if (global.matchMedia && global.matchMedia('(pointer: coarse)').matches) enableTouchUI();

    // ---------- per-instance state ----------
    var wasm = null, f32 = null, u8 = null;
    var destroyed = false;
    var rafId = 0, lastT = 0, tGlobal = 0;
    var sound = createSound();
    var muted = false;
    var particles = [];
    var shake = 0, flash = 0;
    var prevBuilds = 0, prevSells = 0, prevShots = 0, prevBooms = 0;
    var prevLeaks = 0, prevTrips = 0, prevWaves = 0, prevRefused = 0, prevOver = 0;
    var prevLevel = 1;
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
      if (e.key === 'r' || e.key === 'R') restart();
      if (e.key === 'm' || e.key === 'M') toggleMute();
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
      pendingAction = (e.button === 2 || tool === 3) ? 4 : tool + 1;
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

        if (hp < maxHp) {
          var bw = LOW_SCALE * 10;
          var bx = snap(x) - bw / 2, by = snap(y) - LOW_SCALE * 7;
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
        : !!wasm.exports.can_build(hoverC, hoverR, tool);
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
        hudPhase.textContent = 'BUILD ' + Math.max(0, Math.ceil(e.get_phase_t())) + 's';
        goBtn.classList.add('td-armed');
      } else {
        hudPhase.textContent = 'INCOMING ' +
          (e.get_wave_size() - e.get_to_spawn()) + '/' + e.get_wave_size();
        goBtn.classList.remove('td-armed');
      }
      for (var i = 0; i < 3; i++) {
        toolEls[i].classList.toggle('td-poor', scrap < e.get_cost(i));
      }
    }

    // ---------- loop ----------
    function loop(now) {
      if (destroyed) return;
      var dt = Math.max(0, Math.min((now - lastT) / 1000, 0.05));
      lastT = now;
      tGlobal += dt;

      wasm.exports.set_input(hoverC, hoverR, pendingAction);
      pendingAction = 0;
      trackShells();
      wasm.exports.step(dt);
      pollEvents(now);

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
      wasm.exports.init();
      f32 = new Float32Array(wasm.exports.memory.buffer);
      u8 = new Uint8Array(wasm.exports.memory.buffer);
      particles.length = 0;
      shake = 0; flash = 0; noteT = 0;
      pendingAction = 0;
      setTool(0);
      prevBuilds = wasm.exports.get_builds();
      prevSells = wasm.exports.get_sells();
      prevShots = wasm.exports.get_shots();
      prevBooms = wasm.exports.get_booms();
      prevLeaks = wasm.exports.get_leaks();
      prevTrips = wasm.exports.get_trips();
      prevWaves = wasm.exports.get_waves();
      prevRefused = wasm.exports.get_refused();
      prevLevel = wasm.exports.get_level();
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
        };
      },
    };
  }

  global.TowerDefense = { mount: mount };

})(window);
