# Grid Breaker

A paddle-and-ball wall breaker whose entire simulation — ball physics, swept
collision, the tile grid, chain-reacting bombs, power-ups and the level curve —
is hand-written in WebAssembly Text (`game.wat`) and runs as a compiled `.wasm`
binary. JavaScript forwards input, calls `step(dt)`, and draws what it finds in
the engine's linear memory.

Works on **desktop (keyboard or mouse)** and **mobile (left thumbstick)**.

Open [`index.html`](index.html) to play it.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.gb-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
shooters is *conventions*, copied by hand: a globals block at the top of the
`.wat`, entity pools at fixed offsets, an xorshift RNG, and an `init` /
`set_input` / `step` / `get_*` export surface.

The reason is blunt: a shared engine library would mean a change made for one
game could break another, and each title here is meant to stand on its own as a
piece of work. Copying costs a few hundred duplicated lines and buys the
guarantee that nothing else in the repo can break this game.

Tooling is the one exception, and it changed when this game moved into this
repository. Grid Breaker arrived from the portfolio repo with its own
`build.js`, on the same isolation argument. Here it is built by the shared
[`scripts/build.mjs`](../../scripts/build.mjs) instead, because a single builder
is what makes `npm run check` able to verify every title's committed `.wasm`
against its `.wat` in one pass — and with the binaries committed, that drift
check is worth more than per-title build isolation.

## Files

```
grid-breaker/
├── grid-breaker.js   ← the widget (engine embedded inside) — REQUIRED
├── grid-breaker.css  ← scoped styles (.gb-*)               — REQUIRED
├── game.wat          ← engine SOURCE — edit to change gameplay
├── game.wasm         ← compiled engine (also embedded in the .js as base64)
├── index.html        ← standalone page: the game and nothing else
├── demo.html         ← minimal working integration example
├── logo.svg          ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`grid-breaker.js` and `grid-breaker.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="grid-breaker.css">

<div id="game"></div>

<script src="grid-breaker.js"></script>
<script>
  var game = GridBreaker.mount('#game');
</script>
```

### JavaScript API

```js
var game = GridBreaker.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, lives, level, tilesLeft, gameOver }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop                    | Mobile                 |
|---------|----------------------------|------------------------|
| Move    | A / D, ← / →, or the mouse | left thumbstick        |
| Launch  | Space                      | LAUNCH button (right)  |
| Restart | R                          | tap the GAME OVER text |
| Mute    | M                          | the SOUND button       |

On desktop, moving the mouse takes over steering and pressing a key hands it
back. The engine is told which is driving (`ptrActive`), so the two never fight.

### The thumbstick

Touch devices get a stick rather than a d-pad. The left half of the arena is a
steering zone: the ring re-anchors under wherever your thumb lands, so there is
nothing to hunt for and no reason to look away from the ball. The right thumb
keeps LAUNCH, so steering and serving are two independent fingers.

**The knob only travels horizontally**, and the ring is drawn with a rail across
it. The paddle has one axis; a knob that slid vertically would promise control
that does not exist.

It is analog, and that is the point: `set_input` takes the direction as an `f32`
and the engine applies it as `x += dir * PADDLE_SPEED * dt`, so anything in
`[-1, 1]` is legal. A nudge walks the paddle into position for a delicate edge
hit; a full push sprints it across the arena. The keyboard is the special case
that can only ever ask for `-1`, `0` or `1`. No engine change was needed.

### Which controls you get is decided per event, not per device

There is no device sniffing. Both schemes are bound at once and every pointer is
routed by its **`pointerType`**: a mouse only ever steers, a finger or pen only
ever works the stick and the button. They cannot fight, because no pointer can
drive both.

This matters because the obvious test is wrong. `'ontouchstart' in window` is
true on every touchscreen laptop, so classing the device as "touch" takes mouse
steering away from someone holding a mouse — and on a hybrid machine the right
answer changes the moment they put it down.

So the touch overlay is **always in the DOM and always interactive**, and only
its *visibility* is gated. Hiding it with `display: none` would swallow the very
first touch on a device the media query guessed wrong about, leaving the stick
dead until a second tap. `(pointer: coarse)` — without the `ontouchstart`
fallback — describes the *primary* pointer, so it is true on phones and tablets
and false on a laptop with a touchscreen, which makes it a good initial guess for
presentation. A first touch corrects it, whatever it guessed.

The result on a touchscreen laptop: mouse steering by default, the stick appears
the moment a finger lands, and the mouse keeps working afterwards.

Input is one pointer registry on `.gb-stage` keyed by `pointerId`, not listeners
per control. That is what makes the two-finger case hold up: a second finger on
the button cannot release it for the first, `pointercancel` shares a release path
with `pointerup` so nothing latches on, and the button stays held while a thumb
slides off it.

