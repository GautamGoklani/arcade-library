# arcade-library

Browser arcade games whose entire simulation is hand-written WebAssembly Text —
and a full WebAssembly course built around them.

No game engine. No compiler front-end. No runtime dependency. JavaScript
forwards input and draws what it reads back out of linear memory; everything
else — physics, enemy AI, bullet pools, collisions, the level curve — is WAT.

```
arcade-library/
├── CLAUDE.md           ← how this repo is built: invariants, conventions, gotchas
├── index.html          ← landing page; open it, or npm run serve
├── games/
│   ├── pixel-wave/     ← retro wave shooter, 3.5 KB engine, keyboard + touch
│   ├── grid-breaker/   ← brick breaker, 4.4 KB engine, keyboard + pointer + touch
│   ├── worm-chase/     ← grid territory capture, 3.8 KB engine, no imports
│   ├── asteroid-miner/ ← mining run, 4.2 KB engine, fuel and cargo, 320x240
│   └── sector-defense/ ← wave defence, 3.6 KB engine, shield + combo, 320x240
├── docs/               ← the course: 20 chapters, glossary, cheatsheet
└── scripts/            ← build.mjs (wat → wasm) and serve.mjs
```

---

## Play

Every game is committed with its compiled binary, so a fresh checkout is
playable with nothing installed:

```bash
git clone https://github.com/GautamGoklani/arcade-library
cd arcade-library
```

Open any game's `index.html` directly — each is a single-file build with the
engine embedded, so `file://` works.

For the landing page and the docs, serve it:

```bash
npm install
npm run serve      # http://localhost:8080
```

| | |
|---|---|
| **[Pixel Wave](games/pixel-wave/)** | The swarm patrols the upper half of the arena, asteroids fall, and every cleared level adds one more enemy. 33 enemies, 160 bullets, endless levels. Keyboard and touch |
| **[Grid Breaker](games/grid-breaker/)** | Brick breaking where the layout, the ball physics and the power-up drops all live in the engine. Paddle follows the pointer, or an on-screen stick on touch. Keyboard, pointer and touch |
| **[Worm Chase](games/worm-chase/)** | Leave your territory, loop back, and a flood fill decides what your trail sealed off. Hazards, and chasers that cannot follow you home. Hold to move. Keyboard and touch |
| **[Asteroid Miner](games/asteroid-miner/)** | Rocks split when shot and pebbles pay out in gems. Fuel burns while you thrust, the hold holds twelve, and only the depot turns either into progress. Drawn at 320x240 with scanlines. Keyboard and touch |
| **[Sector Defense](games/sector-defense/)** | Hold a line against attackers that each pick their own path across the field. A shield that only recovers once the shooting stops, and a combo that decays. Keyboard and touch |

---

## Learn WebAssembly

