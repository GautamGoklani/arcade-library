# Worm Chase

A territory game on a 32×24 grid. You are not avoiding your own tail — you are
drawing with it. Leave your land, loop back into it, and everything the loop
sealed off becomes yours. Everything about that — the grid, the flood fill that
decides what "sealed off" means, the chasers, the hazards and the level curve —
is hand-written in WebAssembly Text (`game.wat`) and runs as a compiled `.wasm`
binary. JavaScript forwards a direction, calls `step(dt)`, and draws what it
finds in the engine's linear memory.

Works on **desktop (hold an arrow or WASD)** and **mobile (hold and drag
anywhere)**.

Open [`index.html`](index.html) to play it.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.wc-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, fixed offsets in linear memory, an xorshift RNG, and an `init` /
`set_input` / `step` / `get_*` export surface.

The reason is the same one [Grid Breaker's README](../grid-breaker/README.md)
gives: a shared engine library would mean a change made for one game could break
another. Copying costs a few hundred duplicated lines and buys the guarantee
that nothing else in the repo can break this game. Tooling is the exception —
the shared [`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` can verify all four committed binaries in one pass.

### It has no imports

Pixel Wave, Grid Breaker and Asteroid Miner all import `sinf` and `cosf`,
because they steer in continuous space and WebAssembly has no trigonometry
instruction. This engine imports **nothing**:

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

Nothing here turns through an angle. A worm occupies a cell or it does not,
every heading is one of four `(dx, dy)` pairs, and every decision in the
simulation is an integer comparison. The module is a pure function of `init`,
the input stream and `dt` — which is also why the headless bench below can
replay a run exactly.

## Files

```
worm-chase/
├── worm-chase.js     ← the widget (engine embedded inside) — REQUIRED
├── worm-chase.css    ← scoped styles (.wc-*)               — REQUIRED
├── game.wat          ← engine SOURCE — edit to change gameplay
├── game.wasm         ← compiled engine (also embedded in the .js as base64)
├── index.html        ← standalone page: the game and nothing else
├── demo.html         ← minimal working integration example
├── logo.svg          ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`worm-chase.js` and `worm-chase.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="worm-chase.css">

<div id="game"></div>

<script src="worm-chase.js"></script>
<script>
  var game = WormChase.mount('#game');
</script>
```

### JavaScript API

```js
var game = WormChase.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, lives, level, owned, target, total, gameOver }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop                   | Mobile                 |
|---------|---------------------------|------------------------|
| Move    | hold ← ↑ → ↓ or W A S D   | hold and drag anywhere |
| Stop    | let go                    | lift your thumb        |
| Restart | R                         | tap the GAME OVER text |
| Mute    | M                         | the SOUND button       |

### Hold to move, let go to stop

This is not a snake that drives itself. **The worm moves only while you are
holding a direction and stops the moment you let go**, which makes standing
still a move: you can park on the edge of your territory, watch where the pack
is going, and commit to a loop when the gap opens.

Stopping is not a pause. The chasers keep their own clock running, so a worm
that stops halfway round a loop feels them closing on the trail it left behind —
and the trail does not fade while you think about it.

Two details make it feel right rather than mushy:

- **Setting off is immediate.** A press from a standstill takes the heading on
  the same frame instead of waiting for the tick to read it.
- **Tapping is not faster than holding.** The worm's clock keeps running while
  it stands still, banking at most one tick. Zeroing it on release and refilling
  it on press — the obvious implementation — would make a mashed key the
  quickest way to travel. Pause as long as you like and set off instantly; tap
  as fast as you like and move at exactly the same speed.

A held direction is still stored as a *request* rather than written straight
onto the heading, and three things fall out of that:

- A turn typed mid-cell lands **on the cell boundary**, not a frame later.
- Holding two keys cannot wedge the worm diagonally. There is one slot, the last
  press wins, and a diagonal request resolves onto whichever axis the worm is
  not already travelling along. Releasing one of two held keys hands steering
  back to the other rather than stopping.
- A straight reversal is rejected while moving, because it would drive the head
  into the cell the worm just left. **Stopping first defeats that guard** — from
  a standstill every direction is legal, including back down your own trail,
  which is fatal. The trail kills; the engine does not make an exception for the
  cell you came from.

The worm also starts each life **stationary**. One that resumed the instant it
respawned would be steered by whichever key was held when it died, which is
never the key the player wanted.

### The touch stick

Unlike Grid Breaker's paddle rail, the steering zone here is **the whole
board**: a worm turns on both axes, so there is no half of the screen that could
be reserved for anything else, and a thumb that had to find a corner would cost
the turn. The ring re-anchors under wherever the thumb lands and the knob moves
freely, but the reading is **snapped to the dominant axis** past a dead zone —
a worm has four headings, so an analog value would only ever be rounded to one
of them. That rounding happens in the widget, which keeps `set_input` honest
about what it accepts.

The stick is hold-to-move like the keys: inside the dead zone, or with the thumb
lifted, it reports "nothing held" and the worm stops.

As in Grid Breaker, which scheme you get is decided per *event* by
`pointerType`, not by sniffing the device at mount: a mouse never steers, a
finger or pen always does, and `(pointer: coarse)` only chooses what is
*shown* until the first touch corrects it.

## Gameplay rules

- **Claim by enclosing.** Outside your territory the worm lays a trail. Re-enter
  your own land and the trail, plus everything it sealed off, becomes yours.
- **You move only while holding a direction.** Letting go stops the worm but not
  the chasers.
- **5 lives.** You lose one by hitting the board edge, a hazard, or your own
  trail — or by letting a chaser touch your head **or cross your trail**. The
  trail is the vulnerable thing; getting home fast is the whole game.
- **Chasers cannot enter your territory.** That is what makes captured ground
  worth having and gives a cornered worm somewhere to run to. While you are safe
  at home they roam; the moment you lay a trail they hunt.
- **Enclosing is a reward.** Hazards caught inside a capture are cleared (+20
  each) and chasers fenced in are destroyed (+150 each).
- A level ends when you hold enough of the board. The share needed starts at
  **34%** and climbs 4 points a level to a ceiling of 72%.
- Every level is a fresh board: a 5×5 home block in the middle, hazards
  scattered clear of it, and the chasers respawned away from it.

### Scoring

| event | points |
|---|---|
| cell claimed | 4 |
| hazard cleared by a capture | 20 |
| chaser fenced in | 150 |
| level cleared | 250 |

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ worm-chase.js (JavaScript)                           │
│   • builds DOM, reads keyboard and touch input       │
│   • calls wasm exports each frame:                   │
│       set_input(dx, dy) on change → step(dt)         │
│   • reads the 768-cell grid and the chaser records   │
│     straight out of wasm linear memory and draws them│
│   • interpolates the worm and the chasers between    │
│     ticks using get_tick_frac / get_chase_frac       │
│   • particles, screen shake and sound are presentation│
│     only — triggered by diffing the engine's event   │
│     counters frame to frame                          │
└───────────────▲──────────────────────────────────────┘
                │ exports: init, set_input, step, and the
                │ get_* readers listed below, plus memory
┌───────────────┴──────────────────────────────────────┐
│ game.wasm (compiled from hand-written game.wat)      │
│   • the worm's tick, turn queue and death rules      │
│   • trail laying and the flood fill that closes it   │
│   • chaser roam/hunt behaviour on a separate clock   │
│   • hazard and chaser placement, level generation    │
│   • score/lives state machine                        │
└──────────────────────────────────────────────────────┘
```

### WASM linear memory layout

| region  | offset | stride | count | fields |
|---------|--------|--------|-------|--------|
| grid    | 0      | 4 B    | 768   | `state`, `hazard`, `mark`, `epoch` — one byte each; cell (c,r) at `(r*32 + c)*4` |
| queue   | 3072   | 4 B    | 768   | the flood fill's BFS frontier, one `i32` cell index per slot |
| chasers | 6144   | 32 B   | 8     | cx, cy, pcx, pcy, dx, dy, active (all `i32`) |

`state` is 0 open, 1 owned, 2 trail. `hazard` is 0 or 1. `mark` is flood-fill
scratch and is meaningless between steps. `epoch` is 1–6, cycling, stamped on
each cell when a capture claims it — the renderer shades territory by it, so the
board records which push took which ground without the engine storing a
timestamp.

Everything scalar — score, lives, level, the owned count — lives in a **global**
rather than in memory, because the `get_*` readers are the only consumer and a
global is one instruction to read. Grid Breaker puts its score at a fixed
address instead, but its renderer was already walking memory for the tile grid.

**If you change this layout in `game.wat`, change the constants at the top of
`worm-chase.js` with it.** Nothing links the two at build time.

### Exports

`init`, `set_input(dx, dy)`, `step(dt)`, `memory`, and the readers:
`get_score`, `get_lives`, `get_level`, `get_owned`, `get_target`, `get_total`,
`get_trail_len`, `is_game_over`, `get_head_x`, `get_head_y`, `get_prev_x`,
`get_prev_y`, `get_dir_x`, `get_dir_y`, `get_tick_frac`, `get_chase_frac`,
`get_capture_count`, `get_capture_cells`, `get_deaths`, `get_kills`.

`get_prev_*` and `get_tick_frac` exist for one reason: the worm advances a whole
cell per tick, roughly seven times a second, and drawing it only where the
engine says it is would animate at 7 fps on a 60 fps canvas. The renderer
interpolates between the previous cell and the current one instead.

The last four are **event counters**. The engine never calls out — it has no
imports at all — so a monotonic counter is the whole notification channel:
JavaScript diffs them between frames to decide what to play and what to shake.

## The one interesting problem: what counts as enclosed

The rule "everything your loop sealed off becomes yours" needs a definition of
*sealed off*, and the obvious ones are all traps. Point-in-polygon needs the
trail to be a polygon, which it is not once it doubles back on itself. Tracing
the loop's interior needs a consistent winding, which a trail that re-enters
your territory at an arbitrary angle does not have.

`$capture` inverts the question. It converts the trail to territory, then floods
**inward from the four edges of the board**, marking everything the outside can
still reach. Whatever is left unmarked and unowned is, by definition, fenced in.

That is a breadth-first search over at most 768 cells, with the frontier queue
at a fixed offset in linear memory — sized for the whole grid, because that is
the worst case and there is no allocator to ask for more. It runs on the tick
that closes a loop and nowhere else. It is also completely indifferent to what
shape the trail was, which is what lets the game accept a figure-of-eight, a
loop drawn back across old territory, or a trail that touches the board edge.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$TICK_BASE` / `$TICK_STEP` / `$TICK_MIN` | seconds per worm tick at level 1, per-level decrease, floor | 0.140 / 0.005 / 0.072 |
| `$CHASE_BASE` / `$CHASE_STEP` / `$CHASE_MIN` | the same three for chasers | 0.260 / 0.011 / 0.105 |
| `$START_LIVES` | starting lives | 5 |
| `$HOME_HALF` | half-width of the free home block | 2 (a 5×5 patch) |
| `$SCORE_CELL` / `$SCORE_HAZARD` / `$SCORE_CHASER` / `$SCORE_LEVEL` | scoring | 4 / 20 / 150 / 250 |

The level curve is three functions rather than three constants, all of them
keyed on the level number and all of them clamped:

| per level | level 1 | growth | ceiling |
|---|---|---|---|
| share of the board needed | 34% | +4 points | 72% |
| hazards | 2 | +6 | 96 |
| chasers | 1 | +1 every second level | 8 |

### Three findings from benching, all of them about level 1

The engine's RNG is seeded to a constant, so level 1 is the same board every
run and a headless pilot driving the compiled binary reproduces exactly.

1. **Greedy chasers made leaving home a coin flip.** In the first build they
   homed in on the worm's head at all times. Because they cannot enter
   territory, they all converged on the boundary cell nearest the head, parked
   there, and killed the worm on the tick it stepped out — three deaths in four
   seconds, with no capture ever made. They now **roam while the worm is home**
   and only hunt once a trail exists. Roaming also keeps them apart; identical
   AI chasing an identical target stacks them into a single blob.
2. **A death used to cost two more.** Respawning put the worm back on owned
   ground with the pack still pressed against the boundary it had just died on.
   `$scatter_chasers` now throws every chaser to a random cell at least 11 cells
   away, so the next life starts with room.
3. **The opening was tuned down across the board.** Level 1 shipped at two
   chasers, 16 hazards, a 45% target and chasers at 73% of the worm's speed. It
   now opens at one chaser, two hazards, a 34% target, and chasers at 54% of the
   worm's speed — the first level has to teach the loop-and-claim rule before it
   starts punishing it. The late-game numbers did not move; the curve just
   starts lower and climbs by level number.

After the retune the same pilot — which plans nothing and never defends its
trail — reaches levels 3–4 and survives 45–80 seconds. Every one of its deaths
that is not a wall, hazard or self-collision is a chaser cutting the trail,
which is the mechanic working rather than a bug.

## Rebuilding the engine

```bash
npm install                  # wabt is a devDependency of this repo
npm run build:worm-chase     # game.wat -> game.wasm, re-embedded into the .js
npm run check                # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `worm-chase.js` are both committed, so a
fresh checkout plays with nothing installed — which is exactly the arrangement
that lets a binary drift away from the `.wat` it claims to be built from.
`npm run check` recompiles into memory and fails if either committed copy
disagrees with the source. It covers every title, so run it before pushing an
engine change.

## Browser support

Any browser with WebAssembly. No build step, no dependencies, no imports, and no
network requests at runtime — the engine ships inside the JS file.
