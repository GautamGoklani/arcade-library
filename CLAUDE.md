# arcade-library — working notes

Browser arcade games whose entire simulation is **hand-written WebAssembly
Text**, plus a 21-chapter WebAssembly course built around them. No game engine,
no compiler front-end, no runtime dependency. JavaScript forwards input and
draws what it reads out of linear memory; everything else is WAT.

**The documentation is the deliverable. The games are the excuse.** When a
change would improve the code but weaken the explanation, the explanation wins.

---

## Commands

```bash
npm install                  # wabt (assembler) and marked (docs renderer)
npm run build                # engines + documentation
npm run build:<slug>         # one engine, e.g. npm run build:worm-chase
npm run build:docs           # every docs/*.md → docs/*.html
npm run check                # THE guard — run before every commit
npm run serve                # static server on :8080 with the right wasm MIME type
```

`npm run check` is three checks in one, and all three exist because something in
this repo is committed that a build could regenerate:

1. **`build.mjs --check`** recompiles every `game.wat` in memory and fails if the
   committed `.wasm` — or the base64 copy embedded in the widget — differs.
2. **`build-docs.mjs --check`** re-renders every chapter and fails if the
   committed `.html` differs, then verifies every relative link resolves.
3. **`check-layout.mjs`** compares each widget's memory-layout constants against
   its engine's globals. See "The layout hazard" below.

---

## Layout

```
TASKS.md                the open backlog — read it before picking up work
index.html              landing page / arcade hub — a card per game
games/<slug>/           one self-contained game each (see below)
games/plans-for-other-games.md    roadmap: shipped, still to build, build order
docs/                   the course: 21 chapters + glossary, cheatsheet, reading list
docs/reference/         original .docx project documents, kept as a historical record
scripts/build.mjs       wat → wasm, and re-embeds base64 into each widget
scripts/build-docs.mjs  md → html, generates docs/index.html, checks links
scripts/check-layout.mjs  widget constants vs engine globals
scripts/serve.mjs       dev server
```

### The games

| Slug | Engine | Shape | Notes |
|---|---|---|---|
| `pixel-wave` | 3.5 KB | wave shooter | the first title; the course's main worked example |
| `grid-breaker` | 4.5 KB | paddle and ball | arrived from a portfolio repo; predates some conventions |
| `worm-chase` | 3.9 KB | grid territory capture | **no imports**; hold-to-move |
| `asteroid-miner` | 4.2 KB | mining run | splitting entities, fuel/cargo; first with the retro renderer |
| `sector-defense` | 3.6 KB | wave defence | **no imports**; per-entity intent, two meters instead of lives |
| `circuit-runner` | 3.0 KB | endless lane runner | **no imports**; nothing to shoot, generated board, tap-zone touch |

Vector Arena was removed in `e90bc03`. Chapters 6, 7 and 17 still teach
techniques drawn from it and say so inline; do not "fix" those by deleting the
material.

---

## Hard invariants

Break these and the repository stops being what it is.

1. **No game shares code with any other game.** Not a utility, not a sprite
   helper, not an RNG. What titles share is *conventions*, copied by hand. The
   reason is blunt: a shared library means a change made for one game can break
   another, and each title is meant to stand alone as a piece of work. Copying
   costs a few hundred duplicated lines and buys that guarantee. Tooling is the
   single exception — one builder, so `--check` can cover every title at once.

2. **Every game owns a CSS prefix, and no other game may use it.**
   `pw-` `gb-` `wc-` `am-` `sd-` `cr-`. Every rule is namespaced under `.<prefix>-root`
   so a widget can be dropped into someone else's page.

3. **JavaScript owns no game state.** It forwards input, calls `step(dt)`, and
   reads entity records out of linear memory to draw them. If a rule lives in
   the widget, it is in the wrong file.

4. **The engine never calls out.** No imported callbacks. It exposes monotonic
   **event counters** (`get_kills`, `get_deaths`, …) and the widget diffs them
   between frames to decide what to play and what to shake. One place decides
   what happened, so sound, particles and shake can never disagree.

5. **Strict MVP WebAssembly.** Four value types, one 64 KiB page, structured
   control flow, at most two imports (`sinf`/`cosf`; three engines need none). No
   post-MVP feature, no feature detection, no fallback build. If a proposal
   would help, say so in a comment and don't use it — chapter 14 does exactly
   that for `memory.fill`.

