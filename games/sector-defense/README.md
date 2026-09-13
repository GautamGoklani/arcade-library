# Sector Defense

Hold a line. Attackers descend in waves, each one picking its own path across
the field, and anything that reaches the bottom takes a bite out of the sector
you are defending. A regenerating shield absorbs incoming fire — but only
recovers once the shooting stops. All of it — the attackers' intent, the two
meters, the decaying combo and the wave curve — is hand-written in WebAssembly
Text (`game.wat`) and runs as a compiled `.wasm` binary. JavaScript forwards
input, calls `step(dt)`, and draws what it finds in the engine's linear memory.

Works on **desktop (keyboard)** and **mobile (horizontal stick, round FIRE
button)**.

Open [`index.html`](index.html) to play it.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.sd-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, entity pools at fixed offsets, an xorshift RNG, and an `init` /
`set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` verifies all seven committed binaries in one pass.

### It has no imports

Like [Worm Chase](../worm-chase/), this module imports nothing:

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

It was drafted with the usual `sinf`/`cosf` pair and neither turned out to be
reachable. Attackers steer toward a target *column* rather than along a curve,
everything falls straight down or on a fixed lateral, and every collision is an
axis-aligned box test — so there is no angle in the engine and no `sqrt`
either. An import that is never called is a dependency for nothing, so they
went.

## Files

```
sector-defense/
├── sector-defense.js   ← the widget (engine embedded inside) — REQUIRED
├── sector-defense.css  ← scoped styles (.sd-*)               — REQUIRED
├── game.wat            ← engine SOURCE — edit to change gameplay
├── game.wasm           ← compiled engine (also embedded in the .js as base64)
├── index.html          ← standalone page: the game and nothing else
├── demo.html           ← minimal working integration example
├── logo.svg            ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`sector-defense.js` and `sector-defense.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="sector-defense.css">

<div id="game"></div>

<script src="sector-defense.js"></script>
<script>
  var game = SectorDefense.mount('#game');
</script>
```

### JavaScript API

```js
var game = SectorDefense.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, level, shield, sector, combo, multiplier, bestCombo, gameOver }
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
| Move    | ← / → or A / D     | left stick (horizontal)|
| Fire    | Space (hold)       | round **FIRE** button  |
| Restart | R                  | tap the GAME OVER text |
| Mute    | M                  | the SOUND button       |

The defender has **one axis**, so the touch control is Grid Breaker's rail
rather than Asteroid Miner's free stick: the knob travels horizontally only,
and the ring is drawn with a rail across it to say so before it is touched. It
is analog — `set_input` takes the direction as an `f32` applied as a fraction
of `PLAYER_SPEED`, so a nudge walks the defender into position and a full push
sprints it across. The keyboard is the digital special case that can only ever
ask for `-1`, `0` or `1`, and the engine never learns which produced the value.

## Gameplay rules

- **Nothing gets past the line.** An attacker that crosses the sector line is
  destroyed and takes 18 off the sector. That is the only thing you are really
  defending; the defender itself cannot be destroyed and never respawns.
- **The shield absorbs, then the sector pays.** An enemy shot takes 34 off the
  shield if there is any left. If there is not, it takes 10 off the sector. A
  partial shield still absorbs the whole hit — a shield that let some through
  would need the player to track two numbers to predict one outcome.
- **The shield only recovers after a pause.** 2.6 seconds without being hit,
  then 11 a second. That delay is the mechanic: it turns "don't get hit" into
  "break contact and recover", which is a decision rather than a reflex.
- **The combo decays.** Each kill within 2.4 seconds of the last extends a
  streak worth up to 4× score. Letting the window lapse costs it exactly as
  surely as being hit does, so the multiplier is really a measure of pressure
  maintained.
- **Clearing a wave repairs 15 sector** and refills the shield, and pays 150
  plus whatever shield is left. Without the repair a single bad wave early is
  carried for the whole run, and the game becomes about a mistake made minutes
  ago.
- The sector reaching zero is the only way to lose.

### The four attackers

Each has its own silhouette, so what is coming is readable by shape and not
only by colour — which also means the game still reads with the colour turned
down, and to a colour-blind player.

| | Kind | Behaviour | From |
|---|---|---|---|
| ● | **Drifter** | Walks toward a target column, picks a new one on arrival | wave 1 |
| ✦ | **Weaver** | Half again as fast sideways, and re-rolls its target mid-crossing | wave 2 |
| ▼ | **Diver** | Descends normally until it lines up with you, then drops at 3.4× | wave 3 |
| ■ | **Hulk** | Two hits, barely moves sideways, fires half as often | wave 4 |

Every attacker moves in a straight line you can see — the unpredictability is
in *when it changes its mind*, not in the motion itself. That distinction is
what keeps a formation unreadable without making any single attacker unfair.

### Scoring

| event | points |
|---|---|
| kill | 20 × multiplier (1× to 4×) |
| wave cleared | 150 + shield remaining |

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ sector-defense.js (JavaScript)                       │
│   • builds DOM, reads keyboard and touch input       │
│   • calls set_input(move, fire) → step(dt)           │
│   • reads the attacker and bullet records straight   │
│     out of wasm linear memory and draws them         │
│   • draws into a 320x240 buffer, blown up 3x         │
│   • particles, shake and sound are presentation only │
│     — triggered by diffing the engine's counters     │
└───────────────▲──────────────────────────────────────┘
                │ exports: init, set_input, step, enemies_alive,
                │ the get_* readers below, and memory
