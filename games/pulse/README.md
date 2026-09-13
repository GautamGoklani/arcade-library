# Pulse

A twelve-segment tube with you on the rim of it and a bar of music walking
toward you. Everything arrives on the grid: enemies spawn on sixteenth notes,
and a shot fired on an eighth note hits three times as hard as one that is not.
All of it — the tempo, the bar, the pattern, what counts as *in time* — is
hand-written in WebAssembly Text (`game.wat`) and runs as a compiled `.wasm`
binary. JavaScript forwards two numbers, calls `step(dt)`, draws what it finds
in the engine's linear memory, and plays the soundtrack off the engine's step
counter.

Works on **desktop (arrow keys and space)** and **mobile (two tap zones and a
fire pad)**.

Open [`index.html`](index.html) to play it.

## What this title was actually waiting for

Pulse sat on the roadmap for as long as it did because it "needs an audio
system that does not exist yet". That was the wrong way round, and it is
exactly why it stayed blocked.

The missing piece was never a synthesiser. Every title here since Grid Breaker
has had one, in about eighty lines of Web Audio in the widget. What was missing
was an answer to a question the third invariant asks:

> if the music decides when enemies arrive, and the music lives in JavaScript,
> then JavaScript owns game state.

So it does not live in JavaScript. **The engine is the sequencer.** It owns the
tempo, the sixteen-step bar, the step counter and the pattern; it decides what
spawns and when. The widget reads `get_steps()`, diffs it like any other event
counter, and plays a note. The synthesiser is an *instrument*, not a clock.

What that buys is not tidiness. It is that the music and the game **cannot
drift**. There is no scheduling to reconcile, no audio-clock-versus-frame-clock
problem, no "the beat and the spawn were forty milliseconds apart". The spawn
and the note are the same event, read off the same counter — so a player timing
a shot to what they hear is timing it to what the engine did.

The cost is stated plainly rather than hidden: notes are played the frame the
counter moves, so there is up to one frame of jitter — 16ms at 60fps, against a
sixteenth note of 156ms at the opening tempo. A conventional Web Audio
sequencer would avoid that by booking a second of music ahead against the audio
clock, which is the right way to build a music app and the wrong way to build
this, because the moment the music is booked ahead it is a second out of step
with a simulation that can be restarted, paused or slowed by a stuttering
frame.

## Self-contained, deliberately

This folder shares **no code and no assets** with any other title in `games/`.
It has its own scoped stylesheet (`.pl-` — no other game may use that prefix),
its own synthesiser and its own drawing. What it takes from the other engines
is *conventions*, copied by hand: a globals block at the top of the `.wat`,
entity pools at fixed offsets, an xorshift RNG, monotonic event counters, and
an `init` / `set_input` / `step` / `get_*` export surface.

