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
`npm run check` verifies all nine committed binaries in one pass.

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
game.getState();   // { score, level, shield, sector, combo, multiplier, bestCombo, gameOver, paused, difficulty }
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
| Move    | ← / → or A / D     | left stick (horizontal)|
| Fire    | Space (hold)       | round **FIRE** button  |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |
| Pause   | P or Esc; losing focus too | the PAUSE button; tap the sector to resume |
| Restart | R                  | tap the GAME OVER text |
| Mute    | M                  | the SOUND button       |

**Gamepad**, standard mapping, no setup: left stick or d-pad moves along the
line, `A` / `X` / either trigger fires, `Start` pauses, `Back` or `Y` restarts,
a shoulder button mutes. It is polled once a frame rather than listened for,
because `getGamepads()` only refreshes its snapshots when called.

Pause is the widget's, not the engine's: the engine advances by whatever `dt` it
is handed, so pausing is the loop not calling `step` while it goes on drawing
the frozen frame. See [chapter 15](../../docs/15-game-loop-architecture.md).

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
- **Every fifth wave comes by carrier.** A heavy ship descends to the top of
  the field, patrols, and drops the wave's attackers from its bay (its lights
  blink before each drop) instead of letting them walk in from the top edge.
  Bring it down and whatever is still in the bay never arrives: 300, plus 40
  for each attacker denied. Once the bay is empty it climbs away. See
  [Carrier waves](#carrier-waves-september-2026).
- **Waves 3, 8, 13 and on bring a lander.** Three seconds in, a small orange
  craft dives from the top edge toward the far side of the field from you, to a
  landing spot at mid-field marked with blinking brackets, and puts a squad of
  three to five attackers down there at once. The squad is part of the wave's
  count, not extra. Six rounds (two more each lander) bring it down on the way
  in and deny the squad: 150, plus 40 an attacker. See
  [The lander](#the-lander-october-2026).
- **A kill sometimes drops a shield module** (1 in 20). It falls straight
  down from where the attacker died, with a tick on your line showing where it
  will land. Catch it and the shield is full at once, with no recovery pause,
  plus 50 points. Miss it and it falls through the line. See
  [The shield module](#the-shield-module-september-2026).
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
| carrier brought down | 300 + 40 per attacker still in the bay |
| lander brought down | 150 + 40 per attacker aboard |
| shield module caught | 50 |

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
| carrier  | 2176   | —      | 1     | x, y, vx, hp, maxHp, active, bay (seconds to the next drop), flash |
| module   | 2208   | —      | 1     | x, y, vy, active |
| lander   | 2224   | —      | 1     | x, y, landY, hp, active, squad, flash, climbing |

**Total: 2,256 bytes.** The carrier went in after the bullet pools, the module
after the carrier and the lander after the module, so nothing that existed
before any of them moved. Kinds are 0 drifter, 1 weaver, 2 diver, 3 hulk.
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
`get_player_x`, `get_calm`, `get_shield_delay`, `is_game_over`, and the
event counters `get_shots`, `get_kills`, `get_hurts`, `get_leaks`,
`get_breaches`, `get_waves`, `get_carriers`, `get_carrier_hits`,
`get_carrier_downs`, `get_bay_drops`, `get_denied`, `get_module_drops`,
`get_module_catches`, `get_landers`, `get_lander_hits`, `get_lander_downs`,
`get_landings`. A lander's denied squad is added to `get_denied` with the
carrier's.

`get_calm` — seconds since the last hit landed — exists so the HUD can show
*which state the shield is in* rather than leaving the player to infer it from
a bar that has started moving. `get_shield_delay` is the pause it has to reach.
The widget used to compare against a hard-coded 2.6, which is Normal's value.
The difficulty table sets 2.0 on Easy and 3.4 on Hard, so on those settings the
bracket over the defender changed colour at the wrong moment. It was found
while adding the module, and it is the mistake CLAUDE.md warns about: a number
the table can move, shown by the widget from its own copy.

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

Several of the numbers in both tables above are the **Normal** column of the
difficulty table rather than fixed constants. See below.

## Difficulty, September 2026

Three settings, picked with the HUD button or
`mount(el, { difficulty: 'hard' })`. The table lives in the engine:
`set_difficulty(d)` records the choice (0 easy, 1 normal, 2 hard) and `init()`
applies it, so a setting never changes halfway through a run.

| | Easy | Normal | Hard |
|---|---|---|---|
| The sector's capacity | 130 | 100 | 80 |
| ... repaired per wave cleared | 22 | 15 | 8 |
| Descent | 18, +2.6 a wave, cap 78 | 22, +3.4, cap 95 | 26, +4.2, cap 112 |
| Attacker fire gap | 3.0–5.4 s, floor 1.0 | 2.4–4.6 s, floor 0.75 | 2.0–4.0 s, floor 0.6 |
| A new attacker kind every | 2 waves | 1 wave | 1 wave, starting with 2 |
| Shield recovery pause | 2.0 s | 2.6 s | 3.4 s |
| Drip tightens per wave | 0.028 | 0.035 | 0.048 |
| ... gap floor | 0.48 s | 0.34 s | 0.24 s |
| Most attackers in a wave | 20 | 26 | 26 |

The three knobs the backlog named were **the descent rate, the fire rate and
which kinds arrive when**. Three more are in the table, and two of them were
added because a bench said so.

The sector's capacity is this game's starting lives — it is the only way to
lose, and every other title's table moves that number. The shield's recovery
pause is the other half of the fire rate: being shot at more often only matters
if breaking contact is also harder, and moving one without the other makes Hard
a game you win by standing still in a corner.

**A third finding from benching, and the reason for the last three rows.** With
only the knobs above in the table, the three columns came out **505 / 411 / 327
seconds** against the headless pilot — Hard ran 80% as long as Normal, where the
rest of the library's tables land nearer half. An instrumented run showed why:
**the sector was still at full capacity at wave 13 on all three settings.** The
run was a non-event until the shared spawn curve bottomed out and then collapsed
inside a minute, so the columns only separated in the last sixty seconds of a
six-minute run. That is not a difficulty curve; it is three ways to play the
same game. What actually decides when this game gets hard is the drip — how
fast the gap between arrivals tightens, and how short it may get — so that went
in the table, and the numbers became 581 / 411 / 268.

Note that **Hard keeps Normal's wave size** and only tightens the drip. More
attackers per wave at the same spacing is a longer wave rather than a harder
one, which is finding 2 above. Easy is the column that shortens the wave,
because on Easy a long wave is the problem.

**Three things are deliberately not in the table.** `$PLAYER_SPEED` and
`$FIRE_CD` are the feel of the defender rather than the challenge, and a
sluggish gun on Easy would be a different game to learn on. `$SHIELD_MAX` stays
at 100 because the shield is a meter the player reads as a percentage, and a
shield that is "120% full" is a worse HUD for no gain.

**Normal is the previous balance exactly.** The same input replayed through the
committed engine and this one gave byte-identical results on every frame — all
2,176 bytes of the simulated region plus all sixteen readers — over 36,000
frames, re-initialising on each game over so restarts and wave builds were
covered as well as one long run.

Benched with a pilot that tracks the lowest attacker with a jittered aim, fires
constantly, and never manages the shield or breaks contact to let it recover.
24 runs each, capped at fifteen minutes (no run reached the cap):

| | Survived: worst / median / best | Mean | Waves (median / best) | Kills (median) | Breaches (median) |
|---|---|---|---|---|---|
| Easy | 519 / 555 / 798 s | 580.7 s | 29 / 45 | 525 | 8 |
| Normal | 350 / 413 / 481 s | 410.7 s | 19 / 22 | 387 | 3 |
| Hard | 195 / 271 / 328 s | 268.2 s | 14 / 17 | 265 | 2 |

All three reach wave 3 in 24 of 24 runs, which is the bar CLAUDE.md sets for a
gentle opening — this game has never had a harsh start, and the table does not
give it one.

**What the bench does not cover, and one honest caveat.** Even after the drip
went into the table, **Normal's sector is still untouched at wave 17** — the
long quiet opening is the balance this engine already shipped with, and Normal
is byte-identical to it, so it is not something the table could fix without
changing what Normal is. Easy is quieter still by design. Only Hard starts
taking sector damage in the middle of a run rather than at the end of one. A
player who wants the fight to begin earlier wants Hard, and that is now a real
answer rather than a shrug. **Decided, September 2026: left as it is.**

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and Easy and Hard get `sector-defense:easy` and `sector-defense:hard`.

## Carrier waves, September 2026

The boss wave from the menu of features for the other eight titles, as the
menu described it: *a carrier that lands attackers instead of walking in*.

Every fifth wave, a carrier descends to the top of the field (y 96) and patrols
side to side, 80 px/s and 12 faster each carrier. The wave's attackers come out
of its bay at its position, on the wave's usual drip, instead of spawning along
the top edge. They start about 150 px lower, so they reach the line sooner, and they
arrive where the carrier is rather than anywhere at all. The bay's lights
blink for the last 0.6 s before each drop. It takes 24 rounds (8 more each
carrier) and never fires. Its threat is its payload.

**What it adds is a decision the other waves do not ask.** Shoot the carrier,
which is tough and far away, or the attackers it has already dropped, which are
falling toward the line. Bringing it down denies whatever is still in the bay:
**300, plus 40 for each attacker denied**, and those attackers never arrive.
Once the bay is empty it climbs away. That is no penalty, only a forgone bonus,
so a wave can never stall on a ship with nothing left to do. A round that
strikes no attacker carries on up and can still strike it, so stray fire
counts.

**Nothing about it is random.** Its path is a fixed patrol and it draws nothing
from `$rng`. A carrier wave's attackers roll their kinds exactly as a walking
wave's would, and **waves 1-4 replay the engine that had no carrier**: 72 runs
(24 seeds × 3 settings, 241,841 frames) identical byte for byte over the old
2,176 bytes and every old reader, up to wave 5.

### What it costs, and what shooting it is worth

Three pilots, each on 24 seeds per setting, all tracking with a 200 ms lag:
the old engine; the new one flown by a pilot that only ever shoots attackers
(the pilot the difficulty table was benched with); and the new one flown by a
pilot that goes after the carrier while it has a payload, unless an attacker is
already below the halfway line. Sector lost on the wave, mean:

| | Wave 5 | Wave 10 | Wave 15 | Carriers brought down | Denied, per carrier |
|---|---|---|---|---|---|
| Normal, no carriers | 5.0 | 8.9 | 13.2 | — | — |
| Normal, carrier ignored | 9.5 | 21.7 | 32.8 | 4 / 68 | 0.2 |
| Normal, **carrier first** | **0.9** | **6.3** | 31.4 | 52 / 72 | 5.2 |
| Hard, no carriers | 5.7 | 25.5 | — | — | — |
| Hard, carrier ignored | 9.6 | 35.4 | — | 6 / 44 | 0.5 |
| Hard, **carrier first** | **2.8** | **14.2** | — | 43 / 46 | 5.6 |

**Ignore it and a carrier wave costs about twice as much as a walking wave**,
because its attackers start closer to the line. **Shoot it first and the wave is
cheaper than a walking one**, and shorter: on Normal wave 5 took 11 s against
21 s ignored, and wave 10 took 17 s against 26. That gap is the decision, and it
is the right way round. Stray fire alone almost never brings one down (4 of 68),
so the payoff comes only from choosing to.

By wave 15 on Normal the choice stops mattering for this pilot (31.4 against
32.8). The wave is so dense by then that "unless an attacker is below the
halfway line" is nearly always true, so it rarely gets to shoot the carrier.
A player who picks their moment will do better than that rule.

**Overall, carriers take a little off a run rather than moving the curve**:
median survival 547 / 354 / 217 s without them, and 509-513 / 347-348 /
203-207 s with them, depending on the pilot. The difficulty table did not need
re-tuning, and a carrier wave is a spike with a decision in it, not a wall.

**What the bench cannot tell you** is how well a person reads the bay lights.
Both pilots ignore them. The lights say *where the next attacker will appear*,
which is worth most to a player lining up under the carrier to shoot it, and no
pilot here does that on purpose.

## The shield module, September 2026

The power-up from the menu of features for the other eight titles, as the menu
described it: *drop a shield module from a kill*.

One kill in twenty drops a module. It falls straight down at 140 px/s from where
the attacker died. A tick on the defender's line marks exactly where it will
land, and a soft two-note chime says one has fallen, so it is heard while you
are watching the attackers. **Catch it and the shield is full at once**, with no
recovery pause, plus 50 points. Miss it and it falls through the line and is
gone. One falls at a time, and a module still falling when the wave ends goes
with it. A cleared wave refills the shield anyway, so carrying it over would be
a free catch.

It restores the **shield**, not the sector, on purpose. The sector is the thing
being defended and the only way to lose, and nothing falling from the sky
should mend it; that would be a second life. The shield is the meter this game
already asks you to manage. The module is the one way to get it back without
breaking contact, and it costs exactly what breaking contact costs: it lands
where the attacker died, so reaching it means leaving the column you were
holding, usually for the one under the fire you were avoiding.

**It is drawn from a random stream of its own**, as Pixel Wave's and Worm
Chase's pickups are. The main stream never sees the roll, so the attackers,
their shots and their turns are the ones the engine without modules made. A
module that is never caught leaves the run exactly as it was. Replaying the
same input through both engines on all three settings gave identical memory
(the old 2,208 bytes) and fourteen readers on every frame until the first
catch. That covered 90,000 frames per setting, with 51 modules dropped and
missed along the way.

### What the bench found

The 200 ms-lag pilot the difficulty table and the carrier were benched with
(tracks the lowest attacker, fires constantly), in four versions: the engine
before modules; the new one flown by the same pilot, which ignores modules but
catches some by being in the way; and two that go for a falling module if they
can reach it and nothing is below y 520 — one whenever the shield is under 100,
one only under 50. 24 seeds each, median survival:

| | Before | Ignores it | Goes for it below 100 | Below 50 | Only when empty, and near |
|---|---|---|---|---|---|
| Easy | 513 s | 516 s | 527 s | 523 s | 513 s |
| Normal | 348 s | 353 s | 335 s | 345 s | 341 s |
| Hard | 203 s | 203 s | 203 s | 207 s | 203 s |

On Normal, the pilot going for every module caught 106 of 195. The pilot that
ignores them caught 45 of 204 just by standing in the way.

**It moves the curve by less than this bench can see, and that is the finding,
not a failure to find one.** Every row is within a few percent of the others.
Doubling the drop rate to 1 in 10 gave the same picture. The shield already
takes about 85% of the hits — 33 of 38 on Normal — so a refill saves perhaps a
leak or two a run. What ends a run is attackers crossing the line: 9 breaches
at 18 against 5 leaks at 10. And leaving your column to catch a module is
exactly how an attacker gets past. The refill and the column it cost come out
roughly even. That is a real choice with no dominant answer, and it is why the
difficulty table did not need re-tuning.

**The alternative that was benched.** Since breaches decide runs, a module that
armed a barrier on the line — stop the next attacker to cross — was tried
instead of the refill. It did little more: Normal came out 371 / 353 / 350 s for
the ignoring, empty-only and below-50 pilots against 348 before, and Easy and
Hard moved by under 3%. The best of that is the *ignoring* pilot, catching
modules by accident, which says more about noise than about the barrier. It was
not worth a second meaning for "shield", so the refill shipped. If play shows
the module is too slight to notice, the barrier, or a higher drop rate, are the
two measured levers.

What no pilot here does is manage the shield — none of them breaks contact to
let it recover, which a person does. A player who plays the shield will value a
refill more than these pilots can, and nothing here measured that.

## The lander, October 2026

The title's own idea from the menu of features for the other eight titles,
*a carrier that lands attackers*. The carrier wave above already delivers its
wave from a bay, so this is the other reading of the line: a craft that
**lands** its attackers well down the field instead of letting them walk in.
It was built to ask the opposite of what the carrier asks. The carrier is
slow, far away and tough, and its threat is a steady drip. The lander is fast,
close and fragile, and its threat is one burst, put down in the middle of the
field.

- **When.** On waves 3, 8, 13 and every fifth wave after, two before each
  carrier, 3 seconds into the wave.
- **Where.** It aims at the *mirror* of the defender's column at the moment it
  launches (clamped 120px off the walls), dives at 150 px/s to y 380, and
  unloads there. The spot is marked with blinking corner brackets from the
  moment it launches, and it sits on the side of the field you are not on, so
  getting under it means leaving the column you were holding.
- **What.** A squad of 3, one more every other lander, to 5, put down side by
  side 44px apart so one burst of fire cannot take them all. The squad comes
  **out of** the wave's count: a lander wave sends the same number of
  attackers as any other, some of them starting 300px closer to the line.
  A harder wave, not a longer one.
- **The answer.** 6 rounds (2 more each lander, with its hits left shown as
  pips under it) bring it down before it lands, for 150 plus 40 an attacker
  aboard, and the squad never arrives. It is in the air for about 2.8 s. Once
  it has unloaded it climbs away and cannot be hit: nothing aboard, nothing to
  deny.

**Nothing about it is random.** Its x is the player's, reflected, and it
draws nothing from `$rng`. The squad's attackers roll their kinds as the drip
would have. **Waves 1-2 replay the engine without a lander byte for byte**:
random flying through both engines on all three settings, 108,000 frames,
gave identical memory over the old 2,224 bytes and every old reader until
wave 3.

### What it costs, and what shooting it is worth

The carrier bench's pilot, 200 ms late, 16 seeds a setting: on the engine
without landers; on this one, ignoring the lander; and on this one, going
under a loaded lander and shooting it unless an attacker is already below
y 480. All three shoot the carrier first, as the better carrier pilot did.
Sector lost on the wave, mean:

| | Wave 3 | Wave 8 | Wave 13 | Landers brought down | Median survival |
|---|---|---|---|---|---|
| Easy, no landers | 0.0 | 2.3 | 2.9 | — | 520 s |
| Easy, lander ignored | 0.0 | 11.9 | 21.0 | 0 / 79 | 470 s |
| Easy, **lander first** | 0.0 | **4.5** | **12.5** | 33 / 82 | 462 s |
| Normal, no landers | 0.0 | 4.2 | 16.8 | — | 346 s |
| Normal, lander ignored | 3.4 | 10.3 | 42.2 | 1 / 51 | 312 s |
| Normal, **lander first** | **1.3** | 10.3 | **29.7** | 32 / 50 | 314 s |
| Hard, no landers | 0.0 | 15.9 | 20.0 | — | 212 s |
| Hard, lander ignored | 3.4 | 22.9 | — | 1 / 38 | 209 s |
| Hard, **lander first** | **1.1** | **12.4** | 39.0 | 24 / 35 | 208 s |

**Ignored, a lander wave costs from one and a half to seven times what the same
wave cost without one.** The squad lands 300px closer to the line than a walking
attacker starts, and on the side of the field the defender is not covering.
**Shooting it first gets most of that back**, and on Hard's wave 8 more than
all of it. What it does not do is lengthen the run for this pilot: landers
take about 30-50 s off a run on Easy and Normal whichever way it plays them,
and nothing measurable on Hard, where the runs end before the second lander
matters. Its rule gives up the lander whenever an attacker is low, which by
wave 13 is most of the time. It brought down about two landers in three on
Normal and Hard, and two in five on Easy.

The difficulty table was not re-tuned for it. A lander wave is a spike with a
decision in it, like the carrier's, and runs end within a minute of where
they did.

**What the bench cannot tell you** is what the brackets do for a person. The
pilot reads the lander's position; a player reads the spot, and the spot says
where the squad will be three seconds from now, which is what decides whether
to chase the lander or get ready for what it brings.

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
