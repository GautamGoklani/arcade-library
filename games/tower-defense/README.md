# Tower Defense Lite

A generated route across a sixteen-by-twelve board, a core at the end of it,
and a wave walking. You do not steer anything: you decide where boxes go, and
then you watch. All of it — the route generator, the towers, the heat, the
economy — is hand-written in WebAssembly Text (`game.wat`) and runs as a
compiled `.wasm` binary. JavaScript forwards a square and a verb, calls
`step(dt)`, and draws what it finds in the engine's linear memory.

Works on **desktop (click, keys 1-4, space)** and **mobile (pick a tool, tap a
square)**.

Open [`index.html`](index.html) to play it.

## The idea: heat, not money, is the resource

Scrap runs out and comes back. **Heat runs out inside the wave you needed it.**

Every gun tower heats as it fires, trips at 100, and refuses to fire again
until it has cooled back to 40. A pylon makes 50 heat a second while firing, so
on its own it manages about two and a half seconds before it trips and then
sits out nearly seven — a duty cycle of roughly a quarter. Which means a block
of eight pylons does not deliver eight guns' worth of anything. It delivers
eight guns for two seconds and then a hole in the line, and the wave walks
through it.

The answer is the **vent**: it shoots nothing, and it cools every tower in the
eight squares around it. One vent in reach roughly triples what a gun
delivers — and every vent is a gun you did not build, on a board that only
allows twenty-eight towers. That trade is the game.

The rest follows from it. There is one enemy, the **damper**, whose whole
attack is to add heat to the towers it walks past: the only thing in this
library that attacks a resource rather than a hit-point total, and the only
one whose counter is *where you built* rather than what you built.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.td-` — no other game may use that prefix),
its own sprite pipeline and its own synthesised sound. What it takes from the
other engines is *conventions*, copied by hand: a globals block at the top of
the `.wat`, entity pools at fixed offsets, an xorshift RNG, monotonic event
counters, and an `init` / `set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` verifies all nine committed binaries in one pass.

At **5,124 bytes** this is the largest engine in the library, which is what
happens when the interesting state is a board rather than a position.

### It has no imports

Like [Worm Chase](../worm-chase/), [Sector Defense](../sector-defense/),
[Circuit Runner](../circuit-runner/) and [Starfield Runner](../starfield-runner/):

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

Towers range-check with a distance and shells fly along a normalised vector,
and both of those are `f32.sqrt`, which is an instruction. Nothing in the
engine needs an angle — the widget works the barrel direction out from the
tower's stored aim point, because that is a drawing question.

## Files

```
tower-defense/
├── tower-defense.js   ← the widget (engine embedded inside) — REQUIRED
├── tower-defense.css  ← scoped styles (.td-*)               — REQUIRED
├── game.wat           ← engine SOURCE — edit to change gameplay
├── game.wasm          ← compiled engine (also embedded in the .js as base64)
├── index.html         ← standalone page: the game and nothing else
├── demo.html          ← minimal working integration example
├── logo.svg           ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`tower-defense.js` and `tower-defense.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="tower-defense.css">

<div id="game"></div>

<script src="tower-defense.js"></script>
<script>
  var game = TowerDefense.mount('#game');
</script>
```

### JavaScript API