[**docs/**](docs/) is the substantial part of this repository: a course in three
parts, written to be read in order, with the Pixel Wave, Worm Chase, Asteroid
Miner and Sector Defense engines as the worked example in Part III. Grid Breaker arrived after the
first seventeen chapters were written and is not covered by it; its own
[README](games/grid-breaker/README.md) documents it instead.
The links below are the Markdown sources, which is what renders on
GitHub; the same chapters are also built as browsable HTML at
[`docs/index.html`](docs/index.html) for the served site.

**Part I — the language.** [What WebAssembly actually
is](docs/01-what-is-webassembly.md) · [Reading and writing
WAT](docs/02-wat-syntax.md) · [Numbers and
operations](docs/03-numbers-and-operations.md) · [Control
flow](docs/04-control-flow.md) · [Linear memory](docs/05-linear-memory.md) ·
[Functions and tables](docs/06-functions-tables.md) · [The JavaScript
boundary](docs/07-javascript-interop.md) · [Globals and module
state](docs/08-globals-and-state.md)

**Part II — the ecosystem.** [The toolchain](docs/09-toolchain.md) · [Source
languages](docs/10-source-languages.md) · [Beyond the
browser](docs/11-beyond-the-browser.md) · [The security
model](docs/12-security-model.md) · [Debugging and
profiling](docs/13-debugging-and-profiling.md) · [Post-MVP
features](docs/14-post-mvp-features.md)

**Part III — these engines.** [Game loop
architecture](docs/15-game-loop-architecture.md) · [Entity pools in linear
memory](docs/16-entity-pools.md) · [Maths without a standard
library](docs/17-math-without-a-stdlib.md) · [A grid, and the flood fill that
closes a loop](docs/18-grids-and-flood-fill.md) · [Pools that grow their own
contents](docs/19-pools-that-grow.md) · [Giving each entity its own
intent](docs/20-per-entity-intent.md)

**Reference.** [Glossary](docs/glossary.md) · [Instruction
cheatsheet](docs/cheatsheet.md) · [Further reading](docs/further-reading.md)

It covers a good deal more than what these games happen to use — WASI, the
Component Model, the security model's real limits, SIMD, threads, choosing a
source language, and an honest account of when WebAssembly is the wrong tool.

---

## Build

```bash
npm install                  # wabt (assembler) and marked (docs renderer)
npm run build                # engines + documentation
npm run build:engines        # every game.wat → game.wasm
npm run build:docs           # every docs/*.md → docs/*.html
npm run check                # verify all build output matches its sources,
                             #   and that each widget agrees with its engine
npm run serve                # static server with the right wasm MIME type
```

Two things are committed that a build could regenerate, both deliberately:

- **The `.wasm` binaries**, so a fresh checkout is playable with no toolchain.
- **The `docs/*.html` pages**, so GitHub Pages can serve the documentation
  without a build step. The `.md` files remain the source of truth and are the
  only thing to edit.

`npm run check` is what stops either silently drifting — it recompiles and
re-renders in memory, compares, and changes nothing. It also verifies every
relative link in the generated pages resolves. Wire it into CI.

Every title carries its engine as base64 inside its widget JS, so each is two
files with no network requests at runtime. The build re-embeds it.

### Why the docs are rendered to HTML

Markdown reads fine on github.com, which is where the sources are meant to be
read. But this repository is also *served* — from the landing page, from
`npm run serve`, from GitHub Pages — and there a `.md` file arrives as
`text/markdown` and the browser shows unstyled plain text with every `#` and
`|` intact. Twenty chapters of that is not documentation anyone will read.

Rendering at build time gives real HTML that works with JavaScript disabled, is
indexable, and supports find-in-page on first load — none of which a
client-side Markdown viewer manages.

---

## Using a game in your own page

Pixel Wave ships as a self-contained widget. Copy two files:

```html
<link rel="stylesheet" href="pixel-wave.css">
<div id="game"></div>
<script src="pixel-wave.js"></script>
<script>
  const game = PixelWave.mount('#game');
  // game.restart() · game.getState() · game.destroy()
</script>
```

Multiple instances on one page are independent. See
[`games/pixel-wave/README.md`](games/pixel-wave/README.md) for the options and
the memory layout.

Grid Breaker, Worm Chase, Asteroid Miner and Sector Defense ship the same way,
as `GridBreaker.mount()`, `WormChase.mount()`, `AsteroidMiner.mount()` and
`SectorDefense.mount()` — see their READMEs for options and memory layouts.

See [chapter 7](docs/07-javascript-interop.md) for the difference between
shipping a widget like these and shipping a bare engine for a host to render.

---

## Why hand-write the engines

To learn the machine without a compiler in the way. It is explicitly **not** a
recommendation — [chapter 10](docs/10-source-languages.md) is blunt about what
it costs, and Rust, Zig or AssemblyScript are the right answers for real work.

What the exercise produced, though, is five complete games in **strict MVP
WebAssembly**: four value types, one 64 KiB memory, structured control flow, and
two imports — `sinf` and `cosf` — which Worm Chase and Sector Defense do not
need at all. No post-MVP feature, no feature detection, no fallback build. They
run on anything that has ever supported WebAssembly.

The documentation is the deliverable. The games are the excuse.

---

MIT licensed. Engines, sprites and documentation written by hand.
The original Pixel Wave project documents are in
[`docs/reference/`](docs/reference/), with a note on where they now disagree
with the code.
