#!/usr/bin/env node
/**
 * Compiles every game's `game.wat` to `game.wasm`, and re-embeds the result
 * anywhere a build has been inlined as base64.
 *
 *   node scripts/build.mjs                 # build everything
 *   node scripts/build.mjs pixel-wave      # build one title
 *   node scripts/build.mjs --check         # compile, compare, change nothing
 *
 * `--check` is the mode worth wiring into CI. The `.wasm` files are committed —
 * a visitor opening `games/<title>/index.html` from a checkout has no build step
 * — which means the binary and its source can silently drift apart. `--check`
 * recompiles into memory and fails if what lands on disk is not what the `.wat`
 * currently says.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * `embed` describes an inlined copy of the binary. Pixel Wave ships as a
 * single-file widget with the engine as a base64 string, so that a consumer
 * copies two files and makes zero network requests at runtime — the trade is
 * that the string has to be rewritten whenever the engine changes, and nothing
 * about the file format would tell you if it hadn't been.
 */
const TITLES = [
  {
    slug: 'vector-arena',
    wat: 'games/vector-arena/game.wat',
    wasm: 'games/vector-arena/game.wasm',
    embed: [],
  },
  {
    slug: 'pixel-wave',
    wat: 'games/pixel-wave/game.wat',
    wasm: 'games/pixel-wave/game.wasm',
    embed: [
      {
        file: 'games/pixel-wave/pixel-wave.js',
        pattern: /var WASM_B64 = "[A-Za-z0-9+/=]*";/,
        render: (b64) => `var WASM_B64 = "${b64}";`,
      },
    ],
  },
];

const argv = process.argv.slice(2);
const check = argv.includes('--check');
const wanted = argv.filter((a) => !a.startsWith('--'));

let wabt;
try {
  wabt = await (await import('wabt')).default();
} catch {
  console.error('wabt is not installed. Run `npm install` first.');
  process.exit(1);
}

/** Compile one .wat to bytes, with names resolved and the module validated. */
function compile(watPath) {
  const source = readFileSync(join(ROOT, watPath), 'utf8');
  const mod = wabt.parseWat(watPath, source);
  try {
    // resolveNames turns $identifiers into indices; validate is what catches a
    // type error in the stack machine. Skipping either lets a broken module
    // reach the browser, where the failure surfaces as a bare LinkError.
    mod.resolveNames();
    mod.validate();
    return Buffer.from(mod.toBinary({}).buffer);
  } finally {
    mod.destroy();
  }
}

let failed = false;

for (const title of TITLES) {
  if (wanted.length && !wanted.includes(title.slug)) continue;

  const bytes = compile(title.wat);
  const b64 = bytes.toString('base64');
  const onDisk = readFileSync(join(ROOT, title.wasm));

  if (check) {
    if (!onDisk.equals(bytes)) {
      console.error(`stale: ${title.wasm} does not match ${title.wat}`);
      failed = true;
    }
    for (const e of title.embed) {
      if (!readFileSync(join(ROOT, e.file), 'utf8').includes(b64)) {
        console.error(`stale: embedded engine in ${e.file} does not match ${title.wat}`);
        failed = true;
      }
    }
    if (!failed) console.log(`ok: ${title.slug} (${bytes.length} bytes)`);
    continue;
  }

  writeFileSync(join(ROOT, title.wasm), bytes);
  console.log(`${relative('.', title.wasm)} — ${bytes.length} bytes`);

  for (const e of title.embed) {
    const path = join(ROOT, e.file);
    const src = readFileSync(path, 'utf8');
    if (!e.pattern.test(src)) {
      console.error(`could not find the embed slot in ${e.file}`);
      failed = true;
      continue;
    }
    writeFileSync(path, src.replace(e.pattern, e.render(b64)));
    console.log(`  embedded into ${e.file}`);
  }
}

if (failed) process.exit(1);