```js
var game = TowerDefense.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, scrap, core, level, phase, kills, leaks, gameOver }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.

## Controls

| Action | Desktop | Mobile |
|---|---|---|
| Choose a tool | 1 / 2 / 3 / 4, or the toolbar | the toolbar |
| Place or sell | click a square | tap a square |
| Sell without switching tool | right-click | — |
| Call the wave in early | Space, or the SPACE button | the SPACE button |
| Restart | R | tap the GAME OVER text |
| Mute | M | the SOUND button |

The toolbar is real DOM buttons rather than a palette painted onto the canvas,
and that is deliberate: they are the only part of this game that is a *tool*
rather than a picture. They have to be reachable by keyboard, they have to say
what they cost, and they have to be able to look unaffordable — three things
HTML does for free.

**The selected tool is the one piece of state the widget owns.** It is a
property of the pointer, not of the board: the engine is told a square and a
verb and has no opinion about which button is lit. Everything else, including
whether a square can be built on, is asked of the engine — the cursor calls
`can_build` rather than working it out, so what the cursor promises and what a
click does are the same sentence.

## Gameplay rules

- **The core has 20 integrity.** A crawler or sprinter that reaches it costs 1,
  a damper 2, a hauler 3. Zero ends the run.
- **Twenty-eight towers, ever.** Not a memory limit — a game rule. See the note
  under Tuning.
- **Build phase, then wave.** The build clock starts at 14s and shortens by
  half a second a level, to a floor of 8.
- **Calling the wave in early pays.** Unspent build seconds convert to scrap at
  3 a second, and to score at 6. A timer with nothing happening in it is dead
  time, and this repository has a rule about that; making the wait purchasable
  turns it into the only decision in the loop that is not about where to put a
  box.
- **Selling returns 65%.** Not all of it, or the board can be rearranged for
  free between waves and placement stops being a commitment.
- **Towers shoot the enemy furthest along the route** in reach, not the nearest
  one. The nearest is by definition the one with the most board left to walk,
  so shooting it wastes every tower behind you.
- **Score counts the core you kept.** 25 a point, added at the end — without it
  there is no difference between surviving a wave by ten and surviving it by
  one, and defending well would score the same as defending barely.

### The three towers

| | Tower | Cost | Reach | What it does | Heat |
|---|---|---|---|---|---|
| ▮ | **Pylon** | 20 | 132 | 9 damage every 0.26s, hitscan | 13 a shot — 50/s while firing |
| ◎ | **Mortar** | 45 | 210 | a shell to where the target *was*, 26 damage in a 62px splash | 33 a shell — 22/s while firing |
| ▦ | **Vent** | 15 | 92 | nothing. Cools every tower in reach by 20/s | none |

The pylon is hitscan on purpose. At 132px of reach and a quarter-second reload
a travelling bullet would spend most of its life in the air and miss a sprinter
that had already left, which reads as the tower being broken rather than
outrun.

The mortar is the reverse: its shell lands **where it was aimed**, not on
whoever it touches on the way. That makes the splash a placement decision the
player can read, and it is exactly why a mortar misses a sprinter — which is
the sprinter's whole job.

The vent's 92px reaches the eight neighbouring squares and nothing else: 60
orthogonal, 85 diagonal, 120 two squares out. So its rule is one a player can
see on the grid rather than one they have to be told.

### The four enemies

| | Enemy | HP | Speed | Core cost | Role |
|---|---|---|---|---|---|
| ● | **Crawler** | 26 | 96 | 1 | the baseline; from wave 1 |
| ▲ | **Sprinter** | 16 | 172 | 1 | punishes a *gap* in coverage; from wave 2 |
| ■ | **Hauler** | 92 | 62 | 3 | punishes not having *enough* coverage; from wave 4 |
| ◆ | **Damper** | 46 | 84 | 2 | adds 21 heat/s to every tower within 145px; from wave 6 |

Health scales at +26% a wave, which is deliberately gentle: this is a game
about coverage, and health inflation is the cheapest and least interesting way
to ask for more of it.

## The route, and why it cannot fail

Every board is generated. The construction is what makes it safe, rather than a
check afterwards:

> **Columns are only ever entered left to right, and within a column the route
> runs in one vertical direction.**

A square therefore cannot be visited twice, the route cannot enclose anything,
and it always terminates — none of which needs a validity test, a retry loop,
or a search. A random walk *with* a retry loop was the first version and it did
work; it was replaced because "generate and check" is a shape that eventually
fails to terminate on some seed nobody has tried yet, and there is no way to
know which seed that is. This is the same reasoning
[chapter 21](../../docs/21-generated-worlds.md) applies to Circuit Runner's
board, arrived at from a different direction.

Two other things about the generator are legibility rather than difficulty.
Vertical runs are capped at two squares, and the direction is kept three
columns in four. Runs of up to three with a fresh coin toss each column
produced routes that were perfectly valid and looked like a car park: a column
going down three next to one going up three puts eight track squares in a
two-by-four block, and there is no route to see in that.

**And the widget draws a rut down the middle of it.** Colouring the track
squares is not enough where the route doubles back — the squares abut and read
as an open yard. The rut joins consecutive path cells *in the order the engine
stored them*, which is the thing the enemies actually follow, so the route
stays legible without the generator having to make duller routes to be
readable.

## Architecture

```
tower-defense.js ── set_input(col, row, verb) ──▶  game.wasm  (all simulation state)
        ▲                  step(dt)                    │
        └──── reads the grid + pools + get_*() ◀───────┘
