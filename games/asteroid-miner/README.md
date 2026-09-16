# Asteroid Miner

A mining run in a wrap-around rock field. Shoot a boulder and it breaks into
chunks; shoot the chunks and they break into pebbles; shoot a pebble and it
pays out in gems. Fill the hold, fly it back to the depot, and do it again
before the tank runs dry. All of it — the ship, the splitting, the fuel, the
hold, the depot and the level curve — is hand-written in WebAssembly Text
(`game.wat`) and runs as a compiled `.wasm` binary. JavaScript forwards input,
calls `step(dt)`, and draws what it finds in the engine's linear memory.

Works on **desktop (keyboard)** and **mobile (aiming stick, round THR and FIRE
buttons)**.

Open [`index.html`](index.html) to play it.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.am-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, entity pools at fixed offsets, an xorshift RNG, and an `init` /
`set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` can verify all five committed binaries in one pass.

## Files

```
asteroid-miner/
├── asteroid-miner.js   ← the widget (engine embedded inside) — REQUIRED
├── asteroid-miner.css  ← scoped styles (.am-*)               — REQUIRED
├── game.wat            ← engine SOURCE — edit to change gameplay
├── game.wasm           ← compiled engine (also embedded in the .js as base64)
├── index.html          ← standalone page: the game and nothing else
├── demo.html           ← minimal working integration example
├── logo.svg            ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`asteroid-miner.js` and `asteroid-miner.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="asteroid-miner.css">

<div id="game"></div>

<script src="asteroid-miner.js"></script>
<script>
  var game = AsteroidMiner.mount('#game');
</script>
```

### JavaScript API

```js
var game = AsteroidMiner.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, lives, level, fuel, cargo, delivered, quota, gameOver, paused }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop            | Mobile                 |
|---------|--------------------|------------------------|
| Turn    | ← / → or A / D     | left stick — it aims   |
| Thrust  | ↑ or W             | round **THR** button   |
| Mine    | Space              | round **FIRE** button  |
| Pause   | P or Esc; losing focus too | the PAUSE button; tap the arena to resume |
| Restart | R                  | tap the GAME OVER text |
| Mute    | M                  | the SOUND button       |

**Gamepad**, standard mapping, no setup: left stick or d-pad turns, `A` / right
trigger / d-pad up thrusts, `X` / left trigger / `B` mines, `Start` pauses,
`Back` or `Y` restarts, a shoulder button mutes. Thrust and mine each have a
face button *and* a trigger, so a pad with worn triggers still plays. It is
polled once a frame rather than listened for, because `getGamepads()` only
refreshes its snapshots when called.

Pause is the widget's, not the engine's: the engine advances by whatever `dt` it
is handed, so pausing is the loop not calling `step` while it goes on drawing
the frozen frame. See [chapter 15](../../docs/15-game-loop-architecture.md).

### The stick names a heading; the keys name a turn rate

Two steering schemes, arbitrated the way Grid Breaker arbitrates mouse against
keys: **whichever spoke last wins**, and they can never both apply. Pressing a
turn key drops the stick's claim; moving the stick overrides the keys.

The keys give the classic rotate-left / rotate-right of the genre. The stick
instead points at *where you want to face*, because a thumb can indicate a
direction far faster than it can hold a rotate button for the right number of
milliseconds. Even so, **the ship still turns toward that heading at
`ROT_SPEED`** rather than snapping to it: the stick is a request, not
teleportation, and a thumb flick and a key press produce the same ship.

The angle convention is the engine's own — 0 is up, and it grows clockwise, so
the widget computes `atan2(dx, -dy)` rather than the usual `atan2(dy, dx)`.

## Gameplay rules

- **Rocks split.** A boulder becomes two chunks, a chunk becomes two pebbles,
  and a pebble becomes cargo — one gem always, a second most of the time, and a
  fuel cell about one pebble in five. The pair from a split always leaves back
  to back, so a split opens a gap to fly through instead of a wall to reverse
  away from.
- **The hold is 12 gems.** A full hold leaves further gems where they are,
  still ticking down. That is the whole reason cargo is a decision: the field
  does not wait for the trip home.
- **Only the depot converts anything into progress.** Docking refuels
  continuously and unloads the hold one gem at a time, about nine a second. The
  depot moves every level, so no single route can be learned and reused.
- **The level asks for round trips, not kills.** Six gems delivered on level 1,
  three more each level. Mining a rock scores, but it does not count.
