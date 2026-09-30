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
game.getState();   // { score, scrap, core, level, phase, kills, leaks, gameOver, paused, difficulty }
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

| Action | Desktop | Mobile |
|---|---|---|
| Choose a tool | 1 / 2 / 3 / 4, or the toolbar | the toolbar |
| Place or sell | click a square | tap a square |
| Upgrade a tower | click it with any build tool; the tool's label shows the price | tap it with any build tool |
| Sell without switching tool | right-click | — |
| Call the wave in early | Space, or the SPACE button | the SPACE button |
| Purge every gun's heat | 5, or the PURGE button | the PURGE button |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |
| Pause | P or Esc; losing focus too | the PAUSE button; tap the board to resume |
| Restart | R | tap the GAME OVER text |
| Mute | M | the SOUND button |

**Gamepad**, standard mapping, adapted to a game that builds rather than steers:
the left stick or d-pad walks the cursor a square at a time (a first step, a
pause, then a faster run — a held arrow key's rhythm, because one flick of a
stick would otherwise cross the board), `A` builds with the selected tool, `B`
sells, `X` cycles the tool, `Y` calls the wave in early, `Start` pauses, `Back`
restarts, a shoulder button mutes, and the left trigger purges. Restart is `Back` alone here, unlike the
other titles, because `Y` is worth more as "send the next wave" on a board where
waiting is a decision. It is polled once a frame rather than listened for,
because `getGamepads()` only refreshes its snapshots when called.