## Gameplay rules

- Clear every breakable tile to advance. There is no last level.
- **5 lives.** Losing the last ball in play costs one.
- The paddle steers the ball: the **ends deflect hardest** (up to 1.05 rad off
  vertical), the middle sends it *almost* straight back — never exactly, see
  the degenerate-state note under Tuning. Speed is never changed by a bounce,
  so aim is the only thing the paddle gives you.
- **Tough tiles** (steel, cracked once hit) take two hits. **Bombs** take out
  every neighbour, and a neighbouring bomb chains. **Solid tiles** (riveted)
  never break and never block a level from being cleared.
- Power-ups fall from broken tiles — catch them with the paddle:

  | capsule | effect | for |
  |---------|--------|-----|
  | **WIDE** | paddle grows by 55% | 12s |
  | **MULTI** | every ball in play splits into three | — |
  | **SLOW** | the ball travels at 68% speed | 9s |
  | **STICKY** | the ball is caught on the paddle; Space launches it | 15s |

- A level is a fresh wall: one of five patterns (checkerboard, solid, pyramid,
  stripes, lattice frame), a row deeper every second level up to 10 rows, with
  bombs and tough tiles growing more common as levels climb.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ grid-breaker.js (JavaScript)                         │
│   • builds DOM, reads keyboard/mouse/touch input     │
│   • calls wasm exports each frame:                   │
│       set_input(dir, launch, ptrOn, ptrX) → step(dt) │
│   • reads the tile grid and entity records straight  │
│     out of wasm linear memory and draws them         │
│   • particles, screen shake and sound are presentation│
│     only, triggered by diffing the engine's event    │
│     counters between frames                          │
└───────────────▲──────────────────────────────────────┘
                │ exports: init, set_input, step, get_score,
                │ get_lives, get_level, get_tiles_left,
                │ balls_alive, is_game_over, get_wide,
                │ get_slow, get_sticky, memory,
                │ and the event counters: get_breaks,
                │ get_chips, get_booms, get_bounces,
                │ get_powers, get_drains, get_launches,
                │ get_hurts, get_clears, get_last_break_row
┌───────────────┴──────────────────────────────────────┐
│ game.wasm (compiled from hand-written game.wat)      │
│   • paddle motion, pointer easing, clamping          │
│   • ball physics with sub-stepped swept collision    │
│   • tile grid, damage, bomb chain reactions          │
│   • power-up spawn/fall/catch and their timers       │
│   • level generation, score/lives state machine      │
└──────────────────────────────────────────────────────┘
```

### Event counters, added after the fact

This title arrived from a portfolio repository without the event counters every
later title has, and its widget worked out what had happened by snapshotting
all 180 tiles each frame and diffing hit points, counting live balls, and
watching lives and level for changes. That is the renderer deciding what the
rules did — the thing invariant 4 in [`CLAUDE.md`](../../CLAUDE.md) exists to
prevent — and it had a cost nobody had noticed: **the widget carried `paddle`,
`power` and `launch` sounds that were never once played.** None of those events
leaves anything in memory to diff. A paddle bounce changes a velocity, a caught
capsule vanishes, a launch clears a flag.

The engine now increments a counter at the line where each event is decided —
`breaks`, `chips`, `booms`, `bounces`, `powers`, `drains`, `launches`, `hurts`,
`clears` — plus one scalar, `get_last_break_row()`, because the brick sound is
pitched by row and a count cannot say where a break was. A bomb chain plays one
boom rather than a boom and nine bricks.

The tile diff survives, demoted: it only decides *where* to put sparks, which
is a drawing question. Adding the counters changed nothing about the
simulation — the same 600-second headless run produced an identical level,
score, lives and paddle-path hash before and after.

### WASM linear memory layout

| region    | offset | stride | count | fields |
|-----------|--------|--------|-------|--------|
| paddle    | 0      | —      | 1     | x, y, halfW, vx |
| balls     | 16     | 32 B   | 6     | x, y, vx, vy, radius, active, stuck, stickOff |
| powerups  | 208    | 24 B   | 8     | x, y, vx, vy, kind, active |
| tiles     | 400    | 8 B    | 180   | hp, kind — cell (c,r) at 400 + (r*15 + c)*8 |
| score     | 1840   | —      | 1     | f32 |
| lives     | 1844   | —      | 1     | f32 |
| level     | 1848   | —      | 1     | i32 |
| tilesLeft | 1852   | —      | 1     | i32 |

`hp` of 0 means empty and a negative `hp` means indestructible. Tile kinds are
0 plain, 1 tough, 2 bomb, 3 solid; power-up kinds are 0 WIDE, 1 MULTI, 2 SLOW,
3 STICKY.

**If you change this layout in `game.wat`, change the constants at the top of
`grid-breaker.js` with it.** Nothing links the two at build time.

## The one hard problem: tunnelling

A ball moving fast enough covers more than a tile's height in a single frame,
and a naive `position += velocity * dt` walks it straight through the wall
without ever testing the cell it crossed. Every brick-breaker has to solve this.

`$step_ball` splits each frame into sub-steps short enough that the ball can
never advance more than 5px at a time, and moves **one axis at a time** within
each sub-step, so the axis that hit something is the axis that reverses — which
is also what makes a ball clip the side of a tile and continue along it rather
than bouncing back the way it came.

The sub-step count is capped at 12 so a stalled frame cannot make the engine do
unbounded work. That cap is never reached in play: at the engine's speed cap of
620px/s and the widget's `dt` clamp of 0.05s, a frame is at most 31px of travel,
which is 7 sub-steps.

Verified with a headless harness driving the compiled binary: a ball fired into
an intact wall at 430, 620, 900 and 1500 px/s — the last being 2.4x the engine's
own cap — breaks a tile and never crosses the wall, at frame times of 1/60,
1/30 and 0.05s. The same harness confirms a 3x3 block of bombs chain-clears
completely and terminates, that solid tiles bounce without breaking, and that
across 40 generated levels `tilesLeft` never disagrees with the grid.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$BALL_SPEED_BASE` | ball speed at level 1 | 430 |
| `$BALL_SPEED_STEP` / `$BALL_SPEED_CAP` | per-level increase, ceiling | 14 / 620 |
| `$PADDLE_HALF_BASE` | half-width at level 1 (floor is 44) | 70 |
| `$MAX_DEFLECT` | how far the paddle's edge throws the ball, in radians | 1.05 |
| `$MIN_DEFLECT` / `$MIN_DEFLECT_HI` | the band a too-vertical return is pushed into | 0.15 / 0.45 |
| `$DROP_CHANCE` | chance a broken tile drops a capsule | 0.16 |
| `$START_LIVES` | starting lives | 5 |