```

**JavaScript owns no game state** — not the scrap, not the wave clock, not
whether a square can be built on. It forwards a square and a verb, calls
`step(dt)`, and walks the grid and the pools to draw them.

The verb is **edge-triggered and consumed on the frame it arrives**: `step`
reads `inAction` and immediately clears it, so a held mouse button cannot lay a
row of towers, and the widget does not have to remember whether it already
sent this click.

The engine never calls out. It exposes **monotonic event counters**
(`get_builds`, `get_sells`, `get_shots`, `get_booms`, `get_kills`, `get_leaks`,
`get_trips`, `get_waves`, `get_refused`) and the widget diffs them between
frames to decide what to play and what to shake. `get_refused` is the one worth
pointing at: a build the rules would not allow is an *event*, so the click that
does nothing still makes a noise, and the engine is the thing that decided it
did nothing.

### WASM linear memory layout

| region | offset | stride | count | fields |
|--------|--------|--------|-------|--------|
| grid | 0 | 4 B | 192 | byte 0 kind (0 open, 1 path, 2 core), byte 1 tower index+1, byte 2 path step |
| towers | 768 | 40 B | 28 | x, y, kind, heat, cd, active, aimX, aimY, tracer, tripped |
| enemies | 1888 | 40 B | 40 | x, y, hp, maxHp, kind, active, step, t, flash, spare |
| shells | 3488 | 32 B | 24 | x, y, vx, vy, tx, ty, active, dmg |
| path | 4256 | 8 B | 120 | px, py — the world centre of each route square, in order |

Total 5,216 bytes of a single 64 KiB page. Scrap, core integrity, the level and
the phase clock are globals rather than memory, as in the other recent titles.

> **The widget hard-codes these offsets.** Change the layout in `game.wat` and
> `tower-defense.js` must change with it — nothing links them at build time,
> and the failure is silent. `npm run check` runs
> [`scripts/check-layout.mjs`](../../scripts/check-layout.mjs), which compares
> the named constants and the order of fields in every record — the `@fields`
> lines in the memory-map comment against the `FIELD` table in the widget. It
> cannot see the engine's own `offset=` loads, so the memory-map comment at the
> top of `game.wat` is still the schema to keep honest.
>
> This is not hypothetical here. Capping the tower pool at 28 moved every pool
> after it, and the throwaway bench harness — which had `PATH_OFF` written out
> as a literal — went on reading the old address and quietly reported that no
> tower had ever hit anything.

### Exports

```
init() · set_input(col, row, verb) · step(dt)
can_build(col, row, kind) · enemies_alive()
get_score() · get_scrap() · get_core() · get_core_max()
get_level() · get_phase() · get_phase_t() · get_build_time()
get_to_spawn() · get_wave_size()
get_cols() · get_rows() · get_cell() · get_path_len()
get_cost(kind) · get_range(kind) · get_splash() · get_heat_max() · get_early_rate()
is_game_over()
get_builds() · get_sells() · get_shots() · get_booms() · get_kills()
get_leaks() · get_trips() · get_waves() · get_refused()
```

`verb` is 0 none, 1-3 build pylon/mortar/vent, 4 sell, 5 call the wave.

## Findings from benching

Every number here came from driving the compiled engine headlessly from Node.
The RNG is seeded to a constant and is touched only by the route generator and
the wave composer, neither of which depends on what the player does, so **every
pilot below defended the identical board against the identical waves.**

### 1 · Level 1 is walkable by a pilot with no plan at all

The bad pilot builds a pylon on the first buildable square it finds in reading
order, next to the track, and does nothing else — no vents, no mortars, never
sells, never calls a wave.

| cleared | at | core |
|---|---|---|
| wave 1 | 17s | 20/20 |
| wave 2 | 34s | 20/20 |
| wave 3 | 52s | 20/20 |
| wave 4 | 71s | 20/20 |
| wave 5 | 90s | 20/20 |
| wave 6 | 130s | 20/20 |

It finally loses the core on wave 11, five minutes in. That is the bar this
repository sets — *if the bad pilot cannot reach level 3, a human is going to
have a bad time* — and it clears it with room.

### 2 · A vent is only worth a slot if it is cooling something worth running

This is the finding the design turns on, and it is not the one that was
expected. Each row is the same board, the same waves, and 28 tower slots spent
in a different ratio.

| what it built | wave reached | score | trips | leaks |
|---|---|---|---|---|
| pylons only | 11 | 3,324 | 120 | 9 |
| 2 pylons : 1 vent | 11 | 3,384 | 77 | 8 |
| 1 pylon : 1 vent | 11 | 3,300 | 53 | 10 |
| pylons + mortars | 15 | 5,436 | 154 | 7 |
| **pylons + mortars + vents** | **18** | **7,026** | 103 | 11 |
| the same, calling every wave in early | 18 | **7,514** | 94 | 11 |

Vents do exactly what they claim to: a third of the slots given over to them
cuts overheating by 40-60% in every single row. On a board of pylons that buys
**nothing at all** — the run still ends on wave 11 — because a pylon that is
running at full duty is still a pylon, and giving up a third of them to get
there is a wash. Add mortars, and the same vents are worth three whole waves.

The general shape of it is worth stating plainly, because it is not obvious in
advance: **support only pays for itself in proportion to what it is
supporting.** A cooling mechanic on cheap towers is a tax dressed as a choice.

### 3 · Calling the wave in early is free score

Same board, same build order, one difference: the pilot calls the wave the
moment it cannot afford anything else. It reaches the same wave — 18 — but
gets there in **410 seconds instead of 509**, and scores 7% more for it. That
is what the mechanic is for: the build clock is a floor on how slowly you may
play, and skipping it is a decision rather than a shortcut.

### 4 · Two tuning mistakes worth recording

**The economy inflated.** The first pass paid 5-11 scrap a kill on top of a
wave bonus that grew 7 a level. By wave 10 the bench sat on hundreds of unspent
scrap and by wave 20 on sixteen thousand, at which point the board fills up,
every strategy converges on "one of everything, everywhere", and none of the
choices this game is made of mean anything. Bounties are now roughly half, and
the wave bonus grows by 2.

**The wave was not a wave.** Enemies arrived 1.05s apart, which strung forty of
them over sixteen seconds along a fifty-square route. Any one gun had a target
in reach about eight percent of the time and tripped roughly once a minute:
overheating was real, measurable, and completely beside the point, and the
bench could not tell a board of guns from a board of guns and vents. Waves now
arrive 0.55s apart falling to 0.18. **Until a gun is asked to fire
continuously, cooling it is worth nothing** — which is obvious in hindsight and
took three rounds of tuning the wrong numbers to see.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$MAX_TOWERS` | the whole board's tower budget | 28 |
| `$COST_PYLON` / `$COST_MORTAR` / `$COST_VENT` | scrap | 20 / 45 / 15 |
| `$PYLON_DMG` / `$PYLON_RELOAD` / `$PYLON_HEAT` | the workhorse | 9 / 0.26s / 13 |
| `$MORTAR_DMG` / `$MORTAR_RELOAD` / `$MORTAR_HEAT` / `$MORTAR_SPLASH` | the crowd answer | 26 / 1.5s / 33 / 62 |
| `$VENT_RANGE` / `$VENT_COOL` | the eight neighbours, and by how much | 92 / 20 |
| `$HEAT_MAX` / `$HEAT_RESET` / `$HEAT_COOL` | trip point, resume point, passive cooling | 100 / 40 / 9 |
| `$DAMPER_RANGE` / `$DAMPER_HEAT` | the enemy that attacks the heat system | 145 / 21 |
| `$CORE_MAX` / `$START_SCRAP` | how much room a new player has | 20 / 95 |
| `$BUILD_TIME` / `$BUILD_TIME_MIN` / `$EARLY_RATE` | the quiet part of the loop | 14s / 8s / 3 |
| `$SELL_FRACTION` | what a tower is worth second-hand | 0.65 |

