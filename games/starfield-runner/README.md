# Starfield Runner

A courier ship falling through a debris field that will not stop speeding up.
There is nothing to shoot and nothing to pick up. The only thing worth points
is **how close you fly to the rocks** — and the only way to patch the hull is
the charge that shaving them banks. All of it, including the field generator
that guarantees a way through, is hand-written in WebAssembly Text
(`game.wat`) and runs as a compiled `.wasm` binary. JavaScript forwards one
number, calls `step(dt)`, and draws what it finds in the engine's linear
memory.

Works on **desktop (arrow keys)** and **mobile (an analogue thumb rail)**.

Open [`index.html`](index.html) to play it.

## Why this exists next to Circuit Runner

Both scroll toward the player, and that is very nearly why this title was not
built at all. The roadmap said so in writing: *build the tight-squeeze scoring
first, or do not build it.* So the squeeze **is** the game, and everything else
was chosen to get out of its way.

| | Circuit Runner | Starfield Runner |
|---|---|---|
| Movement | six discrete traces, a snap slide | analogue x with momentum |
| To collect | charge pickups, deliberately off the safe lane | nothing at all |
| Score | distance, plus what you collected | distance, plus **how little clearance you left** |
| Repair | pickups | only the charge close passes bank |
| Safe play | genuinely safe; the charge is the temptation | survives, and scores 23 points a second |

The last row is the design. A lane cannot express "two pixels closer", so the
ship flies free; a pickup would make safe flying viable, so there are none; and
a hull that repairs itself would let a careful player wait the game out, so the
only repair is the thing that nearly kills you.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.sr-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, entity pools at fixed offsets, an xorshift RNG, monotonic event
counters, and an `init` / `set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` verifies all eight committed binaries in one pass.

### It has no imports

Like [Worm Chase](../worm-chase/), [Sector Defense](../sector-defense/) and
[Circuit Runner](../circuit-runner/):

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

The engine's only geometry is a clearance — a centre distance less two radii —
and `f32.sqrt` is an instruction rather than a library call. Nothing here turns
through an angle, so there is nothing to ask JavaScript for.

## Files

```
starfield-runner/
├── starfield-runner.js   ← the widget (engine embedded inside) — REQUIRED
├── starfield-runner.css  ← scoped styles (.sr-*)               — REQUIRED
├── game.wat              ← engine SOURCE — edit to change gameplay
├── game.wasm             ← compiled engine (also embedded in the .js as base64)
├── index.html            ← standalone page: the game and nothing else
├── demo.html             ← minimal working integration example
├── logo.svg              ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`starfield-runner.js` and `starfield-runner.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="starfield-runner.css">

<div id="game"></div>

<script src="starfield-runner.js"></script>
<script>
  var game = StarfieldRunner.mount('#game');
</script>
```

### JavaScript API

```js
var game = StarfieldRunner.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, distance, speed, hull, charge, multiplier,
                   //   grazes, squeezes, gameOver }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action  | Desktop        | Mobile                       |
|---------|----------------|------------------------------|
| Fly     | ← / → or A / D | slide anywhere on the lower half |
| Restart | R              | tap the GAME OVER text       |
| Mute    | M              | the SOUND button             |

**An analogue rail rather than tap zones**, which is the opposite of the call
[Circuit Runner](../circuit-runner/README.md) makes, for the opposite reason.
There, the input is discrete and a stick would mean pushing, waiting and
re-centring for every lane change. Here the entire scoring rule is about how
many pixels you left, and a two-state control cannot ask for thirty of them.
`set_input` takes an f32, so a nudge drifts and a full push commits.

The keyboard overrides the rail whenever a key is down, so a laptop with a
touchscreen behaves.

## Gameplay rules

- **Three hull plates.** Hitting anything costs one, and there are no lives
  beyond them. Losing the last one ends the run.
- **A hit costs more than a plate.** The multiplier drops to ×1, the banked
  charge is halved, and you get 1.15s of immunity so a dense field cannot land
  three hits on a ship that is still inside the first rock.