The reason is the one [Grid Breaker's README](../grid-breaker/README.md) gives:
a shared engine library would mean a change made for one game could break
another. Tooling is the exception — the shared
[`scripts/build.mjs`](../../scripts/build.mjs) builds every title, so
`npm run check` verifies all nine committed binaries in one pass.

### It has no imports

Like [Worm Chase](../worm-chase/), [Sector Defense](../sector-defense/),
[Circuit Runner](../circuit-runner/), [Starfield Runner](../starfield-runner/)
and [Tower Defense Lite](../tower-defense/):

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

The tube is twelve **discrete segments and a depth**, so nothing in the engine
turns through an angle. The widget works out where a segment lands on screen
with `Math.cos`, because that is a drawing question — and because how big the
tube is on the canvas is a decision the engine should not have an opinion
about.

## Files

```
pulse/
├── pulse.js     ← the widget (engine embedded inside) — REQUIRED
├── pulse.css    ← scoped styles (.pl-*)               — REQUIRED
├── game.wat     ← engine SOURCE — edit to change gameplay
├── game.wasm    ← compiled engine (also embedded in the .js as base64)
├── index.html   ← standalone page: the game and nothing else
├── demo.html    ← minimal working integration example
├── logo.svg     ← catalogue artwork
└── README.md
```

For plain integration you only need to copy **two files** into a site:
`pulse.js` and `pulse.css`.

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="pulse.css">

<div id="game"></div>

<script src="pulse.js"></script>
<script>
  var game = Pulse.mount('#game');
</script>
```

### JavaScript API

```js
var game = Pulse.mount(containerOrSelector, options?);

game.restart();    // start a fresh run
game.getState();   // { score, shield, groove, multiplier, bpm, level, bar,
                   //   onBeatShots, shots, gameOver }
game.destroy();    // stop the loop, remove DOM + all event listeners
```

`options` (all optional):

| option       | meaning |
|--------------|---------|
| `wasmUrl`    | load the engine from a `.wasm` URL instead of the embedded copy (requires an `application/wasm` MIME type) |
| `wasmBase64` | supply your own base64 engine build |

Multiple instances on one page are supported — each `mount()` is independent.
**The soundtrack is most of this game**, and browsers will not open an
AudioContext outside a user gesture, so nothing is heard until the first key or
tap. Everything else works without it.

## Controls

| Action | Desktop | Mobile |
|---|---|---|
| Rotate | ← / → or A / D | tap the left or right side |
| Fire | Space | the FIRE pad |
| Restart | R | tap the GAME OVER text |
| Mute | M | the SOUND button |

**Tap zones rather than a stick**, as in [Circuit Runner](../circuit-runner/),
for the same reason: the ring is a *discrete* input, twelve segments and one
press each, and a stick would mean pushing, waiting and re-centring for every
one. Firing gets its own pad because it is edge-triggered and has to be timed
to a sixteenth of a second, which is not something to ask of a thumb that is
also steering.

Firing is edge-triggered on purpose. Holding the key would let a player spray
and be on the beat by accident once every eighth note, which is the exact skill
the game is about not needing.

## Gameplay rules

- **Shield 100.** Anything that reaches the rim costs 20 *and* four fifths of
  your groove. A leak is a missed beat as much as it is damage, and charging
  for it twice is what makes the meter mean "you are playing in time" rather
  than "you have been playing a while".
- **A shot within 58ms of an eighth note is on the beat.** It flies at 4.4
  depth-units a second instead of 2.6 and does 3 damage instead of 1.
- **Groove** rises 0.085 per on-beat shot, falls 0.12 per off-beat one, and
  bleeds 0.055 a second all the time — so standing still is never a plan. It
  drives the multiplier (up to ×5) *and the tempo* (up to +54 BPM), which is
  the whole reward loop in one sentence: play in time and the track speeds up.
- **A bar with no leak pays.** 12 shield and a 200-point bonus. It is the only
  repair there is, and it is deliberately a *bar* rather than a kill: the unit
  of play here is the pattern, so the unit of reward is too.
- **The first bar is silence.** The song starts one bar in, so you hear the
  tempo before anything arrives on it. A rhythm game that opens on the downbeat
  has asked for a reaction to a beat nobody has heard yet.
- **A level every eight bars**, which raises the tempo floor, the number of
  spawns in a bar and the climb rate.

### The four enemies

| Enemy | HP | Climb | What it is for |
|---|---|---|---|
| **Drone** | 3 | steady | the baseline; from the first bar |
| **Skipper** | 3 | **hops on the step**, and sidesteps a segment every quarter note | the one you can hear moving |
| **Hulk** | 6 | slow | from level 4; wants on-beat shots because three of them beat six |
| **Mirror** | 4 | medium | from level 6. **An off-beat shot does nothing at all to it.** |

The skipper is the reason the step counter belongs to the engine and not the
widget: it moves *on the note*, so a player who is listening knows where it
will be before they can see it.

The mirror is the only thing here that requires the beat rather than rewarding
it, which is why it does not arrive until level 6 — a player who has not yet
found the rhythm would simply be unable to kill it. It wears a spinning ring so
that is visible before three wasted shots make the point.

## How a bar is written

Sixteen steps. The engine picks how many carry a spawn (three, rising to eleven
with the level) and then rejection-samples positions against a **weight by
where the step falls in the bar**:

| step | weight |
|---|---|
| the four quarter notes (0, 4, 8, 12) | 9 |
| the off-eighths (2, 6, 10, 14) | 4 |
| the sixteenths in between | 1 |

That weighting is the whole reason the result sounds like music rather than
noise. Choosing uniformly at random — the first version — produced sixteen
equally probable events a bar, which a listener hears as a stuttering machine
and a player cannot anticipate at all.

Segments **wander** rather than jumping: each spawn is within three segments of
the last one planned. Two spawns a quarter note apart on opposite sides of the
ring is not a pattern, it is a coin toss the player cannot answer, because
there is not time to cross.

And the bar plan lives **in linear memory rather than in globals**, because the
widget reads it *ahead of the simulation*: the HUD draws the coming bar as a
ring of sixteen ticks outside the rim, coloured by what will arrive on each.
That turns the track from something you react to into something you can read,
which is the difference between a rhythm game and whack-a-mole with a
soundtrack.

## Architecture

```
pulse.js ── set_input(move, fire) ──▶  game.wasm  (simulation AND sequencer)
    ▲              step(dt)                 │
    ├──── reads enemy/bolt records ◀────────┤
    └──── diffs get_steps() ─▶ synth ◀──────┘
```

**JavaScript owns no game state** — not the tempo, not the bar, not what counts
as on the beat. It forwards two numbers, calls `step(dt)`, and reads.

The engine never calls out. It exposes **monotonic event counters**
(`get_steps`, `get_bars`, `get_spawns`, `get_shots`, `get_beat_shots`,
`get_kills`, `get_beat_kills`, `get_leaks`, `get_perfects`, `get_moves`) and the
widget diffs them between frames. `get_steps` is the one that makes this title
work: it ticks once per sixteenth note and the soundtrack is played off it.

### The song clock advances in a loop

```wat
(block $ticked
  (loop $tlp
    (br_if $ticked (f32.lt (global.get $songT) (local.get $sd)))
    (global.set $songT (f32.sub (global.get $songT) (local.get $sd)))
    ...
    (br $tlp)))
```

Not a single subtraction. A frame that took longer than one sixteenth note has
to fire **every step it skipped** — dropping them would let a stutter swallow a
spawn, and the player would hear a bar with a hole in it. The widget does the
same on its side, playing up to four notes for one frame's worth of steps.

### WASM linear memory layout

| region | offset | stride | count | fields |
|--------|--------|--------|-------|--------|
| bar | 0 | 4 B | 16 | byte 0 segment+1 (0 = no spawn), byte 1 kind, byte 2 spent |
| enemies | 64 | 32 B | 32 | seg, depth, hp, maxHp, kind, active, flash, hopT |
| bolts | 1088 | 24 B | 24 | seg, depth, dmg, active, onBeat, speed |

Total 1,664 bytes of a single 64 KiB page. `depth` runs 0 at the centre to 1 at
the rim. Shield, groove, score and the song clock are globals rather than
memory, as in the other recent titles.

> **The widget hard-codes these offsets.** Change the layout in `game.wat` and
> `pulse.js` must change with it — nothing links them at build time, and the
> failure is silent. `npm run check` runs
> [`scripts/check-layout.mjs`](../../scripts/check-layout.mjs), which compares
> the named constants; it cannot compare *field order*, so the memory-map
> comment at the top of `game.wat` is the schema to keep honest.

### Exports

```
init() · set_input(move, fire) · step(dt) · enemies_alive()
get_score() · get_shield() · get_shield_max() · get_groove() · get_mult()
get_level() · get_seg() · get_segments()
get_bpm() · get_step_dur() · get_step_idx() · get_steps_per_bar()
get_step_phase() · get_beat_error() · get_beat_window() · get_bar()
get_fire_cd() · is_game_over()
get_steps() · get_bars() · get_spawns() · get_shots() · get_beat_shots()
get_kills() · get_beat_kills() · get_leaks() · get_perfects() · get_moves()
```

`get_beat_error()` is how far the song clock is from the nearest eighth note,
in seconds. It is exported rather than kept private because the widget draws
the timing feedback from it, and because it is what a bench needs in order to
play in time at all.

## The graphics

Drawn into a **320×240 buffer and blown up 3× with smoothing off**, as in the
other recent titles, with **no glow anywhere** and CSS scanlines at true display
resolution. Both are dropped under `prefers-reduced-motion`.

There are no sprites. Everything on the board is a circle, an arc or a spoke at
a radius the engine chose, so all of it is drawn as runs of `fillRect` on the
low-res grid — which is what a line is on that grid anyway.

**The whole picture breathes on `get_step_phase()`**, hardest on quarter notes,
less on eighths, barely on sixteenths. That is not decoration: a player looking
at the board rather than at the HUD still has to be able to see where the beat
is, and the whole tube swelling is the only signal big enough to catch out of
the corner of an eye.

## Findings from benching

Every number here came from driving the compiled engine headlessly from Node.
The RNG is seeded to a constant and is touched only by the pattern writer, so
each pilot below played the same music.

### 1 · Playing in time is worth roughly six times as much

Three pilots, identical targeting, one difference: when they pull the trigger.

| pilot | survived | level | score | per second | on beat | perfect bars |
|---|---|---|---|---|---|---|
| **metronome** — fires only inside the window | 75s | 6 | **82,134** | **1,095** | 100% | 40 |
| **mash** — fires as fast as the edge trigger allows | 101s | 6 | 19,232 | 190 | 38% | 39 |
| **loose** — aims at the beat and misses it | 46s | 3 | 5,068 | 110 | 14% | 14 |

The masher survives *longest*, and that is the design rather than a hole in it:
groove drives the tempo, so a player who is in time is asking for a faster
track and more spawns per second. What they get for it is six times the score
per second. Sloppiness is safe and worthless; precision is dangerous and worth
everything.

### 2 · The window was wide enough to pay a button-masher

The first draft's window was 75ms, which is two windows per eighth note out of
312ms at the opening tempo — **48% of the bar spent inside one**. The masher
landed 70% of its shots on the beat by accident, which makes the whole mechanic
a decoration with a light on it.

At 58ms the accidental rate is 38%, which matches the arithmetic, and the
metronome still clears the window comfortably. The window is a fixed number of
**seconds** rather than a fraction of a beat, so it stays the same in feel and
gets strictly harder as the track speeds up — which is what a rhythm player
expects, and not what a fixed fraction would have given them.

### 3 · A level every four bars is a level every six seconds

Bars are 2.5s at the opening tempo and 1.5s once groove is up. At four bars a
level, the difficulty ramp was outrunning the player badly enough that the best
pilot on the bench was dead in forty-six seconds. At eight bars it lasts
seventy-five and gets to see the mirror.

## Tuning

The constants worth touching are all at the top of `game.wat`:

| constant | meaning | shipped |
|----------|---------|---------|
| `$BPM_BASE` / `$BPM_GROOVE` / `$BPM_CAP` | opening tempo, what full groove adds, ceiling | 96 / +54 / 168 |
| `$BEAT_WINDOW` | how close to an eighth note counts, in seconds | 0.058 |
| `$SEGMENTS` | the ring | 12 |
| `$BOLT_DMG` / `$BOLT_DMG_BEAT` | off the beat, and on it | 1 / 3 |
| `$BOLT_SPEED` / `$BOLT_SPEED_BEAT` | depth units per second | 2.6 / 4.4 |
| `$GROOVE_GAIN` / `$GROOVE_MISS` / `$GROOVE_DECAY` | up, down, and the bleed | 0.085 / 0.12 / 0.055 |
| `$MULT_MAX` | the multiplier at full groove | 5 |
| `$SHIELD_MAX` / `$LEAK_COST` / `$PERFECT_BAR_HEAL` | the tube | 100 / 20 / 12 |
| `$FIRE_CD` / `$FIRE_CD_GROOVE` | reload, cold and at full groove | 0.16s / 0.07s |
| `$MOVE_CD` | how fast holding a direction sweeps the ring | 0.085s |

The difficulty curve:

| per level (eight bars) | value |
|---|---|
| tempo floor | +2.2 BPM |
| spawns in a bar | +1 every two levels, from 3 to 11 |
| climb rate | +11% of the base |
| kinds in play | drone from 1, skipper from 2, hulk from 4, mirror from 6 |

## Rebuilding the engine

```bash
npm install            # wabt is a devDependency of this repo
npm run build:pulse    # game.wat -> game.wasm, re-embedded into the .js
npm run check          # verify the committed binary matches its source
```

`game.wasm` and the base64 copy inside `pulse.js` are both committed, so a
fresh checkout plays with nothing installed. `npm run check` is what stops the
three copies of the engine drifting apart.

## Browser support

Any browser with WebAssembly MVP and canvas 2D: Chrome/Edge 57+, Firefox 52+,
Safari 11+. The engine uses **strict MVP** — four value types, one 64 KiB page,
structured control flow, no post-MVP feature and no feature detection. The
soundtrack needs Web Audio and starts on the first input, because browsers
refuse to open an AudioContext outside a user gesture; without it the game is
still playable from the visual metronome, which is the reason the whole board
pulses.
