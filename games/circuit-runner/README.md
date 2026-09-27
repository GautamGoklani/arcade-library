# Circuit Runner

A charge carrier running six copper traces down a circuit board that will not
stop speeding up. Components slide toward you and you change trace to get
around them; current drains the whole time and the only way to refill it is to
go and collect some. All of it — the board generator, the components, the
economy — is hand-written in WebAssembly Text (`game.wat`) and runs as a
compiled `.wasm` binary. JavaScript forwards one number, calls `step(dt)`, and
draws what it finds in the engine's linear memory.

Works on **desktop (arrow keys)** and **mobile (tap a side of the board)**.

Open [`index.html`](index.html) to play it.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.cr-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, entity pools at fixed offsets, an xorshift RNG, and an `init` /
`set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` verifies all nine committed binaries in one pass.

At **2,967 bytes** this is the smallest engine in the library, which is what
happens when a game has one verb.

### It has no imports

Like [Worm Chase](../worm-chase/) and [Sector Defense](../sector-defense/):

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

The board scrolls on one axis, the runner slides along another, and every
collision is an axis-aligned box test. There is no angle in the engine and no
`sqrt`, so there is nothing to ask JavaScript for.

## Files

```
circuit-runner/
├── circuit-runner.js   ← the widget (engine embedded inside) — REQUIRED
├── circuit-runner.css  ← scoped styles (.cr-*)               — REQUIRED
├── game.wat            ← engine SOURCE — edit to change gameplay
├── game.wasm           ← compiled engine (also embedded in the .js as base64)
├── index.html          ← standalone page: the game and nothing else
├── demo.html           ← minimal working integration example
├── logo.svg            ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`circuit-runner.js` and `circuit-runner.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="circuit-runner.css">

<div id="game"></div>

<script src="circuit-runner.js"></script>
<script>
  var game = CircuitRunner.mount('#game');
</script>
```

### JavaScript API

```js
var game = CircuitRunner.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, distance, current, speed, lane, overclock, gameOver, paused, difficulty }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop        | Mobile                    |
|---------|----------------|---------------------------|
| Change trace | ← / → or A / D | tap the left or right side |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |
| Pause   | P or Esc; losing focus too | the PAUSE button; tap the board to resume |
| Restart | R              | tap the GAME OVER text    |
| Mute    | M              | the SOUND button          |

**Gamepad**, standard mapping, no setup: left stick or d-pad changes trace,
`Start` pauses, `Back` or `Y` restarts, a shoulder button mutes. The pad is
digital here for the same reason the touch controls are tap zones — a lane
change is one press — and it is polled once a frame rather than listened for,
because `getGamepads()` only refreshes its snapshots when called.

Pause is the widget's, not the engine's: the engine advances by whatever `dt` it
is handed, so pausing is the loop not calling `step` while it goes on drawing
the frozen board. See [chapter 15](../../docs/15-game-loop-architecture.md).

**Tap zones rather than a stick**, and this is the one title in the library
where that is the right answer: the input is *discrete*. Every other game here
steers along a continuum, so an analog stick maps onto it directly; a lane
change is one press, and a stick would mean pushing, waiting, and re-centring
for each one. Tapping a side of the board is the whole gesture.

Holding a direction walks trace by trace rather than queueing turns: the engine
refuses a change until the previous slide has finished, so you cannot type
ahead through a row you have not seen yet.

## Gameplay rules

- **There is nothing to shoot.** Every other title here answers a threat by
  removing it. The only verb is which trace you are standing on, and the only
  answers are dodge it, time it, or take it.
- **One meter, and it only goes down.** Current drains continuously and drains
  faster the quicker you are going. Charges refill it; nothing else does. There
  is no regeneration and there are no lives — running out is the single failure
  state, which makes every hit a withdrawal rather than a strike against you.
- **The board speeds up with distance**, from 250 px/s to a cap of 640 a little
  over a minute in. Rows arrive on a *distance* clock, not a wall clock — at a
  fixed time interval a faster board would space components further apart,
  which is exactly backwards.
- **A hit costs 20 current and sparks you** for 0.45s: you cannot steer, and you
  cannot be hit again. The immunity is the important half — without it a wide
  row lands a second hit on a runner it has just frozen.
- **Every row leaves a path, and that path moves by at most one trace.** See
  below; this is a guarantee, not a tendency.

### The four components

