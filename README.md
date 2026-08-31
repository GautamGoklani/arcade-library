# arcade-library

Browser arcade games whose entire simulation is hand-written WebAssembly Text —
and a full WebAssembly course built around them.

No game engine. No compiler front-end. No runtime dependency. JavaScript
forwards input and draws what it reads back out of linear memory; everything
else — physics, enemy AI, bullet pools, collisions, the level curve — is WAT.

```
arcade-library/
├── index.html          ← landing page; open it, or npm run serve
├── games/
│   ├── pixel-wave/     ← retro wave shooter, 3.5 KB engine, keyboard + touch
│   └── vector-arena/   ← vector-glow dogfighting, 2.7 KB engine
├── docs/               ← the course: 17 chapters, glossary, cheatsheet
└── scripts/            ← build.mjs (wat → wasm) and serve.mjs
```

---

## Play

Both games are committed with their compiled binaries, so a fresh checkout is
playable with nothing installed:

```bash
git clone https://github.com/GautamGoklani/arcade-library
cd arcade-library
```

Open `games/vector-arena/index.html` or `games/pixel-wave/index.html` directly —
both are single-file builds with the engine embedded, so `file://` works.

For the landing page and the docs, serve it:

```bash
npm install
npm run serve      # http://localhost:8080
```

| | |
|---|---|
| **[Pixel Wave](games/pixel-wave/)** | The swarm patrols the upper half of the arena, asteroids fall, and every cleared level adds one more enemy. 33 enemies, 160 bullets, endless levels. Keyboard and touch |
| **[Vector Arena](games/vector-arena/)** | Six bots that orbit at range, strafe, lead their shots against your velocity and dodge yours by computing closest approach. Wrap-around arena. Keyboard |

---

## Learn WebAssembly

[**docs/**](docs/) is the substantial part of this repository: a course in three
parts, written to be read in order, with these two engines as the worked example
in Part III. The links below are the Markdown sources, which is what renders on
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
library](docs/17-math-without-a-stdlib.md)

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
npm run check                # verify all build output matches its sources
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

Pixel Wave additionally carries its engine as base64 inside `pixel-wave.js`, so
the widget is two files with no network requests at runtime. The build re-embeds
it.

### Why the docs are rendered to HTML

Markdown reads fine on github.com, which is where the sources are meant to be
read. But this repository is also *served* — from the landing page, from
`npm run serve`, from GitHub Pages — and there a `.md` file arrives as
`text/markdown` and the browser shows unstyled plain text with every `#` and
`|` intact. Seventeen chapters of that is not documentation anyone will read.

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

Vector Arena ships as a bare engine — see
[`games/vector-arena/README.md`](games/vector-arena/README.md) for its exports
and offsets, and [chapter 7](docs/07-javascript-interop.md) for the difference
between the two integration shapes.

---

## Why hand-write the engines

To learn the machine without a compiler in the way. It is explicitly **not** a
recommendation — [chapter 10](docs/10-source-languages.md) is blunt about what
it costs, and Rust, Zig or AssemblyScript are the right answers for real work.

What the exercise produced, though, is a pair of complete games in **strict
MVP WebAssembly**: four value types, one 64 KiB memory, structured control flow,
two imports. No post-MVP feature, no feature detection, no fallback build. They
run on anything that has ever supported WebAssembly.

The documentation is the deliverable. The games are the excuse.

---

MIT licensed. Engines, sprites and documentation written by hand.
The original Pixel Wave project documents are in
[`docs/reference/`](docs/reference/), with a note on where they now disagree
with the code.