- **Graze.** Passing within **30px of a rock's surface** without touching it
  scores, and scores more the tighter it was — a pass at two pixels is worth
  the full amount, one at twenty-nine is worth almost nothing.
- **Squeeze.** Two grazes settling within 0.34s of each other mean you went
  *between* two rocks. That is worth much more, and it is **the only thing that
  raises the multiplier**.
- **The multiplier bleeds** one step for every 1,100px flown without a graze.
  Not per second — per distance, so slowing down is not an option and never
  was.
- **Charge patches the hull.** Grazes and squeezes bank charge; 100 of it buys
  a plate back. At full hull it converts to a 250-point bonus instead, so a
  clean run through a dense field is never wasted.
- **Distance scores flat, without the multiplier.** The multiplier is what risk
  buys; letting it apply to the metre count as well would make the best move
  after a squeeze "stop taking any".

### The three kinds of debris

| Kind | Radius | Behaviour |
|---|---|---|
| **Shard** | 15–23 | small, and therefore the good ones to thread |
| **Boulder** | 30–41 | big enough that the corridor has to matter |
| **Slab** | 24–33 | drifts sideways at up to 34px/s and turns at the walls |

A slab is placed a further 40px clear of the corridor than the others, because
it can wander and a rock that crossed the corridor after placement would undo
the guarantee below.

## The corridor, and why it is drawn

Every field leaves a **guaranteed corridor** that no rock may intrude on, and
its centre moves by a bounded amount between fields. That is Circuit Runner's
`$pathLane` construction, generalised from six discrete lanes to an analogue x,
and it exists for the same reason: fields generated independently can each be
fair and collectively impossible.

What is different here is that **the corridor is on screen.** Every rock
carries its field's corridor centre in its record, and the renderer reads it
off the nearest oncoming rock and draws the channel. Hiding it would make the
game a memory test about where the safe line probably is. Showing it turns
every field into the question the title is actually about:

> the safe line is right there, and it is worth nothing.

Leaving it becomes a choice rather than an accident.

## Architecture

```
starfield-runner.js  ── set_input(move) ──▶  game.wasm  (all simulation state)
        ▲                step(dt)                │
        └──── reads rock records + get_*() ◀─────┘
```

**JavaScript owns no game state.** It forwards one number per frame, calls
`step(dt)`, and walks the rock pool to draw it. Every rule — the ramp, the
field generator, the corridor, what counts as a graze, what a squeeze is worth
— lives in `game.wat`.

The engine never calls out. It exposes **monotonic event counters**
(`get_grazes`, `get_squeezes`, `get_hits`, `get_patches`, `get_fields`) and the
widget diffs them between frames to decide what to play, what to shake and what
to spark. One place decides what happened, so the sound, the particles and the
HUD can never disagree.

### The `near` field does double duty

Each rock stores the **tightest surface clearance it has ever had** to the
ship. The engine uses it to settle up when the rock drops behind: inside the
band, that is a graze. The renderer reads the *same number* to light a ring
around the rock as the ship closes, and to leave it lit afterward — so the
player can see which rocks paid before the score catches up, and nothing in
the widget had to decide anything.

Settling up **on the way out rather than on the way in** is deliberate. Scoring
the moment the ship enters the band would pay for a near miss the player then
turned into a collision, and would pay again every frame the rock slid past.

### WASM linear memory layout

| region | offset | stride | count | fields |
|--------|--------|--------|-------|--------|
| ship   | 0      | —      | 1     | x, vx, alive, invuln |
| rocks  | 16     | 40 B   | 26    | x, y, vx, r, active, near, spin, kind, resolved, path |

Total 1,056 bytes of a single 64 KiB page. Score, distance, hull, charge and
the multiplier are globals rather than memory, as in the other recent titles:
the `get_*` readers are the only consumer, and a global is one instruction to
read.

