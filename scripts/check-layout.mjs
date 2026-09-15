#!/usr/bin/env node
/**
 * Verifies that each widget's copy of its engine's memory layout still agrees
 * with the engine — the offsets, and the order of the fields inside every
 * record.
 *
 *   node scripts/check-layout.mjs
 *
 * ## Why this exists
 *
 * Every game here is two halves that must agree on where things are in linear
 * memory: `game.wat` declares `(global $ROCKS_OFF i32 (i32.const 24))`, and the
 * widget declares `var ROCKS_OFF = 24` so it can walk the same records to draw
 * them. **Nothing links the two.** Get it wrong and the failure is silent: the
 * engine keeps simulating correctly while the renderer reads velocity as
 * position. No exception, no console error, just a game that draws nonsense.
 *
 * That is the class of bug `--check` already prevents between a `.wat` and its
 * committed `.wasm`. This extends the same idea across the boundary the
 * conventions could not.
 *
 * ## Two checks
 *
 * **Named constants.** Each title lists the offsets, strides and counts that
 * both sides spell the same way, and their values must match.
 *
 * **Field order.** This one used to be missing, and the gap was not
 * hypothetical: while Tower Defense was being built, capping its tower pool
 * moved every pool after it, and a bench harness with an offset written out as
 * a literal went on reading the old address and reported — plausibly and
 * completely wrongly — that no tower had ever hit anything. The engine and the
 * widget both read `f32[a + 4]`-style positions that neither side named, so
 * nothing could notice field 4 becoming field 5.
 *
 * Now both sides name them. Each engine's memory-map comment carries one
 * machine-readable line per record,
 *
 *     ;; @fields rock f32 ROCK_STRIDE: x y vx vy radius size active spin
 *
 * and each widget declares the same thing as a table it reads through,
 *
 *     var FIELD = { rock: { x: 0, y: 1, vx: 2, vy: 3, radius: 4, ... } };
 *     if (f32[a + FIELD.rock.active] <= 0) continue;
 *
 * This script fails if:
 *
 *  - a widget's FIELD table disagrees with the engine's `@fields` line — a
 *    missing field, an extra one, or one at a different position;
 *  - an `@fields` line disagrees with the prose field list a human reads in the
 *    same comment, or with the record's stride (more fields than fit);
 *  - a widget reads a typed array at a bare numeric position — `f32[a + 4]`,
 *    `f32[0]`, `u8[cell + 1]` — instead of through FIELD, because a raw number
 *    is exactly the read that silently goes stale.
 *
 * ## What it still does not check
 *
 * The engine's own reads. `game.wat` loads fields with `(f32.load offset=20
 * (local.get $a))`, and there is no way to know from that line which record
 * `$a` points at, so the engine side of field order is still the memory-map
 * comment kept honest by hand. What is guaranteed is narrower and still worth
 * having: the comment, the prose, the stride and the widget can no longer
 * disagree with each other without this script saying so.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Per title, the constants that appear on both sides under the same name. A
 * new game belongs here the moment its widget copies an offset — and its
 * engine needs `@fields` lines and its widget a FIELD table before this passes.
 *
 * Pixel Wave was left out for a long time on the belief that its widget spelled
 * the constants differently from its engine. By the time anyone checked, it did
 * not: both sides already said BOTS_OFF, BOT_STRIDE and the rest, so the title
 * had been unguarded for no reason at all.
 */
