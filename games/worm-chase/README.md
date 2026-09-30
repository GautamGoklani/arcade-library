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
game.getState();   // { score, lives, level, owned, target, total, gameOver, paused, difficulty }
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

| Action  | Desktop                   | Mobile                 |
|---------|---------------------------|------------------------|
| Move    | hold ← ↑ → ↓ or W A S D   | hold and drag anywhere |
| Stop    | let go                    | lift your thumb        |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |
| Pause   | P or Esc; losing focus too | the PAUSE button; tap the board to resume |
| Restart | R                         | tap the GAME OVER text |
| Mute    | M                         | the SOUND button       |

**Gamepad**, standard mapping, no setup: left stick or d-pad steers — one axis
at a time, since the worm turns on a grid — `Start` pauses, `Back` or `Y`
restarts, a shoulder button mutes. It is polled once a frame rather than
listened for, because `getGamepads()` only refreshes its snapshots when called.
Keys and the touch stick outrank it, so a controller resting in a drawer cannot
cancel a direction someone is holding.

Pause is the widget's, not the engine's: the engine advances by whatever `dt` it
is handed, so pausing is the loop not calling `step` while it goes on drawing
the frozen board. See [chapter 15](../../docs/15-game-loop-architecture.md).

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
- **The hunter.** Every fourth level one of the pack is a violet, horned
  **hunter**. Chasers go for your head; the hunter goes for your *trail*, the
  cell of it nearest to itself, so a long loop is what it punishes. Fence it in
  for 500. See [The hunter](#the-hunter-september-2026).
- **Capsules.** Every so often a capsule appears on open ground and fades after
  twelve seconds. Drive over it or **enclose it** to take it. The pale blue
  star is **freeze**: the chasers stop where they are for four seconds (a
  frozen chaser still kills on contact). The yellow bolt is **surge**: the worm
  moves 40% faster for five. Effects in force show as coloured squares beside
  LIVES, and end if you lose a life. See
  [Capsules](#capsules-september-2026).
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

### Drawn at 320×240

This title was retrofitted with the library's retro render treatment in
September 2026. It draws into a **320×240 buffer blown up 3× with smoothing off**,
with scanlines and a vignette in CSS (`.wc-scan`, dropped under
`prefers-reduced-motion`) and screen shake that moves in whole low-res pixels.
Two things had to go. The trail and the worm's head carried a `shadowBlur`
glow, which is the one effect that marks a picture as made after about 1995;
both are bright enough against the dark board without it. And the grid and the
territory outline were stroked lines, which is a smear at a third of a pixel
wide; both are one-pixel bars now, the outline drawn on the inside edge of each
owned cell.

The draw code was written at full resolution, so the snap to whole low-res
pixels lives in the adapter rather than at each call: the buffer's `fillRect`
and `drawImage` are wrapped to round their edges, and a one-pixel detail that
would round away keeps one low-res pixel. The engine did not change.

### WASM linear memory layout

| region  | offset | stride | count | fields |
|---------|--------|--------|-------|--------|
| grid    | 0      | 4 B    | 768   | `state`, `hazard`, `mark`, `epoch` — one byte each; cell (c,r) at `(r*32 + c)*4` |
| queue   | 3072   | 4 B    | 768   | the flood fill's BFS frontier, one `i32` cell index per slot |
| chasers | 6144   | 32 B   | 8     | cx, cy, pcx, pcy, dx, dy, active, kind (0 chaser, 1 hunter) (all `i32`) |
| capsules | 6400  | 24 B   | 2     | col, row, kind (0 freeze, 1 surge), life, active (all `f32`) |

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
`get_capture_count`, `get_capture_cells`, `get_deaths`, `get_kills`,
`get_drops`, `get_grabs`, `get_hunters`, `get_hunter_kills`, `get_freeze_t`,
`get_surge_t`.

`get_prev_*` and `get_tick_frac` exist for one reason: the worm advances a whole
cell per tick, roughly seven times a second, and drawing it only where the
engine says it is would animate at 7 fps on a 60 fps canvas. The renderer
interpolates between the previous cell and the current one instead.

`get_capture_count` through `get_hunter_kills` are **event counters** (`get_capture_cells`
is the size of the last capture, read alongside its counter). The engine never calls out — it has no
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

## Difficulty, September 2026

Three settings, picked with the HUD button or
`mount(el, { difficulty: 'hard' })`. The table lives in the engine:
`set_difficulty(d)` records the choice (0 easy, 1 normal, 2 hard) and `init()`
applies it, so a setting never changes halfway through a run.

| | Easy | Normal | Hard |
|---|---|---|---|
| Starting lives | 7 | 5 | 3 |
| Chaser step | 0.34 s | 0.26 s | 0.20 s |
| ... faster per level | 0.009 | 0.011 | 0.014 |
| ... floor | 0.14 s | 0.105 s | 0.085 s |
| A new chaser every | 3 levels | 2 levels | 1.5 levels (was 1; see [Past level 1](#past-level-1)) |
| Hazards | 2, +4 a level | 2, +6 a level | 4, +8 a level |
| Land to clear a level | 29% on level 1, +3 a level, cap 60% | 34%, +4, cap 72% | 39%, +5, cap 80% |

**The worm's own clock is not in the table.** `$TICK_BASE` and its ramp are the
feel of the controls rather than the challenge, and a worm that crawled on Easy
would be a different game to learn on rather than an easier one. What changes is
what is chasing it, how cluttered the board is, and how much of it a level asks
for.

**Normal is the previous balance exactly.** Identical input replayed through the
committed engine and this one gave byte-identical memory on every frame, over
13,795 frames of twelve runs. (Lives are an engine global rather than a memory
cell here, so there is no way to pin them from outside the way Pixel Wave's
replay does; the coverage comes from more runs instead.)

Benched with a pilot that plays badly: it runs in straight lines, turns at
random, never plans a loop, never checks where a chaser is and never heads home
to bank a claim — so whatever land it takes, it takes by accident. 24 runs each:

| | Survived: worst / median / best | Mean | Captures (median) | Cells held (median) |
|---|---|---|---|---|
| Easy | 22 / 28 / 48 s | 28.2 s | 3 | 47 |
| Normal | 13 / 18 / 29 s | 19.2 s | 2 | 39 |
| Hard | 6 / 10 / 17 s | 10.3 s | 1 | 31 |

### Past level 1

That pilot never clears level 1, so the per-level half of the table (a new
chaser every few levels, hazards growing, the target tightening, chasers
speeding up) was benched with a pilot that plays properly. At home it looks at
every rectangular loop it could run out from its territory and back. It takes
the one that encloses most per step, *if* every chaser would need longer to
reach any cell of it than the worm needs to close it, with 30% to spare. Out on
a trail, it runs home by the shortest safe path the moment a chaser gets closer
to the trail than it is to home. It sees chasers 150 ms late. It never wanders.

From level 1 with the usual lives, 15-minute cap, 8 runs each:

| | Level reached: worst / median / best | Survived (median) |
|---|---|---|
| Easy | 15 / **16** / 19 | 523 s |
| Normal | 7 / **10** / 11 | 572 s |
| Hard | 3 / **5** / 6 | 316 s |
| Hard, after the change below | 4 / **5** / 6 | 367 s |

And from engine builds that start at level *L* with full lives, 24 runs each:
levels cleared, median time to clear, median lives lost in it:

| Level | 1 | 2 | 3 | 4 | 6 | 8 | 10 | 12 |
|---|---|---|---|---|---|---|---|---|
| Easy | 24 · 16 s · 0 | 24 · 18 s · 0 | 24 · 17 s · 0 | 24 · 26 s · 0 | 24 · 25 s · 0 | 24 · 38 s · 0 | 24 · 43 s · 1 | 24 · 42 s · 0 |
| Normal | 24 · 21 s · 0 | 24 · 24 s · 0 | 24 · 40 s · 0 | 24 · 46 s · 0 | 24 · 64 s · 1 | 24 · 90 s · 2 | 21 · 115 s · 2 | 14 · 124 s · 4 |
| Hard, a chaser every level (as first shipped) | 12 · 33 s · 0 | 12 · 57 s · 0 | 11 · 79 s · 1 | 10 · 124 s · 1 | 0 · — · 3 | 0 · — · 3 | 0 · — · 3 | 0 · — · 3 |
| **Hard, every 1.5 levels (now)** | 12 · 33 s · 0 | 12 · 35 s · 0 | 12 · 68 s · 0 | 12 · 101 s · 1 | **5** · 159 s · 3 | 0 · — · 3 | 0 · — · 3 | 0 · — · 3 |

(Hard: 12 runs a level, and a 3-minute cap rather than 10; see below.)

**The per-level half of the table works, and the columns separate by where
they break.** On Normal every level clears, and what grows is the *cost*: time
to clear goes from 21 s to 124 s by level 12, and lives lost from 0 to 4. The
break comes around level 10-12, and that is where the from-level-1 runs end
(median level 10). Easy does not break inside twelve levels for this pilot:
every level clears, and lives lost stays at 0-1. That is the same shape at a
different point, and an easy setting that a careful player can keep playing is
what Easy is for.

**Hard had a wall at level 6, and it was the chaser count.** Hard added a
chaser every level, so level 6 had six, against three on Normal and two on
Easy. From there this pilot cleared nothing. It spent **25% of level 6 at home,
54% of level 8 and 75% of level 10**, looking for a loop that no chaser could
reach first and not finding one; runs that did not die sat there until the
cap. (That cap is 3 minutes and level 4 already took a median 124 s, so some of
those runs might have cleared given longer, but the median run still lost all
three lives.) After level 5, Hard was less a harder game than a game with
nothing safe to do, which is close to what CLAUDE.md's dead-time rule is about.

**So Hard now adds a chaser every level and a half**, 4 at level 6 rather than
6. The engine stores the interval in half-levels (`$CHASER_EVERY` is 6, 4, 3),
so Easy and Normal compute exactly what they did before: replayed against the
previous engine from every start level 1-12, they were byte-identical, and Hard
differed at exactly levels 2-11. The wall moved two levels deeper rather than
going away. Level 6 now clears in 5 of 12 runs, with 5% of it spent waiting,
and the stall starts at level 8 (29% waiting, then 67% at 10). Hard still
reaches its cap of eight chasers at level 12, as before. The table's other
Hard numbers did not move.

**The good pilot and the bad one bracket Normal's opening.** The bad pilot
above dies on level 1 in 18 seconds. This one clears it in 21 without a
scratch. Level 1 punishes wandering and rewards the loop-and-claim rule, which
is what finding 3 below retuned it to do.

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and Easy and Hard get `worm-chase:easy` and `worm-chase:hard`.

## Capsules, September 2026

The first item from the menu of features for the other eight titles: power-ups,
fitted to this game. Every 9–15 seconds of a level (the first at six), a capsule
appears on open ground at least four cells from the head. It lasts twelve
seconds, and there are never more than two.

| Kind | Share | Effect |
|---|---|---|
| **Freeze** (pale blue star) | 55% | the chasers' clock stops for 4 s: they hold still, and a frozen chaser still kills on contact |
| **Surge** (yellow bolt) | 45% | the worm ticks at 60% of its usual interval, 40% faster, for 5 s |

**You take one by driving over it or by enclosing it.** Enclosing is how this
game already pays for hazards and chasers: whatever a capture seals off is
yours. So a capsule is a lure onto the open board, and it asks the question the
whole game asks: how far out will you go, and how much will you fence? Both
kinds are the same answer in two shapes: more worm-time per chaser-time. Neither
is a shield or an extra life. Lives are not what a good player runs short of
here; time outside territory is. Taking a kind already in force restarts its
clock rather than stacking it. Effects end when a life is lost or a level
begins.

### On a random stream of their own

Capsules are placed from **`$dropRng`**, a second xorshift state, which is
[chapter 8](../../docs/08-globals-and-state.md)'s argument and the same move
Pixel Wave's power-ups made first. Placed from `$rng`, the first capsule would
shift every chaser's roam after it, and a run that never touched one would still
be a different run. On their own stream it is not. The previous engine and this
one, same seed and same input, were compared byte for byte over the whole old
layout (6,400 bytes) and every old reader: **144 replays from every start level
1–12 on all three settings, 86,790 frames**, identical in every run up to its
first collection. Surge sits behind a branch in `$tick_len` rather than a
multiply by 1.0 for the same reason: a run without one computes exactly what the
old engine did.

### Tuning the rate

The planning pilot from [Past level 1](#past-level-1) was taught to value a loop
that runs through or encloses a capsule as if it held 30 more cells. It was
flown from level 1 with a 15-minute cap. The medians below are level reached
and capsules taken a game, 8 runs each:

| | No capsules | Every 5–9 s | **Every 9–15 s** | Every 16–26 s |
|---|---|---|---|---|
| Easy | 16 · 0 | 17 · 26 | **17 · 18** | 16 · 12 |
| Normal | 9 · 0 | 9 · 17 | **9 · 11** | 9 · 7 |
| Hard | 5 · 0 | 6 · 12 | **6 · 7** | 6 · 4 |

And at 24 runs, Easy and Normal, level reached worst / median / best:

| | No capsules | Ignores them | Goes for them |
|---|---|---|---|
| Easy | 10 / 15 / 18 | 11 / 15 / 20 | **13 / 16 / 18** |
| Normal | 6 / 9 / 11 | 6 / 9 / 11 | 7 / 9 / 11 |

**It is a modest help, and it helps the bottom most.** Going for capsules adds
about a level on Easy and Hard and lifts the worst run by three levels on Easy.
It moves nothing on Normal's median. A pilot that ignores them still takes 4–9
a game by accident, just by enclosing ground, and plays the same game as
before: at 24 runs its levels match the engine without capsules. (At 8 runs it
looked a level worse on Easy and Normal, and that was noise. Neither effect can
cost a life by itself: freeze only stops chasers, and surge only makes the worm
faster.) Every 9–15 s is about one capsule per level on Normal's pace. That is
often enough to be part of the game, and rare enough that a player is never
choosing between capsules.

**What this bench cannot price.** The pilot takes a capsule and then plays
exactly as before. Its safety test still assumes the chasers are moving and
the worm is at normal speed, so it never runs the long loop a freeze makes safe.
Those four seconds are the whole point for a person, so the numbers above are
a floor on what capsules are worth, not an estimate.

## The hunter, September 2026

This game's entry on the menu of features for the other eight titles was the
same idea twice: a boss wave, *"a hunter chaser every few levels that cuts the
trail rather than chasing the head"*, and its own idea, *"a hunter that cuts
your trail"*. It is built as that.

On every fourth level one more chaser joins the pack, and it is a **hunter**:
violet, horned, with a split jaw, so it reads as a different animal by shape
and not only by colour. While the worm is home it roams like the others. Once a
trail exists, a chaser homes on the head, and the hunter homes on **the trail
cell nearest to itself**. A chaser is beaten by being quick: run for home and
it follows you there. The hunter is beaten by being *short*, because the trail
it is heading for is behind you. It punishes exactly the long, lazy loop that a
game with only chasers lets you get away with.

It is beaten the way this game beats anything: **fence it in**, for 500 rather
than a chaser's 150. It lives in the chaser record's last field, which used to
be padding, so no layout moved, and the extra slot it takes is placed from
`$rng` like any chaser. Levels without one therefore replay the engine before it
byte for byte: 144 replays from every start level 1-12 on all three settings
differed at exactly levels 4, 8 and 12 and nowhere else.

### What it costs

The planning pilot from [Past level 1](#past-level-1), 12 runs a level, before
and after, shown as levels cleared · median time. Every level without a hunter
came out identical, row for row, as the replay says it must.

| Level | Easy, before → with | Normal, before → with | Hard, before → with |
|---|---|---|---|
| 4 | 12 · 27 s → 12 · **35 s** | 12 · 46 s → 12 · **56 s** | 12 · 101 s → **9** · 119 s |
| 8 | 12 · 34 s → 12 · 38 s | 12 · 89 s → **10** · 95 s | 0 → 0 |
| 12 | 12 · 43 s → 12 · 46 s | 6 · 128 s → **4** · 160 s | 0 → 0 |

**A hunter level is a step, not a wall.** On Easy it costs a few seconds. On
Normal it costs about a fifth more time, and a couple of runs at level 8 and
up. On Hard it takes level 4 from certain to three in four. Hard's levels 8 and
12 were already beyond this pilot before the hunter (see [Past level
1](#past-level-1)), and remain so.

**What the bench does not measure: fencing it.** This pilot's safety test
already assumes any chaser could head for any cell of a loop, which is what the
hunter actually does, so the pilot is not surprised by it. That is why the cost
is modest. But it never plans a loop *around* the hunter, so it almost never
collects the 500. A player who treats the hunter as a target is playing a part
of the game no pilot here does.

---

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