`$MAX_TOWERS` is a game rule, not a memory bound. At 40 the bench could
eventually fill every useful square, and once it can, a slot spent on a vent is
not a slot not spent on a gun — which is the trade the whole title rests on.

The difficulty curve, per wave:

| per wave | value |
|---|---|
| enemies | +2, from 5, capped at 34 |
| enemy health | +26% of the base |
| spawn spacing | −0.014s, from 0.55s, floored at 0.18s |
| build time | −0.5s, from 14s, floored at 8s |
| kinds in play | crawler from 1, sprinter from 2, hauler from 4, damper from 6 |

## Rebuilding the engine

```bash
npm install                     # wabt is a devDependency of this repo
npm run build:tower-defense     # game.wat -> game.wasm, re-embedded into the .js
npm run check                   # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `tower-defense.js` are both committed, so
a fresh checkout plays with nothing installed. `npm run check` is what stops
the three copies of the engine drifting apart.

## Browser support

Any browser with WebAssembly MVP and canvas 2D: Chrome/Edge 57+, Firefox 52+,
Safari 11+. The engine uses **strict MVP** — four value types, one 64 KiB page,
structured control flow, no post-MVP feature and no feature detection. Sound
needs Web Audio and is created on the first input, because browsers refuse to
start audio outside a user gesture; without it everything else still works.