- **4 ships.** A rock at any size costs one. Cargo is *spilled* where you died
  rather than deleted — the same arithmetic, but it reads as a chance instead
  of the game taking something. You respawn at the depot with a full tank and
  2.2 seconds of blinking invulnerability.
- **Thrust costs fuel and an empty tank is a dead engine.** You can still turn
  and still shoot. See below.
- Every level clear pays 200 plus **whatever fuel is left in the tank**.

### Scoring

| event | points |
|---|---|
| splitting a boulder or chunk | 5 |
| destroying a pebble | 15 |
| gem delivered at the depot | 25 |
| level cleared | 200 + fuel remaining |

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ asteroid-miner.js (JavaScript)                       │
│   • builds DOM, reads keyboard and touch input       │
│   • arbitrates stick against keys, then calls:       │
│       set_input(rot, thrust, fire, aimOn, aimAng)    │
│       → step(dt)                                     │
│   • reads the ship, rock, bullet and pickup records  │
│     straight out of wasm linear memory and draws them│
│   • draws into a 320x240 buffer, blown up 3x         │
│   • particles, shake and sound are presentation only │
│     — triggered by diffing the engine's counters     │
└───────────────▲──────────────────────────────────────┘
                │ exports: init, set_input, step, rocks_alive,
                │ the get_* readers below, and memory
┌───────────────┴──────────────────────────────────────┐
│ game.wasm (compiled from hand-written game.wat)      │
│   • ship physics: thrust, drag, speed cap, wrapping  │
│   • bullet pool with wrapped collision against rocks │
│   • rock splitting, and the pebble payout            │
│   • pickups: gems, fuel cells, lifetimes, collection │
│   • fuel and cargo state, docking, the quota         │
│   • field top-up, level generation, score/lives      │
└──────────────────────────────────────────────────────┘
```

### WASM linear memory layout

| region  | offset | stride | count | fields |
|---------|--------|--------|-------|--------|
| ship    | 0      | —      | 1     | x, y, vx, vy, heading, alive |
| rocks   | 24     | 32 B   | 28    | x, y, vx, vy, radius, size, active, spin |
| bullets | 920    | 24 B   | 24    | x, y, vx, vy, life, active |
| pickups | 1496   | 32 B   | 40    | x, y, vx, vy, life, kind, active, phase |
| depot   | 2776   | —      | 1     | x, y |

**Total: 2,784 bytes.** Rock `size` is 3 boulder, 2 chunk, 1 pebble; pickup
`kind` is 0 gem, 1 fuel cell. Scalars — score, lives, fuel, cargo, the quota —
live in globals rather than memory, as in
[Worm Chase](../worm-chase/game.wat): the `get_*` readers are the only
consumer, and a global is one instruction to read.

**If you change this layout in `game.wat`, change the constants at the top of
`asteroid-miner.js` with it.** Nothing links the two at build time.

### Exports

`init`, `set_input(rot, thrust, fire, aimOn, aimAng)`, `step(dt)`,
`rocks_alive`, `memory`, and the readers: `get_score`, `get_lives`,
`get_level`, `get_fuel`, `get_fuel_max`, `get_cargo`, `get_cargo_max`,
`get_delivered`, `get_quota`, `get_heading`, `get_thrusting`, `get_invuln`,
`get_depot_x`, `get_depot_y`, `get_depot_r`, `is_game_over`, and the event
counters `get_shots`, `get_hits`, `get_grabs`, `get_fuels`, `get_drops`,
`get_deaths`.

The counters are how the engine reports events without calling out: JavaScript
diffs them between frames to decide what to play and what to shake. They only
ever increase.

## The graphics are old on purpose

The field is drawn into a **320×240 buffer and blown up 3× with smoothing off**.
That single decision is what makes it read as an old game rather than a modern
game with pixel-art sprites in it: every mark rasterises at the low resolution,
so a rotated rock, the depot's rings, a particle and the exhaust flame are all
made of the same chunky pixels the sprites are, and a rotation lands on the
pixel grid instead of gliding smoothly over it.

The draw code still works in 960×720 world units. A `1/3` transform on the
buffer's context is what makes that free — not one coordinate in the renderer
had to change.

Three smaller rules follow from the same idea:

- **No glow anywhere.** A blur is the giveaway that a picture was made after
  about 1995. Brightness on this hardware came from picking a brighter colour,
  so a bullet is a dark-amber block with a pale core rather than a soft light.
- **Everything lands on whole pixels.** Stars, bullets and particles are
  snapped to the low-res grid, and screen shake moves in whole low-res pixels —
  a sub-pixel shake would resample the entire field every frame and undo the
  point of the buffer.
- **Scanlines and a vignette**, in CSS rather than in the frame loop. They never
  change, so drawing them per frame would be 240 fill calls a frame for the same
  picture — and in CSS they sit at true display resolution, which is where
  scanlines have to be to look like scanlines. Both are dropped under
  `prefers-reduced-motion`.

## The two problems worth reading about

### Entities that spawn entities

Splitting is the mechanic, and it is the one thing an entity pool
([chapter 16](../../docs/16-entity-pools.md)) is not obviously shaped for: a
rock's destruction *creates* rocks, while the loop that destroyed it is still
walking the same array.

Nothing recurses. `$split_rock` deactivates the parent and calls `$spawn_rock`
twice, which does what spawning always does — scans for a slot whose `active`
is zero and writes into it. The children are ordinary records. Whether this
frame's loop happens to reach them is irrelevant, because they are drifting
rocks either way and the next frame treats them like any other.

**A full pool silently drops the children.** That is the correct failure, and
it is worth being explicit about: the alternative is refusing to destroy the
parent, which would make a crowded field unshootable — the player would be
punished for the pool being full, which is not a thing they can see or reason
about. Twenty-eight slots is enough that it effectively never happens: ten
boulders splitting all the way down is 10 + 20 + 40, but pebbles are destroyed
rather than split and the field is topped up to a target count rather than a
maximum.

### Running out of fuel

The first build had a real soft-lock in it, and the headless bench found it by
accident: with a dry tank far from the depot, the ship drifts to a stop and
there is nothing to do. The bench measured **75 seconds** before a drifting rock
happened to hit it.

Three things fix it, in order of how often they matter:

1. **Pebbles drop fuel cells**, about one in five, so the field itself is a fuel
   supply and mining your way home is a real option.
2. **An emergency reserve** trickles the tank back to a sliver — 3 units a
   second up to 14, about 1.6 seconds of thrust followed by a five-second wait
   for the next sip. Running dry is meant to be a crawl home, not a dead run.
3. **Ramming a rock is always an exit.** A death respawns you at the depot with
   a full tank, so the worst case is a deliberate, expensive scuttle rather than
   a stuck game.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$ROT_SPEED` | turn rate, **radians per second** — a rate, not an acceleration | 3.4 |