const TITLES = [
  {
    slug: 'pixel-wave',
    js: 'pixel-wave.js',
    names: ['BOTS_OFF', 'BOT_STRIDE', 'MAX_BOTS', 'BULLETS_OFF', 'BULLET_STRIDE',
            'MAX_BULLETS', 'AST_OFF', 'AST_STRIDE', 'MAX_AST'],
  },
  {
    slug: 'grid-breaker',
    js: 'grid-breaker.js',
    names: ['BALLS_OFF', 'BALL_STRIDE', 'MAX_BALLS', 'POWER_OFF', 'POWER_STRIDE',
            'MAX_POWER', 'TILES_OFF', 'TILE_STRIDE', 'COLS', 'ROWS'],
  },
  {
    slug: 'worm-chase',
    js: 'worm-chase.js',
    names: ['COLS', 'ROWS', 'GRID_OFF', 'CELL_STRIDE', 'CHASER_OFF',
            'CHASER_STRIDE', 'MAX_CHASERS'],
  },
  {
    slug: 'asteroid-miner',
    js: 'asteroid-miner.js',
    names: ['ROCKS_OFF', 'ROCK_STRIDE', 'MAX_ROCKS', 'BULLETS_OFF', 'BULLET_STRIDE',
            'MAX_BULLETS', 'PICKUPS_OFF', 'PICKUP_STRIDE', 'MAX_PICKUPS'],
  },
  {
    slug: 'circuit-runner',
    js: 'circuit-runner.js',
    names: ['RUNNER_OFF', 'PARTS_OFF', 'PART_STRIDE', 'MAX_PARTS',
            'PICKUPS_OFF', 'PICKUP_STRIDE', 'MAX_PICKUPS'],
  },
  {
    slug: 'starfield-runner',
    js: 'starfield-runner.js',
    names: ['SHIP_OFF', 'ROCKS_OFF', 'ROCK_STRIDE', 'MAX_ROCKS'],
  },
  {
    slug: 'tower-defense',
    js: 'tower-defense.js',
    names: ['GRID_OFF', 'CELL_STRIDE', 'COLS', 'ROWS', 'TOWERS_OFF', 'TOWER_STRIDE',
            'MAX_TOWERS', 'ENEMIES_OFF', 'ENEMY_STRIDE', 'MAX_ENEMIES',
            'SHELLS_OFF', 'SHELL_STRIDE', 'MAX_SHELLS', 'PATH_OFF', 'PATH_STRIDE'],
  },
  {
    slug: 'pulse',
    js: 'pulse.js',
    names: ['BAR_OFF', 'BAR_STRIDE', 'ENEMIES_OFF', 'ENEMY_STRIDE', 'MAX_ENEMIES',
            'BOLTS_OFF', 'BOLT_STRIDE', 'MAX_BOLTS'],
  },
  {
    slug: 'sector-defense',
    js: 'sector-defense.js',
    names: ['ENEMIES_OFF', 'ENEMY_STRIDE', 'MAX_ENEMIES', 'PB_OFF', 'PB_STRIDE',
            'MAX_PB', 'EB_OFF', 'EB_STRIDE', 'MAX_EB'],
  },
];

const SIZE = { f32: 4, i32: 4, u8: 1 };

let failed = false;
const fail = (slug, msg) => { console.error(`  ${slug}: ${msg}`); failed = true; };

function watGlobal(wat, name) {
  const m = wat.match(new RegExp(`\\(global \\$${name} i32 \\(i32\\.const (-?\\d+)\\)`));
  return m ? Number(m[1]) : null;
}

/** The memory-map comment: from the MEMORY LAYOUT banner to the closing rule. */
function memoryMap(wat) {
  const start = wat.indexOf('MEMORY LAYOUT');
  if (start < 0) return null;
  const end = wat.indexOf('\n  ;; ===================================================', start);
  return end < 0 ? null : wat.slice(start, end);
}

/** `;; @fields rock f32 ROCK_STRIDE: x y vx ...` → [{ pool, type, stride, names }] */
function parseFields(map) {
  const out = [];
  const re = /;;\s*@fields\s+(\w+)\s+(f32|i32|u8)\s+(\w+|-)\s*:\s*(.+)$/gm;
  let m;
  while ((m = re.exec(map))) {
    out.push({ pool: m[1], type: m[2], stride: m[3], names: m[4].trim().split(/\s+/) });
  }
  return out;
}

/**
 * `var FIELD = { rock: { x: 0, ... }, ... };` → { rock: { x: 0, ... } }. The
 * table is written one record per line on purpose, which is what makes it
 * parseable without a JavaScript parser.
 */
function parseFieldTable(js) {
  const start = js.search(/\bvar FIELD = \{/);
  if (start < 0) return null;
  const end = js.indexOf('\n  };', start);
  if (end < 0) return null;
  const table = {};
  const re = /^\s*(\w+):\s*\{([^}]*)\},?\s*$/gm;
  const body = js.slice(start, end);
  let m;
  while ((m = re.exec(body))) {
    const fields = {};
    for (const [, k, v] of m[2].matchAll(/(\w+):\s*(\d+)/g)) fields[k] = Number(v);
    table[m[1]] = fields;
  }
  return table;
}

