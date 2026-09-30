# Asteroid Miner

A mining run in a wrap-around rock field. Shoot a boulder and it breaks into
chunks; shoot the chunks and they break into pebbles; shoot a pebble and it
pays out in gems. Fill the hold, fly it back to the depot, and do it again
before the tank runs dry; spend what you banked there on a bigger hold, a bigger
tank or a ship back. All of it — the ship, the splitting, the fuel, the
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
game.getState();   // { score, lives, level, fuel, cargo, delivered, quota, credit, gameOver, paused, difficulty }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |
| `difficulty` | `'easy'`, `'normal'` (the default) or `'hard'` for the first run; the HUD button changes it after that |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop            | Mobile                 |
|---------|--------------------|------------------------|
| Turn    | ← / → or A / D     | left stick — it aims   |
| Thrust  | ↑ or W             | round **THR** button   |
| Mine    | Space              | round **FIRE** button  |
| Refit, docked | 1 / 2 / 3, or click an item | tap an item |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |
| Pause   | P or Esc; losing focus too | the PAUSE button; tap the arena to resume |
| Restart | R                  | tap the GAME OVER text |
| Mute    | M                  | the SOUND button       |

**Gamepad**, standard mapping, no setup: left stick or d-pad turns, `A` / right
trigger / d-pad up thrusts, `X` / left trigger / `B` mines, `Start` pauses,
`Back` or `Y` restarts, a shoulder button mutes. Docked, the d-pad's down
picks a refit item and `Y` buys it instead of restarting; `Back` still restarts
there. Thrust and mine each have a
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
- **Power-ups fall out of mined pebbles**, about one in seventeen. **MAGNET**
  (red horseshoe, 12 s) pulls every gem and fuel cell within 190 px toward the
  ship. **DRILL** (brass bit, 10 s) mines a rock out whole: a shot pays every
  pebble the rock would have become and leaves nothing behind. Both show in the
  HUD with their seconds, and both are lost with the ship. See
  [Power-ups](#power-ups-september-2026).
- **Every gem the depot takes is also banked**, and the bank is spent while
  docked: a bigger hold, a bigger tank, or a ship back. Gems still in the hold
  when a level's quota is met are banked too, not lost. See
  [The depot's refit](#the-depots-refit-october-2026).
- **Every third level a rival miner warps in**, on the far side of the field
  from the depot. It cuts rocks and picks up loose gems into its own hold of
  ten, and cannot hurt you. Shoot it and its whole hold spills where it is;
  three hits drive it off (150). If it fills its hold it gets away, and the
  level's quota rises by 5. See [The rival](#the-rival-october-2026).

### Scoring

| event | points |
|---|---|
| splitting a boulder or chunk | 5 |
| destroying a pebble | 15 |
| gem delivered at the depot | 25 |
| level cleared | 200 + fuel remaining |
| power-up picked up | 50 |

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
| rival   | 2784   | —      | 1     | x, y, vx, vy, active, cargo, stun, drill, tx, ty |

**Total: 2,824 bytes.** The rival's `active` is 1 working and 2 warping out;
`drill` is how far into cutting the rock at (`tx`, `ty`) it is. Rock `size` is 3 boulder, 2 chunk, 1 pebble; pickup
`kind` is 0 gem, 1 fuel cell, 2 magnet, 3 drill. Scalars — score, lives, fuel, cargo, the quota —
live in globals rather than memory, as in
[Worm Chase](../worm-chase/game.wat): the `get_*` readers are the only
consumer, and a global is one instruction to read.

**If you change this layout in `game.wat`, change the constants at the top of
`asteroid-miner.js` with it.** Nothing links the two at build time.

### Exports

`init`, `set_input(rot, thrust, fire, aimOn, aimAng, buy)`, `step(dt)`,
`rocks_alive`, `memory`, and the readers: `get_score`, `get_lives`,
`get_level`, `get_fuel`, `get_fuel_max`, `get_cargo`, `get_cargo_max`,
`get_delivered`, `get_quota`, `get_heading`, `get_thrusting`, `get_invuln`,
`get_depot_x`, `get_depot_y`, `get_depot_r`, `is_game_over`, and the event
counters `get_shots`, `get_hits`, `get_grabs`, `get_fuels`, `get_drops`,
`get_deaths`, `get_power_drops`, `get_powers`; and for the power-ups,
`get_magnet` and `get_drill` (seconds left) and `get_magnet_r` (its reach,
so the ring is drawn where the rule is); and for the refit, `get_credit`,
`get_docked`, `get_hold_tier`, `get_tank_tier`, `get_refit_cost(item)` (the
price now, or -1 when it cannot be bought), `get_refit_next(item)` (what the
hold or tank would become) and the counter `get_refits`. `buy` is 0, or 1 / 2
/ 3 for hold / tank / ship, sent for one frame per press. For the rival:
`get_rival_hp`, `get_rival_cap`, `get_rival_drill` (seconds to cut a rock, so
the beam fills at the engine's rate) and the counters `get_rivals`,
`get_rival_hits`, `get_rival_takes`, `get_rival_routs` and
`get_rival_escapes`.

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
about. Twenty-eight slots is enough that on Easy and Normal it never happened
in the bench: ten boulders splitting all the way down is 10 + 20 + 40, but
pebbles are destroyed rather than split and the field is topped up to a target
count rather than a maximum. Hard's twelve boulders do fill it now and then,
from level 8 up: see [Above level 4](#above-level-4).

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
| `$POWER_CHANCE` | chance a mined pebble drops a power-up | 0.06 |
| `$MAGNET_TIME` / `$MAGNET_R` / `$MAGNET_PULL` | the magnet: seconds, reach, pull | 12 s / 190 px / 240 px/s |
| `$DRILL_TIME` | the drill: seconds | 10 s |
| `$RESERVE_RATE` / `$RESERVE_CAP` | the emergency trickle and its ceiling | 3 / 14 |
| `$CARGO_MAX` / `$DELIVER_EVERY` | hold size, and seconds per gem unloaded | 12 / 0.11 |
| `$DEPOT_R` | docking radius | 52 |
| `$START_LIVES` / `$INVULN_TIME` | ships, and blinking invulnerability after a respawn | 4 / 2.2 |

Seven of those — the lives, the burn rate, the cell, the rock speed and its
ramp, and the two numbers behind the field size — are the **Normal** column of
the difficulty table rather than fixed constants. See below.

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

## Difficulty, September 2026

Three settings, picked with the HUD button or
`mount(el, { difficulty: 'hard' })`. The table lives in the engine:
`set_difficulty(d)` records the choice (0 easy, 1 normal, 2 hard) and `init()`
applies it, so a setting never changes halfway through a run.

| | Easy | Normal | Hard |
|---|---|---|---|
| Starting ships | 5 | 4 | 3 |
| Fuel burn, per second of thrust | 6.5 | 8.5 | 10.5 |
| ... so a full tank is | 15.4 s | 11.8 s | 9.5 s |
| A fuel cell is worth | 28 | 22 | 18 |
| Boulders on the field | 2, +1 a level, cap 8 | 3, +1, cap 10 | 4, +1, cap 12 |
| Gems a level asks for | 4, +2 a level | 6, +3 | 8, +4 |
| Rock speed | 22, +3 a level | 26, +4 | 31, +5 |

The three knobs the backlog named were **fuel burn, rock density and the
quota**, and those are the spine of it. Two more came with them because they
are the same knob wearing another coat. **Rock speed** travels with density: more
rocks at the same crawl reads as clutter rather than as pressure, and a field
that is merely busier is the "a harder wave is not a longer wave" mistake in
another shape. **A fuel cell's worth** travels with the burn rate: the burn rate
alone decides how long a tank lasts, but the cell is what decides whether the
field can pay for it, and moving one without the other makes Hard a game about
docking rather than about mining.

**Three things are deliberately not in the table.** `$ROT_SPEED` and `$DRAG` are
the feel of the ship rather than the challenge — a barge on Easy would be a
different game to learn on rather than an easier one. And `$RESERVE_RATE` /
`$RESERVE_CAP` stay put on every setting: the reserve is what stops a dry tank
being 75 seconds of drifting with nothing to do, and that is a dead-time bug,
not a difficulty. Making Hard "harder" by letting it come back would be
reintroducing the bug and calling it a setting.

**Normal is the previous balance exactly.** The same input replayed through the
committed engine and this one gave byte-identical results on every frame — all
2,784 bytes of the simulated region, plus all eighteen readers — over 36,000
frames, with a fresh `init()` on each game over so the comparison covered
restarts and level builds as well as one long run.

Benched with a pilot that plays badly: it points at the nearest rock, or at the
depot once the hold is full, thrusts in random bursts whatever the fuel gauge
says, fires constantly, and never dodges anything. 24 runs each, capped at ten
minutes (no run reached the cap):

| | Survived: worst / median / best | Mean | Level (median / best) | Gems (median) | Rocks shot (median) |
|---|---|---|---|---|---|
| Easy | 80 / 175 / 335 s | 193.6 s | 3 / 4 | 10 | 82 |
| Normal | 66 / 148 / 362 s | 164.3 s | 2 / 4 | 6 | 63 |
| Hard | 12 / 81 / 144 s | 71.7 s | 1 / 2 | 3 | 48 |

That bad pilot reaches **level 3 in 15 of 24 Easy runs**, which is the bar
CLAUDE.md sets for a gentle opening. It clears it in only 5 of 24 on Normal —
worth knowing, but that is the balance this engine already shipped with rather
than anything the table changed, and Normal is byte-identical to it. On Hard it
never reaches level 3, which is the point of Hard.

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and Easy and Hard get `asteroid-miner:easy` and `asteroid-miner:hard`.

### Above level 4

That pilot never passes level 4, and the density caps (8 / 10 / 12 boulders)
are reached at levels 7, 8 and 9. So the field after density stops growing, when
only rock speed and the quota still climb, was benched separately. The pilot is
a competent one. It leads its shots, plans its dodges (it simulates eight escape
headings and coasting for a second against every rock, and takes the one with
the most clearance), goes home when the hold is full, the quota is covered or
fuel is under 28, and sees everything 200 ms late. It runs on engine builds
that start at level *L* with a full set of ships. 24 runs per cell, 10-minute
cap:

| Level cleared, of 24 | 4 | 6 | 8 | 10 | 12 | 14 | 16 |
|---|---|---|---|---|---|---|---|
| Easy | 24 | 21 | 21 | 15 | 11 | 6 | 4 |
| Normal | 20 | 13 | 8 | 6 | 3 | 1 | 0 |
| Hard | 13 | 4 | 2 | 0 | 0 | 0 | 0 |

From level 1 with the usual ships, the same pilot reaches a median of level
**6 / 5 / 3** in fifteen minutes (best 8 / 7 / 5).

**The curve does not flatten at the cap.** Nothing changes shape at levels 7,
8 or 9. Past them, speed and the quota alone keep the clear rate falling at about
the rate density did, so the game carries on getting harder with no cliff and no
plateau. Median ships lost per level rises until it meets the setting's
supply, and clears that succeed take longer: 68 s at level 4 on Normal, 140 s
at level 12.

**Fuel never binds for a pilot that goes home at a quarter tank**: 0.0% of
frames dry at every level and setting. What ends runs up there is rocks.

**Two things it found:**

- **The pool does fill, on Hard.** The section on splitting below says
  twenty-eight slots is enough that a full pool "effectively never happens".
  That holds on Easy and Normal (0.0% of frames at every level measured). On
  Hard, from level 8, the pool is full **0.3% of frames at level 8, 0.7% at
  10 and 2.5% at 16**, and a split during those frames drops its children, as
  designed. It is rare, and the failure is the right one: the player sees a
  rock vanish and loses a few gems.
- **Hard's density cap sits beyond where this pilot plays.** Hard reaches 12
  boulders at level 9, and the pilot clears level 8 in 2 of 24 runs and level
  10 in none. CLAUDE.md warns that a ceiling the player never reaches is not a
  difficulty curve. This one is not doing harm, since the curve below it is
  real, but a lower cap on Hard would change nothing anyone plays.

## Power-ups, September 2026

The power-up idea from the menu of features for the other eight titles, as the
menu put it: *a magnet or a bigger drill to carry home*. There are both. Both
are about the trip rather than the fight, because the trip is what this game is
made of.

- **MAGNET**, 12 seconds: every gem and fuel cell within 190 px is pulled
  straight toward the ship at 240 px/s. Chasing loot across a drifting field is
  where fuel goes, and where a ship with a nearly full hold meets the rock it
  did not see. A dotted ring shows the reach, at the radius the engine checks,
  and blinks through its last two seconds. It steers loot, not power-ups:
  picking one of those up is still a decision.
- **DRILL**, 10 seconds, the "bigger drill": a shot mines a rock out whole. It
  pays every pebble the rock would have become — four for a boulder, two for a
  chunk — and leaves no fragments drifting toward you. Same yield as shooting
  it down the long way, a quarter of the shots, and a field that empties
  instead of filling up. Drill rounds are brass and white, so a shot that will
  mine a rock out whole does not look like one that will only crack it.

They fall from mined pebbles, the moment the game already pays out at, with a 6%
chance each, as a capsule that drifts like a gem and times out like one. The
roll, which of the two it is, and how it drifts all come from a random stream
of their own, as Pixel Wave's, Worm Chase's and Sector Defense's do. A
power-up that is never picked up changes nothing about the field. Replaying
random flying through the engine before and after, on all three settings, gave
identical ship, rock and bullet memory and fourteen readers on every frame
until the first pickup, over 90,000 frames per setting with 135 capsules
dropped and missed along the way. (The pickup pool itself differs, because an
uncaught capsule holds a slot.) Both run out on death and at a level's start.

### A bug the drill found

**New boulders could appear on top of the ship.** The field is topped up every
3.5 seconds wherever there is room, and `$spawn_drifter` kept new boulders
220 px from the depot but not from the ship. The comment beside it already gave
the reason the depot needed that: a rock that materialises on you kills a ship
that did nothing wrong. It applies to the ship anywhere. On Hard, in a bench of
random flying, **4 of 36 deaths came within 0.6 s of a boulder appearing within
150 px of the ship**. The drill made it worse, because a rock mined out whole
leaves room for a top-up sooner.

New boulders now also keep **140 px** from the ship. 220 was tried first, and
it cost the competent pilot below gems: top-ups landing near the ship were also
the rocks it mined next, and pushing them further out meant more flying for
each. 140 is about a second of a boulder's travel. It keeps every spawn out of
reach and moves nothing else — the per-run level distributions before and after
are the same within noise. **This changes every setting, so Normal is no longer
byte-identical to the engine that shipped before difficulty settings**, which
the Difficulty section above says of it; the fix is the one deliberate
difference.

### What the bench found

The competent pilot from "Above level 4" and a bad one (points at the nearest
rock or the depot, thrusts in random bursts, fires constantly, never dodges),
from level 1, on the engine with the spawn fix, with power-ups and without.
Neither pilot does anything special with them: a capsule is just another pickup
to fly to. Mean level reached:

| | Without | With power-ups | Median time to clear a level |
|---|---|---|---|
| Normal, bad pilot (24 runs) | 3.4 | 3.8 | 51 s → 44 s |
| Normal, competent (24 runs) | 4.2 | 4.6 | 55 s → 48 s |
| Hard, bad pilot (16 runs) | 2.2 | 2.6 | 62 s → 47 s |
| Hard, competent (16 runs) | 2.9 | 3.2 | 63 s → 44 s |

**They make levels faster, and a little further.** About half a level more per
run, and a level cleared seven to twenty seconds sooner, with more gems
delivered. Ships are lost a little more often per *minute* (1.04 → 1.08 a
minute for the competent pilot on Normal) but less often per *level*, because
the levels are shorter. Split apart, the magnet does most of the speeding up —
with only magnets on the field, the competent pilot's median level took 41 s —
and the drill is closer to neutral for pilots that do not change how they
fly.

## The depot's refit, October 2026

The title's own idea from the menu of features for the other eight titles:
*spend cargo at the depot*. Every gem the depot takes still counts toward the
quota and still scores 25, and is now also banked as one credit. Docked, the
bank buys three things:

| item | what it does | price |
|---|---|---|
| **HOLD** | 12 → 16 → 20 gems | 8, then 16 |
| **TANK** | 100 → 135 → 170 fuel | 8, then 16 |
| **SHIP** | one ship back, only when one has been lost | 12, then 8 more for each one bought |

The menu appears under the DOCKED note whenever the ship is on the pad, with
every price read from the engine (`get_refit_cost`), so a price on screen is
always the price charged. Refits last the whole run, through deaths, and
only a new run takes them back. Gems still in the hold when the quota is met,
which the next level's reset used to wipe, are banked as well.

**The design that did not survive.** The first version paid for a refit out of
the level's *quota* instead of a separate bank, so an upgrade cost you trips.
It read well and failed on the drip at the depot: a ship docking with more
gems than the quota still wanted finished the level in under a second, before
anyone could press a key. Spending on level 1 meant coming home with a
half-empty hold on purpose. A separate bank can be spent on any visit,
including the one a respawn starts at.

### What the bench found

Measured on the engine before the rival below was added; the rival arrives
on level 3, so these runs differ from today's from there on.

The competent and bad pilots from the power-up bench, from level 1, 15-minute
cap, 12 seeds, with the hold and tank thresholds read from the engine so a
bigger hold is actually filled. Each pilot buys by a fixed policy whenever it
is docked: **none**, **ship** (a ship whenever one is missing and affordable),
**kit** (hold and tank only) or **greedy** (ship first, then hold, then tank).
Mean level reached:

| | none | kit | ship | greedy |
|---|---|---|---|---|
| Easy, bad pilot | 5.5 | 4.9 | 6.8 | 5.8 |
| Easy, competent | 6.5 | 6.5 | 7.9 | 7.0 |
| Normal, bad pilot | 3.8 | 3.8 | 5.1 | 4.7 |
| Normal, competent | 4.0 | 3.8 | 5.1 | 4.1 |
| Hard, bad pilot | 2.7 | 2.8 | 3.0 | 3.2 |
| Hard, competent | 3.4 | 3.3 | 3.8 | 3.4 |

With no purchases the engine reaches the same level with the same score as the
one without a refit on every seed benched, because the bank changes nothing
until it is spent.

**The first ship price was far too low.** At a flat 12, the ship-only policy
took the bad pilot on Easy from level 5.5 to 10.2 and nearly tripled how long
it lived: lives are what ends a run here, and 12 gems is about one level's
delivery by level 3. Making each ship 8 dearer than the last brought it to the
+1 level above. 16 more each was tried too; it moved only the bad pilot, by
0.2-0.5 of a level, and put the third ship (44 gems) out of any pilot's reach,
so the smaller step was kept.

**The hold and tank buy time, not distance.** For these pilots, kit is flat
on how far a run goes and makes levels quicker: the competent pilot's median
level on Normal fell from 45 s to 39 s. A bigger hold means fewer trips, and
also more cargo on board when a rock arrives, which is spilled where you die.
The tank almost never binds, because both pilots head home at a quarter full.
So on these numbers **a ship is the better buy for anyone who is losing
ships**, and the kit is for a player who is not. That was left as it is
rather than priced into a tie: it is a real answer, it changes as the run goes
on, and a player who flies well enough to keep their ships has a reason to buy
the other two.

**What the bench cannot tell you** is whether a person reads the menu as a
shop or as clutter on the one screen where they are safe. It is open only
while docked, which is also when the hold is unloading and the tank is
filling, so the decision costs no time. It is still something to read.

## The rival, October 2026

The boss column of the menu of features for the other eight titles had this
title as a maybe: *a rival miner working the same rocks* fitted it better than
a boss with a health bar. This is that rival, and it is deliberately not a
threat to the ship. It cannot ram you and never fires at you. It competes for
the one thing the level asks for.

- **When.** Every third level (3, 6, 9 …), 5 seconds in. It warps in on the
  far side of the field from the depot, the depot's position plus half the
  field each way, so nothing about where it arrives is random.
- **What it does.** Goes for the nearest loose gem within 360px. Failing
  that, it closes on the nearest rock, holds station beside it matching its
  drift, and cuts it in 1.1 s with a beam you can see filling. A boulder or
  chunk it cuts splits as a shot one does. A pebble it cuts goes **straight
  into its hold** as the gems a pebble pays, and nothing lands on the field.
  Nothing it mines scores for you. It is slower than you (150 px/s against
  your 300) and passes through rocks.
- **Its hold is ten**, shown as pips over it. Fill it and it warps out with
  the lot, and **the level's quota rises by 5**: it filed its claim first.
- **Shoot it and the whole hold spills** where it is, as loose gems, and it
  is stunned, drifting, for 2.5 s; a stunned rival cannot be struck again, so
  one burst is one spill. The third hit drives it off for good, for 150.

The decision is **when to shoot it**. Early, and there is little to spill.
Late, and it has done the mining for you, unless it fills up and leaves
first. A rival still working when the level ends leaves with the level.

**The version that did not work.** The first rival's cut pebbles paid out
onto the field like any split, and the bench showed what that made it: a rival
level came out *faster* than the same level without one, because it was
mining for the player. Its gems now go into its hold, so its haul is yours
only if you shoot it.

### What the bench found

The two pilots from the power-up bench, 16 seeds a setting, from level 1 with
a 15-minute cap: on the engine without a rival; on this one, flying as before
(the rival is just in the way); and on this one with a **hunter** rule, which
leads and shoots the rival whenever it holds five or more gems and is within
380px. Mean level reached, and the median time of level 3, the first rival
level:

| | no rival | rival, ignored | rival, **hunted** | escaped / driven off (ignored) |
|---|---|---|---|---|
| Easy, bad pilot | 5.50 · 38 s | 5.56 · 42 s | 5.44 · 36 s | 7 / 7 of 23 |
| Easy, competent | 6.31 · 36 s | 6.31 · 28 s | 6.31 · 25 s | 4 / 17 of 30 |
| Normal, bad pilot | 3.94 · 38 s | 3.81 · 52 s | 3.63 · 35 s | 4 / 4 of 15 |
| Normal, competent | 4.38 · 63 s | 4.25 · 46 s | 4.63 · 49 s | 1 / 13 of 16 |
| Hard, bad pilot | 2.50 · 73 s | 2.50 · 58 s | 2.50 · 80 s | 1 / 1 of 5 |
| Hard, competent | 3.38 · 61 s | 3.38 · 70 s | 3.31 · 71 s | 0 / 7 of 10 |

**It moves the curve by less than the bench can see, and that was kept.**
Every level mean is within 0.3 of the engine without it, and level 3's time
swings both ways by up to 17 s, which is the spread of a dozen runs rather
than anything the rival does. The reason is in the last column. **These
pilots drive it off far more often than it gets away**, mostly without
meaning to: it works the same rocks they do, so fire aimed at a rock beside it
finds it. The competent pilot, which never aims at it, drove it off 13 times
in 16 on Normal. The hunter spills its hold on purpose. On Normal that was
worth about a third of a level over ignoring it to the competent pilot, and
cost the bad one a little, since chasing the rival is time not spent mining.

So it lands where Sector Defense's shield module did: a real choice with no
dominant answer, which did not need the difficulty table re-tuned. The claim
is what makes letting it go a cost. Without it, benched first, a full rival
simply left, and the only thing ignoring it lost was its haul.

**What the bench cannot tell you** is whether a person reads it as a race or
as theft. A rival that takes gems from a field the player is already short of
could feel like either, and the pips over it are there so the player can see
the race rather than discover it when the quota jumps.

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