Pause is the widget's, not the engine's: the engine advances by whatever `dt` it
is handed, so pausing is the loop not calling `step` while it goes on drawing
the frozen board. See [chapter 15](../../docs/15-game-loop-architecture.md).

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
  a damper 2, a hauler 3, a leader 5. Zero ends the run.
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
- **Upgrade a tower in place, twice.** Click one of your towers with any
  build tool. Each tier adds 15% to what it does (damage, or a vent's
  cooling) and nothing to its heat, for 4× the tower's cost and then 8×. Gold
  pips on the tower show its tier. Selling refunds 65% of everything spent on
  it. See [Upgrades](#upgrades-september-2026).
- **The purge: once a wave, buy every gun's heat back.** While a wave is
  walking, it vents every tower to zero heat and clears every trip, for
  20 scrap plus 10 a wave (70 on wave 5, 220 on wave 20). It refreshes when
  the wave is cleared and is refused in the build phase, when guns cool on their
  own. See [The purge](#the-purge-september-2026).
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
| ⬢ | **Leader** | 120 | 56 | 5 | armour takes 8 off every hit; anything within 90px walks at its pace; every fifth wave |

Health scales at +26% a wave (the leader's too), which is deliberately gentle: this is a game
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
| grid | 0 | 4 B | 192 | byte 0 kind (0 open, 1 path, 2 core), byte 1 tower index+1, byte 2 path step, byte 3 tier (0-2) |
| towers | 768 | 40 B | 28 | x, y, kind, heat, cd, active, aimX, aimY, tracer, tripped |
| enemies | 1888 | 40 B | 40 | x, y, hp, maxHp, kind (0 crawler, 1 sprinter, 2 hauler, 3 damper, 4 leader), active, step, t, flash, spare |
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
is_leader_wave(level) · get_leader_reach()
get_leaders() · get_leader_kills() · get_clinks()
can_purge() · get_purge_cost() · get_purge_ready() · get_purges()
can_upgrade(col, row) · get_upgrade_cost(col, row) · get_upgrades()
```

`verb` is 0 none, 1-3 build pylon/mortar/vent, 4 sell, 5 call the wave, 6 purge, 7 upgrade the tower on (col, row).

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
| `$LEADER_EVERY` / `$LEADER_HP` / `$LEADER_ARMOUR` | the boss: how often, health before scaling, flat damage off every hit | 5 / 120 / 8 |
| `$LEADER_SPEED` / `$LEADER_REACH` | its pace, and the radius that walks at it | 56 / 90 |
| `$PURGE_BASE` / `$PURGE_PER_LEVEL` | the purge's price, and how it rises | 20 / +10 a wave |
| `$TIER_MAX` / `$TIER_GAIN` / `$UPGRADE_MUL` | upgrades: how many, what each adds, price per tier as a multiple of the tower's cost | 2 / +15% / ×4 |
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
| kinds in play | crawler from 1, sprinter from 2, hauler from 4, damper from 6; a leader every fifth wave |

The health row, the core, the starting scrap and the wave bonus are the
**Normal** column of the difficulty table rather than fixed constants. See
below.

## Difficulty, September 2026

Three settings, picked with the HUD button or
`mount(el, { difficulty: 'hard' })`. The table lives in the engine:
`set_difficulty(d)` records the choice (0 easy, 1 normal, 2 hard) and `init()`
applies it, so a setting never changes halfway through a run.

| | Easy | Normal | Hard |
|---|---|---|---|
| Core integrity | 30 | 20 | 14 |
| Starting scrap | 130 | 95 | 75 |
| Enemy health, per wave | +18% | +26% | +34% |
| Wave bonus | 24, +3 a wave | 24, +2 | 20, +1.5 |

The two knobs the backlog named were **starting scrap** and **wave strength**.
Wave strength is the *health* multiplier rather than the head count, and that
was a choice. More enemies at the same spacing is a longer wave, and here a
longer wave is also a thinner one — finding 4 above is what happened last time
a wave got strung out: heat stopped mattering. Health keeps the wave the same
shape and asks every gun to fire for longer, which is the question this game is
built to ask.

The other two rows are there because the first knob, on its own, would not
last. Core integrity is this game's lives, and every other title's table moves
that number. The **wave bonus** is in the table because the economy is the
curve this game actually runs on — finding 4 again, where inflated money made
every strategy converge. Starting scrap is a one-off gift that ten waves of
income swamp; the bonus is the *rate*, and a setting that moved the gift and
not the rate would stop mattering by wave five.

**Four things are deliberately not in the table.** The heat numbers are the
mechanic, not the difficulty: finding 2 — that a vent pays only when it cools
something worth running — is a property of those ratios, and a setting that
moved them would be a different game with the same art. Tower costs stay put
for the same reason; pylon:vent at 20:15 is what makes a vent a real trade.
The spawn spacing stays put because it is what makes a wave a wave. And the
build clock stays put, because calling a wave early pays the remaining seconds
as scrap: a longer clock on Easy would be a bigger bonus for skipping it — the
economy knob again, by the back door.

**Normal is the previous balance exactly.** The same input replayed through the
committed engine and this one — random squares, random tools, sells and early
calls — gave byte-identical memory across the whole 5,216-byte layout and all
twenty-one readers on every frame, over 54,000 frames, re-initialising on each
game over. Normal's bench rows below also reproduce findings 1 and 2 to the
wave, which is the same check from the other direction.

Benched with the two pilots from findings 1 and 2: the **bad pilot** (a pylon on
the first buildable square in reading order, nothing else, never calls a wave)
and the **mixed pilot** (pylon, pylon, mortar, vent, repeating, same placement
rule). Every engine seeds its route and waves identically, so each row is the
same board against the same waves:

| | Bad pilot: waves cleared | Mixed pilot: waves cleared | Mixed: score |
|---|---|---|---|
| Easy | 14 (443 s) | 21 (670 s) | 9,222 |
| Normal | 10 (326 s) | 17 (574 s) | 6,990 |
| Hard | 5 (155 s) | 13 (458 s) | 4,878 |

The bad pilot on **Hard still clears five waves**, so the level-3 bar holds on
every column. And the mixed pilot's lead over the bad one — seven, seven and
eight waves — is roughly the same on all three, which is the check that the
table made the *game* harder rather than making finding 2 go away: a heat plan
is worth about the same number of waves at every setting.

**What an instrumented run shows, and why it is not the Sector Defense
problem.** Tracing the core wave by wave, it sits full until late on every
column — then gives way over three or four waves. Sector Defense's table had the
same shape and was wrong, because its columns only separated in that last
minute. Here they separate in *when* the collapse comes: wave 13, 9 and 5 for
the bad pilot. A tower defence that loses nothing until it loses everything is
the genre working as intended — a leak is a defence that has already failed —
and the table moves the failure point rather than the shape of it.

### What placement is worth

Both pilots above build in the first free square next to the track. To price a
*good* square, the mixed pilot's build order (pylon, pylon, mortar, vent,
repeating, never calling a wave) was kept exactly and only the square choice
changed. A gun goes where the most route squares fall inside its reach, plus a
bonus for sitting beside a vent. A vent goes where it touches the most guns,
with pylons counted double because they run hotter. The route and the waves
come from the seed, so the seed was rewritten to get **24 boards per setting**:

| Waves cleared: worst / median / best | Reading order | By coverage | Gained (median) |
|---|---|---|---|
| Easy | 17 / 20 / 24 | 26 / **33** / 45 | +13 |
| Normal | 12 / 16 / 18 | 20 / **24** / 30 | +8 |
| Hard | 12 / 14 / 16 | 16 / **19** / 24 | +5 |

**Where you put a tower is worth more than which tower you put there.** The
heat plan (mixing in mortars and vents) is worth seven or eight waves on every
setting. Placement is worth thirteen on Easy and eight on Normal on top of it,
and the worst coverage board beats the best reading-order board on Easy and
Normal. This is the skill a player brings that no setting touches. It also
means the bad-pilot figures above say little about a player who looks at the
route before building, and more about one who does not.

It shrinks with the setting (+13, +8, +5). Why was not measured; faster health
growth leaving less time for a good square to pay is the obvious guess, and
only a guess. The reading-order pilot here uses a
slightly different "next to the track" rule from the one in the table above:
on the README's own board it matches Easy and Normal to within a wave (20 and
18 against 21 and 17) but gets only 6 on Hard, not 13. The comparison is still
like for like, because both columns use the same build order on the same 24
boards.

**Still not covered: selling.** No pilot here sells or re-places a tower, so
what the 65% refund buys is unmeasured.

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and Easy and Hard get `tower-defense:easy` and `tower-defense:hard`.

## The leader, September 2026

TASKS.md's boss-wave idea for this title was *"an armoured leader among the
damper wave"*. On every fifth wave the enemy in the middle of the wave is a
**leader**. Its base health is 120 before the wave's scaling (245 on wave 5,
401 on wave 10, 557 on wave 15). It walks at 56 px/s, costs 5 core if it gets
through, and pays 50 scrap and 250 score. It does two things nothing else does:

- **Armour.** Every hit loses a flat 8. A pylon's 9 becomes 1 and a mortar's
  26 becomes 18. A pylon still heats at the full rate, so a row of pylons
  spends its heat on the leader for a ninth of the damage.
- **An escort.** Any enemy within 90 px of it walks no faster than it does, so
  the wave bunches up around it on the way in. The ring is drawn at the radius
  the engine checks.

The build phase announces it — "BUILD 12s · LEADER" — from
`is_leader_wave(level)`, because a boss you could only learn about by losing to
it is not one you can build for. Its kind is drawn from the random stream as
usual and then replaced, so the draw sequence, and every wave's make-up, is the
one the game had before. Replaying random input through the committed engine
and this one gave byte-identical memory, score, scrap and core on every frame
up to wave 5, on all three settings.

### What the bench found

The three pilots from the Difficulty section: **bad** (pylons in reading order),
**mixed** (pylon, pylon, mortar, vent in reading order) and **placed** (the same
order, placed by coverage). 24 routes each on Normal, waves cleared as
worst / median / best:

| | Before | With the leader | Leaders killed: wave 5 · 10 · 15 · 20 |
|---|---|---|---|
| Bad | 9 / 10 / 12 | 9 / 9 / 12 | 23/24 · 2/6 · — · — |
| Mixed | 11 / 15 / 17 | 11 / 14 / 17 | 24/24 · 23/24 · 6/8 · — |
| Placed | 19 / 23 / 29 | 17 / 22 / 29 | 24/24 · 24/24 · 23/24 · 10/19 |

(A dash means no run got that far.) On Easy and Hard the medians moved by one
wave or less, except Easy's placed pilot, which lost two (32 to 30). The bad
pilot on Hard did not move at all (8). **The leader costs
about one wave of run length.** It is a step in the curve, not a wall. The
first leader is a warning that almost every board survives. The second is where
a board of nothing but pylons stops getting through it: 2 kills out of 6
against the mixed board's 23 of 24.

**Switching each half off in turn** showed which half does what. On Normal:

| | Bad: wave-10 leader | Placed: wave-15 leader | Placed: wave-20 leader |
|---|---|---|---|
| Armour and escort (as shipped) | 2/6 | 23/24 | 10/19 |
| Armour, no escort | 1/17 | 20/24 | 5/18 |
| Escort, no armour | 19/20 | 24/24 | 22/22 |
| Neither | 12/18 | 23/24 | 19/20 |

**The armour is the threat.** Without it the leader is a slow hauler, and even
the pylons-only pilot kills it 19 times in 20. **The escort is the leader's
weakness.** Without it the leader was killed *less* often, not more. A wave held
to 56 px/s spends longer in reach of every gun, and a bunched wave is what a
mortar's splash is for. It was meant as pressure — a bunched wave is the one
that asks guns to fire without stopping — and the bench says the defender comes
out ahead. It stays anyway, because it points the same way as the armour: the
leader asks for mortars twice, once to get through the plate and once for the
crowd it gathers. And "the wave walks at the leader's pace" is what makes it a
*leader* rather than a large hauler.

**Lighter and harder-plated beat the first draft.** The draft was 240 health
behind 6 armour. Against it the placed pilot killed 11 of 16 wave-15 leaders
and 2 of 9 on wave 20. At 120 and 8 that became 15 of 16 and 4 of 11, with the
pylons-only board no better off. A boss that dies to a well-built board and
not to a big one tests what you built rather than how much.

One thing the bench cannot say is whether the announcement lands. None of these
pilots reads the HUD. A player who sees "LEADER" and builds a mortar the wave
before should do better than any row here, and nothing measured that.

## The purge, September 2026

TASKS.md's power-up idea for this title was *"a bought one-shot ability rather
than a pickup, since nothing there flies over the board to collect"*. There is
one, and it is about heat.

**PURGE** (5, the toolbar button, or the left trigger) vents every gun on the
board to zero heat and clears every trip, at once. It costs **20 scrap plus 10
a wave**. It can be used **once a wave**, refreshes when the wave is cleared,
and works only while a wave is walking. In the build phase every gun cools on
its own, so a purge there would be scrap thrown away. The engine refuses it,
and the button reads as unavailable, rather than letting a player learn that by
paying for it.

It is the heat system's answer to itself. Dampers and the leader attack heat,
not towers, and until now the only defence against that was built in advance:
a vent, placed before you knew where the pressure would land. The purge is the
same relief bought at the moment you need it, and it costs what everything here
costs, which is scrap that is not a tower. The button shows the current price
from `get_purge_cost()`, because the price moves.

A run that never purges is the game it was before. Replaying random builds,
sells and early calls through the previous engine and this one gave
byte-identical memory, score, scrap and core over 180,000 frames per setting,
re-initialising on every loss.

### What the bench found

The pilots from the leader bench (bad, a pylons-only board placed by coverage,
mixed and placed), each flown without the purge and then with a rule: purge when
at least 40% of the guns are tripped and it can. Waves cleared, worst / median /
best:

| | Never purges | Purges | Purges per run |
|---|---|---|---|
| Normal, pylons only | 9 / 9 / 12 | 9 / 9 / 13 | 3.0 |
| Normal, mixed | 11 / 14 / 17 | 12 / **16** / 19 | 5.5 |
| Normal, placed | 17 / 22 / 29 | 19 / **24** / 33 | 6.0 |
| Easy, placed | 28 / 31 / 39 | 30 / **36** / 41 | 11.8 |
| Hard, placed | 14 / 17 / 19 | 15 / **18** / 21 | 4.7 |

(24 routes on Normal, 12 on Easy and Hard.) **It is worth two waves to a board
with mortars on it and nothing to a board of pylons.** That is this README's
second finding again, from the other side: cooling pays only when it keeps
something worth running firing. A pylon trips and recovers on its own
rhythm; a mortar that trips mid-wave is a big gun silent for most of the wave.
The purge rewards the same board the vent does, and it does not rescue the one
the vent cannot.

**The price rises with the wave because a flat one stopped being a price.**
The first version cost a flat 30, and 30, 45, 60 and 80 all bought *exactly* the
same waves. The trace showed why. These pilots fill all 28 slots by wave 9, and
from then on they bank 150-190 scrap a wave with nothing to spend it on — 1,900
by wave 19 on one route. By the time the purge was wanted, it was free. 20 + 10 a
wave is three pylons on wave 5 and about one wave's income by wave 20. 20 a wave
and 30 a wave were benched too. They mostly priced it out of the middle of the
run (1.2 and 0.8 purges a run for the pylon board, 3.2 and 1.9 for the mixed
one), and the middle is where the choice against a tower is the interesting one.

**A finding the purge turned up about the game underneath it.** Once the board
is full, money stops being the thing you do not have. The note above
`$enemy_bounty` says it must stay scarce, and it does, for eight waves. These
pilots never sell and rebuild, which a person might, but a hoard of a thousand
scrap by wave 15 is not scarcity for anyone. The purge was, for a while, the only sink for
it. Upgrades, below, are the answer that shipped: they give a full board
something to buy, and the hoard is gone.

## Upgrades, September 2026

TASKS.md listed this as the title's own idea: *upgrade a tower in place*.

Click one of your towers with any build tool (on a gamepad, `A` over it) and
it goes up a tier, to a maximum of two. Each tier adds **15%** to what the tower
does: a gun's damage, or a vent's cooling. It adds **nothing to heat**, because
a gun heats by the shot, not by the damage. So an upgrade is more damage per
degree, the one thing this game is really short of. The first tier costs **4×**
the tower and the second **8×**: 80 and 160 for a pylon, 180 and 360 for a
mortar. Selling refunds the usual 65% of everything spent, upgrades included.
Two gold pips on a tower show its tier, and over one of your towers the
selected build tool's label changes to the upgrade price, or "fully upgraded".

There was no new toolbar button. The bar already holds six, and a build tool
on your own tower had no other meaning — before this it was simply refused.

**Why in place.** The board holds 28 towers, and the bench's pilots fill it by
wave 9. From then on the only way to make a board stronger was to sell a tower
at a 35% loss and build a better one on the same square, so scrap piled up with
nothing to buy. The purge's notes record 1,900 banked by wave 19. An upgrade is
what a full board spends money on.

The tier lives in the grid cell's spare byte, not in the tower record, whose
forty bytes are full. Widening the record would have moved every pool after
it, and a tower never leaves its cell. A run that never upgrades is the game it
was: 180,000 frames per setting of random builds, sells and early calls gave
identical memory, score, scrap and core against the engine without upgrades.

### What the bench found

The mixed and placed pilots from the leader bench, flown as before and then
again with an upgrade rule: once all 28 slots are full, upgrade whenever it
can, mortars first, then pylons, then vents, lowest tier first. 12 routes,
waves cleared (worst / median / best), and the scrap left when the run ended:

| | Never upgrades | Upgrades | Scrap left: before → after |
|---|---|---|---|
| Normal, mixed | 11 / 14 / 16 | 11 / 14 / 17 | 1,022 → 59 |
| Normal, placed | 19 / 21 / 28 | 20 / **25** / 35 | 2,356 → 104 |
| Easy, placed | 28 / 31 / 39 | 35 / **43** / 54 | 4,975 → 98 |
| Hard, placed | 14 / 17 / 19 | 15 / **18** / 22 | 1,395 → 39 |

**Money is scarce again.** Every setting's board now ends the run with a
hundred scrap or less instead of a hoard, which is what the note above
`$enemy_bounty` says the economy is for. The mixed pilot reaches the tower
cap late and so gains least. Easy gains most, because Easy's wave bonus pays for
every upgrade on the board.

**The numbers are small because damage per degree is worth so much.** Every
larger version benched ran away with the game on Normal's placed board:

| Per tier | Tiers | Price per tier | Placed board, Normal | Scrap left |
|---|---|---|---|---|
| +50% | 2 | ×1.5, ×3 | 21 → **49** waves | 5,721 |
| +20% | 2 | ×1.5, ×3 | 21 → 35 | 2,233 |
| +20% | 2 | ×4, ×8 | 21 → 28 | 186 |
| +25% | 1 | ×3 | 21 → 29 | 1,989 |
| +30% | 1 | ×4 | 21 → 30 | 1,494 |
| +10% | 2 | ×4, ×8 | 21 → 24 | 185 |
| **+15%** | **2** | **×4, ×8** | **21 → 25** | **104** |

The first draft more than doubled the run and still left thousands unspent.
A single larger tier also left the hoard behind, because 28 upgrades were not
enough to spend it. Two small tiers at a steep price is the version that both
moves the board and empties the bank, and +15% a tier is the least that a
player can still see in a tower's output.

What no pilot here does is choose *which* tower to upgrade with any thought.
The one that sees the most route, or the mortar a vent is already cooling, is
worth more than the next one in the list. A player who picks will do better
than the rule above, and nothing here measured that.

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