6. **The committed `.wasm` and `docs/*.html` must match their sources.** They are
   committed so a fresh checkout is playable and GitHub Pages needs no build.
   `npm run check` is what stops them drifting. Never hand-edit either.

7. **Comments explain decisions, not syntax.** The prevailing style is to record
   *why* a constant is that number and what broke at the other value — usually
   with the measurement that settled it. Match it; it is most of the value here.

---

## The layout hazard

Each game is two halves that must agree on where things are in memory:

```wat
(global $ROCKS_OFF i32 (i32.const 24))     ;; games/asteroid-miner/game.wat
```
```js
var ROCKS_OFF = 24, ROCK_STRIDE = 32;      // games/asteroid-miner/asteroid-miner.js
```

Nothing links them at build time. Get it wrong and there is **no error** — the
engine simulates correctly while the renderer reads velocity as position.
`scripts/check-layout.mjs` now guards the named constants; it cannot guard
*field order* within a record, because neither side names fields. The memory-map
comment at the top of each `game.wat` is the schema — keep it honest, including
the arithmetic showing where each region ends.

---

## Adding a game

1. `games/<slug>/game.wat` — globals block at top, memory-map comment with the
   arithmetic, xorshift RNG, `init` / `set_input` / `step` / `get_*` exports,
   event counters.
2. `games/<slug>/<slug>.js` — the widget. `<Name>.mount(container, opts)`
   returning `{ restart, destroy, getState }`. `opts.wasmUrl` and
   `opts.wasmBase64` are supported everywhere. Include
   `var WASM_B64 = "";` — the builder fills it.
3. `games/<slug>/<slug>.css` — everything under `.<prefix>-root`.
4. `index.html` (standalone page) and `demo.html` (minimal integration example).
   Copy an existing pair; the `--<prefix>-max-width` hook is how the standalone
   page caps width by available height.
5. `logo.svg` — generated by a throwaway Python script in the same pixel
   language the game uses. 480×300, `shape-rendering="crispEdges"`.
6. `README.md` — controls, memory layout table, exports, tuning table, and the
   findings from benching. These are long on purpose.
7. Register in `scripts/build.mjs` `TITLES`, add `build:<slug>` to
   `package.json`, add the constants to `scripts/check-layout.mjs`.
8. Update `index.html` (hub card + counts), root `README.md` (tree, table,
   counts), `games/plans-for-other-games.md` (move from "still to build" to
   "shipped").
9. `npm run build && npm run check`.

### The retro render treatment

Everything from Asteroid Miner onward draws into a **320×240 buffer blown up 3×
with smoothing off**. New titles should assume it; Pixel Wave and Grid Breaker
have not been retrofitted. Circuit Runner adds one wrinkle worth copying when it
applies: variable-width things (its 1- and 2-lane components) are drawn
procedurally with `fillRect` on the low-res grid rather than from ASCII sprites,
because an ASCII grid has one width.

```js
var low = document.createElement('canvas');
low.width = WORLD_W / LOW_SCALE;   // 320
low.height = WORLD_H / LOW_SCALE;  // 240
var g = low.getContext('2d');
g.imageSmoothingEnabled = false;
// every frame, still in 960x720 world units:
g.setTransform(1 / LOW_SCALE, 0, 0, 1 / LOW_SCALE, 0, 0);
// ...draw...
screen.drawImage(low, 0, 0, WORLD_W, WORLD_H);
```

The 1/3 transform is the entire adapter — no draw-code coordinate changes. Then:
**no glow anywhere** (`shadowBlur` is the giveaway that a picture was made after
about 1995 — brightness comes from a brighter colour), everything snapped to
whole low-res pixels including screen shake, and scanlines + vignette in CSS
(`.<prefix>-scan`) so they sit at true display resolution. Drop both under
`prefers-reduced-motion`.

---

## Verifying a change

### Bench the engine headlessly — this is the primary tool

The browser preview pane in this environment **stops issuing animation frames
within a fraction of a second of load** (measured: 0 rAF/sec). You can confirm
that a widget boots and renders a first frame, but you cannot drive gameplay
there. Do not burn turns trying.