Two findings from benching, both commented in place:

1. **Speed is set against the arena, not in the abstract.** At the first-draft
   330px/s a round trip of the 720px arena took about 4 seconds, which made a
   60-tile wall a four-minute level. 430 puts a round trip near 2.7s.
2. **Level 1 is the checkerboard, not the solid block.** Half the tiles, so a
   first-time player reaches a level-up before deciding whether the game is
   worth their time.

### The degenerate state, and the two goes it took to close it

**A ball is never sent vertically — not on the serve, and not off the paddle.**
A ball with `vx == 0` drills a single column, and if the paddle simply tracks
it, it stays vertical for the rest of the run.

The serve was guarded first: a launch angle within 0.15 rad of vertical is
nudged to a random 0.22–0.5 rad instead. That closed one door and left the
other open, because a *bounce* recomputes the angle from where the ball landed
on the paddle, and a paddle that keeps the ball on its centre computes zero
every time. The headless pilot centres perfectly, so it walked straight into
it: **level 2, one tile left, 153 seconds with nothing happening.** No agency,
no threat, no progress — the dead-time case, arrived at from the other side.

The first fix was a fixed floor of 0.15 rad, and it made things *worse* — 645
seconds, because a constant angle off a perfectly-tracking paddle is a
perfectly periodic orbit. The ball rang between the left wall and the same four
pixels of paddle for eleven minutes. What ships is a **band**: the magnitude is
drawn from 0.15–0.45 rad, which cannot resonate, while the *sign* still comes
from where the ball landed, so the paddle reads as slightly curved rather than
as disobeying.

Measured over the same 900-second bench with the perfect-tracking pilot:

| paddle-bounce floor | level reached | worst stall |
|---|---|---|
| none (as shipped before) | 2 | 153s |
| fixed 0.15 rad | 2 | 645s |
| band 0.15–0.33 | 7 | 54s |
| **band 0.15–0.45** | **7** | **35s** |
| band 0.15–0.60 | 7 | 63s |

What is left at 0.45 is not a lock — it is the last-two-tiles hunt every game
of this shape has, and MULTI is the answer the player already has for it.

## Rebuilding the engine

```bash
npm install                    # wabt is a devDependency of this repo
npm run build:grid-breaker     # game.wat -> game.wasm, re-embedded into the .js
npm run check                  # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `grid-breaker.js` are both committed, so
a fresh checkout plays with nothing installed — which is exactly the arrangement
that lets a binary drift away from the `.wat` it claims to be built from.
`npm run check` recompiles into memory and fails if either committed copy
disagrees with the source. It covers every title, so run it before pushing an
engine change.

## Browser support

Any browser with WebAssembly. No build step, no dependencies, and no network
requests at runtime — the engine ships inside the JS file.