> **The widget hard-codes these offsets.** Change the layout in `game.wat` and
> `starfield-runner.js` must change with it — nothing links them at build time,
> and the failure is silent. `npm run check` runs
> [`scripts/check-layout.mjs`](../../scripts/check-layout.mjs), which compares
> the named constants; it cannot compare *field order*, so the memory-map
> comment at the top of `game.wat` is the schema to keep honest.

### Exports

```
init() · set_input(move) · step(dt)
get_score() · get_dist() · get_speed() · get_speed_base()
get_hull() · get_hull_max() · get_charge() · get_charge_max()
get_mult() · get_mult_frac()
get_ship_x() · get_ship_y() · get_ship_vx() · get_ship_r() · get_invuln()
get_graze_band() · get_corridor() · get_path_step() · get_path_x()
is_game_over()
get_grazes() · get_squeezes() · get_hits() · get_patches() · get_fields()
```

`get_mult_frac()` is how much of the current multiplier step is left before it
bleeds. The HUD draws it as a draining underline, which is the only warning the
player gets that a stretch of safe flying is costing them.

## The graphics

Everything is drawn into a **320×240 buffer and blown up 3× with smoothing
off**, as in [Asteroid Miner](../asteroid-miner/), Sector Defense and Circuit
Runner. The whole adapter is one transform:

```js
g.setTransform(1 / 3, 0, 0, 1 / 3, 0, 0);   // still drawing in 960x720 units
screen.drawImage(low, 0, 0, 960, 720);
```

**No glow anywhere.** `shadowBlur` is the giveaway that a picture was made
after about 1995; brightness is a brighter colour. Everything lands on whole
low-res pixels, screen shake included, and the scanlines and vignette are CSS
so they sit at true display resolution. Both are dropped under
`prefers-reduced-motion`.

The ship and its flame are ASCII-grid sprites. **The rocks are not.** A rock is
a radius the engine picked from a range, and an ASCII grid has one size — three
hand-drawn boulders would be three things to keep looking alike, and all of
them would be the wrong radius for the collision the player is being scored on.
They are drawn as pixel discs on the same low-res grid instead. Circuit Runner
reached the same conclusion about its variable-width components.

The starfield is three parallax layers, owned by the widget rather than the
engine, and that is the line: nothing collides with a star, nothing scores one,
and the engine has no opinion about how deep the sky is.

## Findings from benching

Every number here came from driving the compiled engine headlessly from Node.
The RNG is seeded to a constant and is touched only by spawning, so **every
pilot below flew the identical board** — the comparisons are controlled.

### 1 · A constant corridor step is unreachable at speed

The corridor may move between fields, and the first build let it move a flat
210px. A pilot that flew nothing but the corridor was hit three times in two
minutes, and every hit was at the speed cap with the ship **106–170px outside a
corridor 160px wide**. It was not dodging badly; it was still on its way.

At 620px/s a field arrives 268px after the last, which is 0.43s, and 0.43s of
thrust against this much drag covers 142px from rest. A 210px step was simply
not reachable, and no amount of skill closes that.

The step is now a *rate* — `$REACH_RATE`, 300px per second of flight time —
so it shrinks as the board speeds up. Same pilot, same board:

| corridor step | survived | hits |
|---|---|---|
| flat 210px | 122s | 3 |
| rate-based | 194s | 3 |
| rate-based, tighter controller | **1800s (bench limit)** | **0** |

The last row is the verification that matters: **4,060 fields, no hits.** The
corridor guarantee holds, and every death in this game is the player having
left it.

### 2 · Playing safe scores 23 points a second

One pilot, one knob: how wide a gap it prefers to aim for. 1200-second limit,
same board every run.