| `$THRUST_ACC` / `$MAX_SPEED` / `$DRAG` | engine power, speed ceiling, how fast you coast to a stop | 270 / 300 / 0.42 |
| `$FUEL_MAX` / `$FUEL_BURN` | tank size, and burn per second of thrust (≈11.8s of continuous thrust) | 100 / 8.5 |
| `$REFUEL_RATE` / `$FUEL_CELL` | refuel per second while docked, and per cell collected | 38 / 22 |
| `$RESERVE_RATE` / `$RESERVE_CAP` | the emergency trickle and its ceiling | 3 / 14 |
| `$CARGO_MAX` / `$DELIVER_EVERY` | hold size, and seconds per gem unloaded | 12 / 0.11 |
| `$DEPOT_R` | docking radius | 52 |
| `$START_LIVES` / `$INVULN_TIME` | ships, and blinking invulnerability after a respawn | 4 / 2.2 |

The level curve is keyed on the level number and clamped:

| per level | level 1 | growth | ceiling |
|---|---|---|---|
| gems to deliver | 6 | +3 | — |
| boulders on the field | 3 | +1 | 10 |
| rock speed | 26 | +4 | — |

A headless pilot driving the compiled binary — greedy, with no route planning
and no rock avoidance on the way home — reaches **level 4 in about 110 seconds**
across 27 deliveries and 4 deaths. Level 1 is deliberately quiet: three slow
boulders, one full tank, and six gems to fetch.

## Rebuilding the engine

```bash
npm install                     # wabt is a devDependency of this repo
npm run build:asteroid-miner    # game.wat -> game.wasm, re-embedded into the .js
npm run check                   # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `asteroid-miner.js` are both committed,
so a fresh checkout plays with nothing installed — which is exactly the
arrangement that lets a binary drift away from the `.wat` it claims to be built
from. `npm run check` recompiles into memory and fails if either committed copy
disagrees with the source. It covers every title, so run it before pushing an
engine change.

## Browser support

Any browser with WebAssembly. No build step, no dependencies, and no network
requests at runtime — the engine ships inside the JS file.