| | Component | Behaviour | From |
|---|---|---|---|
| ▬ | **Resistor** | One trace, static | the start |
| ⊪ | **Capacitor** | One trace, lethal only while charged — it flips on its own 1.35s clock | 900m |
| ▮ | **Chip** | Two traces, static | 2 km |
| ▬▬ | **Solder bridge** | Two traces, static | 2 km |

The capacitor is the only one that is a *gate* rather than a wall, and it is
drawn dark and hollow while discharged so that is legible at a glance. Each one
arrives with a random phase, so a row of them is a pattern to read rather than
a wall blinking in unison — and the flip runs on a wall clock rather than a
distance clock, so a faster board gives you fewer flips to read, not slower
ones.

### Pickups

| | | |
|---|---|---|
| **Charge** | +17 current, +40 score | the run's whole economy |
| **Overclock** | double score for 6s | 12% of pickups |

A pickup is placed in an open trace **searched outward from wherever the runner
is standing**, so it is almost always one or two traces away. That is a design
decision, not a convenience — see below.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ circuit-runner.js (JavaScript)                       │
│   • builds DOM, reads keyboard and tap input         │
│   • calls set_input(-1 | 0 | 1) → step(dt)           │
│   • reads the component and pickup records straight  │
│     out of wasm linear memory and draws them         │
│   • draws into a 320x240 buffer, blown up 3x         │
│   • particles, shake and sound are presentation only │
│     — triggered by diffing the engine's counters     │
└───────────────▲──────────────────────────────────────┘
                │ exports: init, set_input, step, the get_*
                │ readers below, and memory