| gap preferred | survived | score | per second | hits | plates patched |
|---|---|---|---|---|---|
| widest available | 251s | 5,872 | **23** | 3 | 0 |
| ~300px | 308s | 7,978 | 26 | 4 | 1 |
| ~200px | 92s | 9,124 | 99 | 3 | 0 |
| ~150px | 88s | 19,614 | **223** | 5 | 2 |
| ~120px | 88s | 18,326 | 208 | 6 | 3 |
| ~100px | 88s | 14,828 | 169 | 6 | 3 |
| ~84px | 80s | 12,413 | 155 | 7 | 4 |
| ~70px | 85s | 15,520 | 182 | 8 | 5 |
| ~56px | 85s | 27,128 | 317 | 7 | 4 |

Two things fall out of that table, and both of them are the game working:

- **The widest-gap pilot never patched a plate.** It banked so little charge
  that it never reached 100, so its three hits were simply three hits and it
  died of them. Safe flying is not a slower strategy; it runs out.
- **Every risk-taking setting scores five to thirteen times as much per
  second,** and survival barely moves until the pilot is aiming at gaps
  narrower than about 100px. Beyond that it starts paying in hull.

The table cannot resolve a *peak* — 56px outscoring 150px is one board's luck,
not a finding — and it is quoted as measured rather than smoothed.

### 3 · The ramps were four times too fast

The first build reused Circuit Runner's per-kilometre steps directly. It should
not have: this board is faster and its `km` counter runs up quicker, so field
size hit its cap fifteen seconds in and the corridor hit its floor before the
first minute. Every ramp was divided by roughly four, which spreads the curve
over about the first two minutes and leaves the back half of a good run
somewhere to go.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$SPEED_BASE` / `$SPEED_PER_KM` / `$SPEED_CAP` | opening speed, ramp per 1000px, ceiling | 250 / 11 / 620 |
| `$THRUST` / `$DRAG` / `$MAX_VX` | how the ship flies | 2700 / 4.6 / 540 |
| `$GRAZE_BAND` | how close counts, in px of surface clearance | 30 |
| `$SQUEEZE_WINDOW` | two grazes this close together are one gap | 0.34s |
| `$SCORE_GRAZE` / `$SCORE_SQUEEZE` | at maximum tightness, before the multiplier | 30 / 140 |
| `$CHARGE_MAX` / `$CHARGE_GRAZE` / `$CHARGE_SQUEEZE` | what a plate costs, and what risk banks | 100 / 9 / 22 |
| `$MULT_MAX` / `$MULT_DECAY_PX` | ceiling, and the clean distance that costs a step | 9 / 1100 |
| `$CORRIDOR` / `$CORRIDOR_MIN` / `$CORRIDOR_STEP` | the guaranteed channel and its taper | 250 / 148 / 1.6 |
| `$REACH_RATE` / `$PATH_STEP_MAX` | how fast the corridor may wander | 300 / 300 |
| `$FIELD_GAP` / `$FIELD_GAP_MIN` / `$FIELD_GAP_STEP` | distance between fields, floor, taper | 400 / 268 / 2.6 |
| `$HIT_COST` — there isn't one | a hit costs a plate, the multiplier and half the charge | — |

The difficulty curve, per 1000px travelled:

| per 1000px | value |
|---|---|
| speed | +11, capped at 620 (reached at ~34km) |
| field spacing | −2.6, floored at 268 |
| corridor width | −1.6, floored at 148 |
| rocks per field | +1 per 15km, from 3 to 6 |

## Rebuilding the engine

```bash
npm install                       # wabt is a devDependency of this repo
npm run build:starfield-runner    # game.wat -> game.wasm, re-embedded into the .js
npm run check                     # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `starfield-runner.js` are both
committed, so a fresh checkout plays with nothing installed. `npm run check` is
what stops the three copies of the engine drifting apart.

## Browser support

Any browser with WebAssembly MVP and canvas 2D: Chrome/Edge 57+, Firefox 52+,
Safari 11+. The engine uses **strict MVP** — four value types, one 64 KiB page,
structured control flow, no post-MVP feature and no feature detection. Sound
needs Web Audio and is created on the first input, because browsers refuse to
start audio outside a user gesture; without it everything else still works.