Instead, drive the compiled binary directly from Node. Every engine is
deterministic — in-module xorshift seeded to a constant — so a run replays
exactly. Write the harness to a temp file, run, delete.

```js
import wabtInit from 'wabt';
import { readFileSync } from 'node:fs';
const w = await wabtInit();
const m = w.parseWat('game.wat', readFileSync('games/<slug>/game.wat', 'utf8'));
m.resolveNames(); m.validate();
const { instance: { exports: e } } =
  await WebAssembly.instantiate(m.toBinary({}).buffer,
    { env: { sinf: Math.sin, cosf: Math.cos } });   // {} for import-free engines
e.init();
const f32 = new Float32Array(e.memory.buffer);      // walk pools like the widget does
for (let i = 0; i < 60 * 300; i++) { e.set_input(/* … */); e.step(1 / 60); }
```

Note the harness must live inside the repo (or import `wabt` by absolute path) —
`node_modules` is not reachable from the scratchpad.

This is how every difficulty number in the READMEs was arrived at, and it has
found real bugs that reading could not: a 75-second soft-lock in Asteroid Miner,
chasers camping a boundary in Worm Chase, and a descent cap in Sector Defense so
low the pilot cleared 28 waves without a single attacker reaching the line.

### Tuning lessons that keep recurring

- **Level 1 must be gentle, and difficulty must scale with the level number.**
  This was corrected once already, by the repo owner, mid-build.
- Write a pilot that plays *badly* — no route planning, no dodging. If that
  pilot cannot reach level 3, a human is going to have a bad time.
- A ceiling the player never reaches is not a difficulty curve.
- A harder wave should not simply be a longer wave.
- Always check for the dead-time case: a state where the player has no agency
  and nothing is happening. Fix it in the design, not with a timer.

---

## The course (`docs/`)

Markdown is the source of truth; the `.html` is generated and committed so
GitHub Pages serves it with no build step. **Never edit the `.html`.**

Adding a chapter: write `docs/NN-slug.md`, add it to `PARTS` in
`scripts/build-docs.mjs` (a chapter without an entry is silently never rendered
or linked), add a row to the table in `docs/README.md`, update the previous
chapter's forward nav link and both nav lines in the new one, and bump the
chapter count in `index.html` and root `README.md`.

Part III (15–20) is the case-study half, one chapter per idea rather than one
per game:

| | |
|---|---|
| 15 | the game loop, who owns the clock |
| 16 | entity pools in linear memory |
| 17 | maths without a standard library |
| 18 | a fixed grid, and a flood fill with no allocator |
| 19 | pools that grow their own contents; the resolution you draw at |
| 20 | per-entity intent; meters instead of lives |
| 21 | generating a world that is always winnable |

---

## Gotchas

- **Line endings are load-bearing.** `--check` byte-compares. `.gitattributes`
  pins text to LF on checkout; without it, `core.autocrlf=true` hands the
  builders CRLF and every generated page reports stale on a clean clone.
- **`node --check <widget>.js` before committing.** The widgets are plain ES5
  IIFEs with no build step, so nothing else will catch a syntax error.
- **Heredocs mangle backslashes and em-dashes.** For anything with regexes or
  typography, write a script file and run it rather than piping a heredoc.
- **Long heredocs hit a command-length limit** on this platform. Use the Write
  tool for anything substantial.
- The preview pane's rAF freeze is described above. `preview_start` revives it
  for a moment, which is enough for one screenshot of a first frame.

---

## Roadmap status

**[`TASKS.md`](TASKS.md) is the backlog** — verification debt, missing CI, the
two titles that predate the retro renderer, and the library goals not yet built.
Read it before starting anything; it is written to be picked up cold.

Shipped: Pixel Wave, Grid Breaker, Worm Chase, Asteroid Miner, Sector Defense,
Circuit Runner. The original build order is complete. Remaining concepts:
**Starfield Runner** (cheapest, but it scrolls toward the player like Circuit
Runner does — build its tight-squeeze scoring idea first or do not build it),
**Pulse** (needs an audio system that does not exist yet), **Tower Defense
Lite**.

Deliberately not built: shared high-score storage, and the "shared engine
template / sprite toolkit" the original plan called for — see the note in
`games/plans-for-other-games.md` for why that goal was abandoned rather than
missed.