┌───────────────┴──────────────────────────────────────┐
│ game.wasm (compiled from hand-written game.wat)      │
│   • the lane slide, and refusing a queued turn       │
│   • the board generator and its path guarantee       │
│   • component behaviour, including capacitor timing  │
│   • the current economy: drain, charges, hits        │
│   • speed and row spacing as functions of distance   │
└──────────────────────────────────────────────────────┘
```

### WASM linear memory layout

| region  | offset | stride | count | fields |
|---------|--------|--------|-------|--------|
| runner  | 0      | —      | 1     | x, lane, targetLane, stun, alive (padded to 24) |
| parts   | 24     | 32 B   | 24    | x, y, lane, kind, active, span, timer, charged |
| pickups | 792    | 24 B   | 20    | x, y, lane, kind, active, phase |

**Total: 1,272 bytes** — the smallest world in the library. Part kinds are
0 resistor, 1 capacitor, 2 chip, 3 solder bridge; pickup kinds are 0 charge,
1 overclock. `charged` and `timer` are meaningless for anything but a
capacitor. Scalars — score, current, distance — live in globals.

**If you change this layout in `game.wat`, change the constants at the top of
`circuit-runner.js` with it.** `npm run check` verifies the named ones agree,
and that the widget's `FIELD` table puts every field where the `@fields` lines
in `game.wat` say it is.

### Exports

`init`, `set_input(move)`, `step(dt)`, `memory`, and the readers: `get_score`,
`get_current`, `get_current_max`, `get_dist`, `get_speed`, `get_speed_base`,
`get_runner_x`, `get_runner_y`, `get_lane`, `get_lanes`, `get_lane_w`,
`get_stun`, `get_overclock`, `is_game_over`, and the event counters
`get_switches`, `get_hits`, `get_charges`, `get_boosts`, `get_rows`.

`get_lanes` and `get_lane_w` exist so the renderer can draw the board without a
second copy of the lane geometry — the one piece of layout it would otherwise
have to duplicate.

## The graphics

Same treatment as [Asteroid Miner](../asteroid-miner/) and
[Sector Defense](../sector-defense/): a **320×240 buffer blown up 3× with
smoothing off**, no glow anywhere, everything snapped to whole low-res pixels,
and scanlines plus a vignette in CSS at true display resolution — all dropped
under `prefers-reduced-motion`.

One departure: **the components are drawn procedurally rather than from ASCII
sprites.** A part is one or two traces wide and an ASCII grid has one width, so
two hand-drawn variants of the same resistor would be two things to keep
looking alike. The shapes are rectangles with bands, pins and leads, which is
what `fillRect` is for, and everything still lands on the low-res grid, so it
is the same picture either way. The runner and the pickups are fixed-size and
remain sprites.

The solder pads sliding down each trace are the only thing that conveys speed.
The traces themselves are unbroken lines, and an unbroken line scrolling past
looks identical at any speed.

## Three findings from benching

A headless pilot driving the compiled binary — it reacts to the nearest row and
nothing else, which is how a person plays — found all three.

1. **The economy was a countdown, not an economy.** At the first build's drain
   of 5.2/s no run lasted more than thirteen seconds: the meter emptied before
   the board had asked a hard question. Worse, the pilot collected two charges
   out of ten, because a pickup went into a *uniformly random* open trace and
   most were unreachable. That is not a difficult economy, it is a lottery.
   Drain is now 3.4/s and pickups are searched outward from the runner, so a
   charge is almost always one or two traces away and therefore *competes* with
   the safe trace. The interesting rows are the ones where the charge is on the
   far side of a component.

2. **Individually fair rows, collectively impossible sequences.** Rows were
   generated independently. At the speed cap there is time to cross about one
   and a half traces between rows, so two consecutive rows whose gaps are three
   traces apart cannot be threaded by anything — and the bench was taking a hit
   every two seconds while playing correctly. There is now a reserved lane that
   no component may cover and that wanders by at most one trace per row, which
   makes the board passable **by construction** and leaves the difficulty where
   it belongs: reading which trace that is, and deciding what it costs to leave
   it for a charge.

3. **A part was wide enough that passing it hit it.** Components were inset
   16px in a 160px trace, giving a half-width of 64; the runner's half-width is
   22, and a slide between two traces passes 80px from the blocked trace's
   centre. 64 + 22 = 86 > 80, so *sliding past* a component clipped it — which
   meant a free trace two across with a blocked one between was unreachable.
   The inset is now 26, giving 76 and four pixels of margin.

After all three, the same pilot runs for **a little over two minutes**, taking
four or five hits in the first thirty seconds.

*The difficulty bench (September 2026, below) could not reproduce that figure
with any pilot it built. A pilot that reads the board and moves in the same
frame survives indefinitely; one with a human reaction time — 150, 250 or 350ms
— ends a median of 52, 46 or 38 seconds in, taking two or three hits in the
first thirty. The pilot above is not in the repository, so which of its
properties produced two minutes cannot be checked. The numbers below are the
ones to trust, and they are reproducible from the description given there.* The pilot that detours for
charges takes roughly twice as many hits and survives *longer*, which is the
trade the game is about.

## Tuning

| constant | meaning | shipped |
|----------|---------|---------|
| `$SPEED_BASE` / `$SPEED_PER_KM` / `$SPEED_CAP` | opening speed, ramp per 1000px, ceiling | 250 / 18 / 640 |
| `$DRAIN_BASE` | current per second at `$SPEED_BASE`, scaled by actual speed | 3.4 |
| `$CHARGE_GAIN` / `$HIT_COST` | what a charge gives and a component costs | 17 / 20 |
| `$SLIDE_SPEED` / `$STUN_TIME` | trace-change rate, and the sparking window | 900 / 0.45 |
| `$ROW_GAP` / `$ROW_GAP_MIN` / `$ROW_GAP_STEP` | distance between rows, its floor, and the taper | 300 / 172 / 8 |
| `$CAP_PERIOD` | seconds per capacitor flip | 1.35 |
| `$LANES` / `$LANE_W` | the board | 6 / 160 |

The curve is entirely a function of distance travelled:

| per 1000px | value |
|---|---|
| speed | +18, capped at 640 (reached at ~21km) |
| row spacing | −8, floored at 172 |
| traces a row may block | +1 per 2.2km, from 2 to 3 of 6 |
| component kinds in play | 1 below 900m, 2 below 2km, 4 after |

The speed ramp, the row-spacing taper and floor, the drain and the hit cost are
the **Normal** column of the difficulty table rather than fixed constants. See
below.

## Difficulty, September 2026

Three settings, picked with the HUD button or
`mount(el, { difficulty: 'hard' })`. The table lives in the engine:
`set_difficulty(d)` records the choice (0 easy, 1 normal, 2 hard) and `init()`
applies it, so a setting never changes halfway through a run.

| | Easy | Normal | Hard |
|---|---|---|---|
| Rows closer per km | 5 px | 8 px | 11 px |
| ... floored at | 195 px | 172 px | 150 px |
| Speed added per km | 14 | 18 | 22 |
| ... capped at | 640 | 640 | 640 |
| Drain at base speed | 2.8 /s | 3.4 /s | 3.9 /s |
| A hit costs | 16 | 20 | 24 |

### This title was not supposed to get a table

The backlog said Circuit Runner was the exception: *speed is its only curve, so
"easier" is starting slower and ramping later, not a setting with columns.* The
bench disagreed on every count, and the table is what came of that.

**The opening was already gentle.** A pilot that reacts to the nearest row
after a quarter of a second — the pilot used for everything below — reached the
thirty-second mark with the meter at 96–100 and two or three hits taken.
Starting slower would have made the first half-minute emptier, not fairer, and
this repository has a rule about dead time.

**Speed was not the curve that ended runs.** Over 24 boards, runs ended at
**18–20 km whatever the speed ramp was**. Nearly halving it — 18 per km down to
10 — bought the quarter-second pilot twelve seconds, 46 to 58, and the speed it
died at *fell* as the ramp slowed (571 to 448 px/s). Something else was keyed to
distance.

**What was keyed to distance is the row spacing.** It tapers 8 px a kilometre to
its floor at 16 km — the other curve the backlog's note missed. The time a
player has per row is spacing over speed, so that is the quantity the table
moves. And the meter's own drain, not the hits, was most of what emptied it:
**63% of everything a run lost** went to drain, 37% to hits. So the drain is in
the table, and the hit cost with it as this game's lives.

The note in the backlog was a reasonable reading of the code — the comment on
`$SPEED_BASE` calls speed "the only difficulty curve an endless runner needs" —
and it was wrong in a way only a bench could show.

### Two choices worth recording

**Every column keeps Normal's speed cap.** At Hard's end, `$SPEED_CAP`'s note
is that 640 is as fast as the lane slide can answer, and the reserved path is a
guarantee only while one lane can be crossed between two rows. Hard's floor of
150 px at 640 px/s is a row every 0.23 s against a 0.18 s slide — it holds. A
higher cap on the tighter spacing would not.

At Easy's end, the first draft capped Easy at 560 with a 210 px floor, and a
pilot with a 150 ms reaction ran a median of **504 seconds**, some runs reaching
the bench's ten-minute limit. A row every 0.38 s at the top of the curve is a
steady state a quick player never leaves, and an endless-runner setting that
never ends has no curve left in it. At 640 and 195 px that pilot's median is
105 s and every run ends, while the slow pilot Easy exists for keeps its extra
twenty seconds.

**Three things are not in the table.** `$SPEED_BASE` is where the board starts
*and* the reference the drain is scaled against, so moving it would silently
move the drain on every column. `$SLIDE_SPEED` and `$STUN_TIME` are the feel of
the runner, and the path guarantee is built on the slide. The lanes a row may
block and the component kinds stay put, because both reach their final values by
2.2 km and no run is decided that early.

### The bench

**Normal is the previous balance exactly.** The same input replayed through the
committed engine and this one gave byte-identical memory across the 1,272-byte
layout and all seventeen readers on every frame, over 36,000 frames,
re-initialising on each game over.

The engine seeds its board to a constant, so one engine is one board; the bench
rewrote the seed to get **24 boards**, and drove each with the reacting pilot at
three reaction times. Survival, worst / median / best:

| | 150 ms | 250 ms | 350 ms |
|---|---|---|---|
| Easy | 59 / **105** / 148 s | 47 / **68** / 128 s | 27 / **60** / 107 s |
| Normal | 39 / **52** / 89 s | 24 / **46** / 68 s | 24 / **38** / 74 s |
| Hard | 33 / **40** / 66 s | 11 / **32** / 56 s | 22 / **27** / 45 s |

Hard runs 70-77% as long as Normal at every reaction time; Easy runs
roughly half as long again, and twice as long for the quick pilot. The opening
stays gentle on all three: a median of 0–3 hits in the first thirty seconds.

**One honest outlier.** Hard's worst run at 250 ms ends at 11 seconds: one
board that lands three hits in that time and offers only two charges, so at 24
current a hit the meter that started at 85 is gone. The same board on Normal
runs past 26 s. It is one board in 24, and the median opening is as gentle as
Normal's, but it is the harshest thing the bench found, and it is Hard's hit
cost doing it.

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and Easy and Hard get `circuit-runner:easy` and `circuit-runner:hard`.

## Rebuilding the engine

```bash
npm install                    # wabt is a devDependency of this repo
npm run build:circuit-runner   # game.wat -> game.wasm, re-embedded into the .js
npm run check                  # verify the committed binary matches its source
```

## Browser support

Any browser with WebAssembly. No build step, no dependencies, no imports, and
no network requests at runtime — the engine ships inside the JS file.