┌───────────────┴──────────────────────────────────────┐
│ game.wasm (compiled from hand-written game.wat)      │
│   • the defender's one axis and its fire cooldown    │
│   • per-attacker intent, descent, diving and firing  │
│   • two bullet pools, box collision both ways        │
│   • shield absorption, the regen delay, sector damage│
│   • the decaying combo and its multiplier            │
│   • wave composition, spawn drip, score              │
└──────────────────────────────────────────────────────┘
```

### WASM linear memory layout

| region   | offset | stride | count | fields |
|----------|--------|--------|-------|--------|
| player   | 0      | —      | 1     | x, y, alive (padded to 16) |
| enemies  | 16     | 40 B   | 24    | x, y, vx, vy, hp, kind, active, phase, cd, targetX |
| pbullets | 976    | 24 B   | 20    | x, y, vx, vy, life, active |
| ebullets | 1456   | 24 B   | 30    | x, y, vx, vy, life, active |

**Total: 2,176 bytes.** Kinds are 0 drifter, 1 weaver, 2 diver, 3 hulk.
Scalars — score, shield, sector, combo — live in globals rather than memory, as
in Worm Chase and Asteroid Miner: the `get_*` readers are the only consumer.

`phase` is the one field the simulation never reads. It is a per-attacker
random constant the renderer animates from, so a group spawned in the same
frame does not bob in lockstep — the same trick Worm Chase uses with its
`epoch` byte, which is to say: when the renderer needs a per-entity constant,
the cheapest place to put it is in the record JavaScript is already walking.

**If you change this layout in `game.wat`, change the constants at the top of
`sector-defense.js` with it.** Nothing links the two at build time.

### Exports

`init`, `set_input(move, fire)`, `step(dt)`, `enemies_alive`, `get_mult`,
`memory`, and the readers: `get_score`, `get_level`, `get_shield`,
`get_shield_max`, `get_sector`, `get_sector_max`, `get_sector_y`, `get_combo`,
`get_best_combo`, `get_combo_timer`, `get_combo_window`, `get_to_spawn`,
`get_player_x`, `get_calm`, `is_game_over`, and the event counters
`get_shots`, `get_kills`, `get_hurts`, `get_leaks`, `get_breaches`,
`get_waves`.

`get_calm` — seconds since the last hit landed — exists so the HUD can show
*which state the shield is in* rather than leaving the player to infer it from
a bar that has started moving.

## The graphics

Same treatment as [Asteroid Miner](../asteroid-miner/): the field is drawn into
a **320×240 buffer and blown up 3× with smoothing off**, so every mark
rasterises at the low resolution and nothing on screen is finer than the
sprites are. No glow anywhere — brightness comes from picking a brighter
colour, so a bullet is a coloured block with a pale core. Stars, bullets and
particles snap to the low-res grid, and screen shake moves in whole low-res
pixels. Scanlines and a vignette sit over the canvas in CSS, at true display
resolution, and both are dropped under `prefers-reduced-motion`.

The sector line is the only piece of level geometry in the game, so it is drawn
as a scrolling hazard stripe rather than a hairline: its position has to be
readable at a glance while the player is looking somewhere else, and its colour
carries the sector meter a second time.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$PLAYER_SPEED` / `$FIRE_CD` | defender speed, and seconds between shots | 430 / 0.185 |
| `$SHIELD_MAX` / `$SHIELD_HIT` | shield size, and what one enemy shot costs | 100 / 34 |
| `$SHIELD_REGEN` / `$SHIELD_DELAY` | regen per second, and the calm needed first | 11 / 2.6 |
| `$SECTOR_MAX` / `$BREACH_DAMAGE` / `$LEAK_DAMAGE` | the sector, a crossing, an unshielded hit | 100 / 18 / 10 |
| `$COMBO_WINDOW` / `$COMBO_CAP` | seconds to keep a streak, and its ceiling | 2.4 / 30 |
| `$DIVE_MUL` | how much faster a diver drops once lined up | 3.4 |

The wave curve is keyed on the wave number and clamped:

| per wave | wave 1 | growth | ceiling |
|---|---|---|---|
| attackers | 5 | +2 | 26 |
| seconds between arrivals | 1.15 | −0.035 | 0.34 |
| descent speed | 22 | +3.4 | 95 |
| lateral speed | 95 | +7 | — |
| attacker kinds in play | 1 | +1 per wave | 4 |

### Two findings from benching

A headless pilot driving the compiled binary — perfect aim, always shooting the
lowest attacker — exposed both.

1. **A ceiling the player never feels is not a difficulty curve.** The descent
   cap sat at 62 px/s in the first build, which is eleven seconds to cross the
   field. The pilot cleared **28 waves without a single attacker ever reaching
   the line**, and survived past the bench's 15-minute cap. The cap is now 95.
2. **A harder wave should not just be a longer wave.** With a fixed 1.15s
   spawn drip, wave 26 spends thirty seconds spawning before its last attacker
   even arrives — the bench measured waves averaging 30 seconds each. The drip
   now tightens by 0.035s a wave to a floor of 0.34s, so later waves arrive
   *faster* rather than merely for longer.

After both, the same pilot dies at **wave 22** ignoring incoming fire and
**wave 15** while dodging — dodging pulls it off target, so it kills less and
lets more through, which is the trade the game is about. Wave 1 is deliberately
quiet: five drifters, one kind, the slowest descent in the game.

## Rebuilding the engine

```bash
npm install                     # wabt is a devDependency of this repo
npm run build:sector-defense    # game.wat -> game.wasm, re-embedded into the .js
npm run check                   # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `sector-defense.js` are both committed,
so a fresh checkout plays with nothing installed — which is exactly the
arrangement that lets a binary drift away from the `.wat` it claims to be built
from. `npm run check` recompiles into memory and fails if either committed copy
disagrees with the source. It covers every title, so run it before pushing an
engine change.

## Browser support

Any browser with WebAssembly. No build step, no dependencies, no imports, and
no network requests at runtime — the engine ships inside the JS file.
