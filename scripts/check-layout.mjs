#!/usr/bin/env node
/**
 * Verifies that each widget's copy of its engine's memory layout still agrees
 * with the engine.
 *
 *   node scripts/check-layout.mjs
 *
 * ## Why this exists
 *
 * Every game here is two halves that must agree on where things are in linear
 * memory: `game.wat` declares `(global $ROCKS_OFF i32 (i32.const 24))`, and the
 * widget declares `var ROCKS_OFF = 24` so it can walk the same records to draw
 * them. **Nothing links the two.** Each game's README says so in bold, which is
 * a warning rather than a guard — and a warning is exactly the wrong tool,
 * because the failure is silent. Move a pool by 8 bytes and the engine keeps
 * simulating correctly while the renderer reads velocity as position: no
 * exception, no console error, just a game that draws nonsense.
 *
 * That is the class of bug `--check` already prevents between a `.wat` and its
 * committed `.wasm`. This extends the same idea across the boundary the
 * conventions could not.
 *
 * ## What it does not check
 *
 * Only the constants named below, and only their values. It cannot tell that
 * field 4 of a record became field 5, because neither side names fields — the
 * `.wat` documents them in a comment and the widget reads `f32[a + 4]`. Keeping
 * *those* in step is still a human job, and the memory-map comment at the top
 * of each `game.wat` is the schema to keep honest.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Per title, the constants that appear on both sides under the same name. A
 * new game belongs here the moment its widget copies an offset.
 *
 * Pixel Wave is absent deliberately: its widget predates this convention and
 * spells the constants differently on each side, so there is no name to match
 * on. Renaming them to match is the way in, not a special case here.
 */
const TITLES = [
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
    slug: 'sector-defense',
    js: 'sector-defense.js',
    names: ['ENEMIES_OFF', 'ENEMY_STRIDE', 'MAX_ENEMIES', 'PB_OFF', 'PB_STRIDE',
            'MAX_PB', 'EB_OFF', 'EB_STRIDE', 'MAX_EB'],
  },
];

let failed = false;

for (const title of TITLES) {
  const wat = readFileSync(join(ROOT, 'games', title.slug, 'game.wat'), 'utf8');
  const js = readFileSync(join(ROOT, 'games', title.slug, title.js), 'utf8');
  let agreed = 0;

  for (const name of title.names) {
    // `(global $NAME i32 (i32.const 24))` on one side, `var NAME = 24` — or
    // `NAME = 24` in a shared declaration list — on the other.
    const inWat = wat.match(new RegExp(`\\(global \\$${name} i32 \\(i32\\.const (-?\\d+)\\)`));
    const inJs = js.match(new RegExp(`\\b${name}\\s*=\\s*(-?\\d+)`));

    if (!inWat) {
      console.error(`  ${title.slug}: game.wat declares no global $${name}`);
      failed = true;
    } else if (!inJs) {
      console.error(`  ${title.slug}: ${title.js} declares no ${name}`);
      failed = true;
    } else if (inWat[1] !== inJs[1]) {
      console.error(
        `  ${title.slug}: $${name} is ${inWat[1]} in game.wat ` +
        `but ${inJs[1]} in ${title.js}`);
      failed = true;
    } else {
      agreed++;
    }
  }

  if (agreed === title.names.length) {
    console.log(`ok: ${title.slug} (${agreed} layout constants agree)`);
  }
}

if (failed) {
  console.error('\nThe widget and its engine disagree about linear memory.');
  console.error('Fix the constants at the top of the widget, or the globals in game.wat.');
  process.exit(1);
}