for (const title of TITLES) {
  const wat = readFileSync(join(ROOT, 'games', title.slug, 'game.wat'), 'utf8');
  const js = readFileSync(join(ROOT, 'games', title.slug, title.js), 'utf8');
  const errorsBefore = failed;
  failed = false;

  // ---- 1. named constants ----
  for (const name of title.names) {
    // `(global $NAME i32 (i32.const 24))` on one side, `var NAME = 24` — or
    // `NAME = 24` in a shared declaration list — on the other.
    const inWat = watGlobal(wat, name);
    const inJs = js.match(new RegExp(`\\b${name}\\s*=\\s*(-?\\d+)`));
    if (inWat === null) fail(title.slug, `game.wat declares no global $${name}`);
    else if (!inJs) fail(title.slug, `${title.js} declares no ${name}`);
    else if (String(inWat) !== inJs[1]) {
      fail(title.slug, `$${name} is ${inWat} in game.wat but ${inJs[1]} in ${title.js}`);
    }
  }

  // ---- 2. field order ----
  const map = memoryMap(wat);
  const records = map ? parseFields(map) : [];
  const table = parseFieldTable(js);
  if (!map) fail(title.slug, 'game.wat has no MEMORY LAYOUT comment');
  if (!records.length) fail(title.slug, 'the memory-map comment has no @fields lines');
  if (!table) fail(title.slug, `${title.js} has no \`var FIELD = { ... };\` table`);

  const prose = map
    ? map.split('\n').filter((l) => !l.includes('@fields'))
        .map((l) => l.replace(/^\s*;;/, '').replace(/[\s()]/g, ''))
    : [];

  let fieldCount = 0;
  for (const rec of records) {
    fieldCount += rec.names.length;

    if (rec.stride !== '-') {
      const stride = watGlobal(wat, rec.stride);
      if (stride === null) fail(title.slug, `@fields ${rec.pool}: no global $${rec.stride}`);
      else if (rec.names.length * SIZE[rec.type] > stride) {
        fail(title.slug, `@fields ${rec.pool}: ${rec.names.length} ${rec.type} fields ` +
          `do not fit in a ${stride}-byte stride`);
      }
    }

    // The human-readable list in the same comment must say the same thing.
    if (rec.type === 'u8') {
      rec.names.forEach((n, i) => {
        if (!new RegExp(`byte\\s+${i}\\s+${n}\\b`).test(map)) {
          fail(title.slug, `@fields ${rec.pool}: the prose has no "byte ${i}  ${n}" line`);
        }
      });
    } else {
      const want = rec.names.join(',');
      if (!prose.some((l) => l.includes(want))) {
        fail(title.slug, `@fields ${rec.pool}: no prose line lists "${rec.names.join(', ')}"`);
      }
    }

    if (!table) continue;
    const got = table[rec.pool];
    if (!got) {
      fail(title.slug, `FIELD has no ${rec.pool} record`);
      continue;
    }
    rec.names.forEach((n, i) => {
      if (!(n in got)) fail(title.slug, `FIELD.${rec.pool} is missing ${n} (field ${i})`);
      else if (got[n] !== i) {
        fail(title.slug, `FIELD.${rec.pool}.${n} is ${got[n]} but the engine puts it at ${i}`);
      }
    });
    for (const k of Object.keys(got)) {
      if (!rec.names.includes(k)) fail(title.slug, `FIELD.${rec.pool}.${k} is not a field in game.wat`);
    }
  }
  if (table) {
    for (const k of Object.keys(table)) {
      if (!records.some((r) => r.pool === k)) {
        fail(title.slug, `FIELD.${k} has no @fields line in game.wat`);
      }
    }
  }

  // ---- 3. no bare numeric reads ----
  js.split('\n').forEach((raw, i) => {
    if (raw.includes('WASM_B64')) return;
    // Comments may quote the pattern they forbid — FIELD's own does.
    const line = raw.replace(/\/\/.*$/, '');
    const bare =
      /\b(?:f32|i32|u8)\[\s*\d+\s*\]/.test(line) ||                       // f32[4]
      /\b(?:f32|i32|u8)\[[^\]]*[+-]\s*\d+\s*\]/.test(line) ||             // f32[a + 4]
      /\b(?:f32|i32|u8)\[[^\]]*[+-]\s*\d+\s*\)\s*>>\s*2\s*\]/.test(line); // f32[(X + 4) >> 2]
    if (bare) {
      fail(title.slug, `${title.js}:${i + 1} reads a record at a bare number — ` +
        `use FIELD: ${line.trim()}`);
    }
  });

  if (!failed) {
    console.log(`ok: ${title.slug} (${title.names.length} constants, ` +
      `${fieldCount} fields in ${records.length} records agree)`);
  }
  failed = failed || errorsBefore;
}

if (failed) {
  console.error('\nThe widget and its engine disagree about linear memory.');
  console.error('Fix the FIELD table or the constants at the top of the widget, or the');
  console.error('@fields lines and globals in game.wat — whichever is the one that moved.');
  process.exit(1);
}
