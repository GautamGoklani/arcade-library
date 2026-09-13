# 22 · Case study: the engine that owns time

← [Generating a world that is always winnable](21-generated-worlds.md) · [Contents](README.md) · [Glossary](glossary.md)

---

Every chapter of Part III so far has been about the engine owning *space* — a
pool of positions, a grid of cells, a route across a board. This one is about
the engine owning *time*, which sounds like the same claim and is not, because
time in a browser game already has an owner and it is not you.

[Chapter 15](15-game-loop-architecture.md) settled the first half of that: the
host owns the frame clock, hands the engine a `dt`, and the engine advances
whatever it advances. That is enough for every title in this repository except
one. [Pulse](../games/pulse/) is a rhythm game, and a rhythm game has a second
clock — the musical one — which has to agree with the simulation exactly,
because the whole mechanic is that a shot landing on a beat is worth more than
one that does not.

Where that clock lives turns out to be a real architectural decision with a
wrong answer that is very easy to reach.

---

## The obvious design, and why it fails

Web Audio has a good clock. `AudioContext.currentTime` is sample-accurate,
monotone, and unaffected by a dropped frame. Every guide to sequencing in the
browser tells you — correctly — to use it, and to **schedule ahead**: run a
timer every 25ms, look a couple of hundred milliseconds into the future, and
book every note that falls in that window with `oscillator.start(when)`. The
audio thread plays them at exactly the right moment whatever the main thread is
doing.

So the obvious design for a rhythm game is:

```js
// the obvious design
function scheduler() {
  while (nextNoteTime < audio.currentTime + LOOKAHEAD) {
    playNote(nextNoteTime);
    if (patternHasSpawn(step)) wasm.exports.spawn(segment, kind);  // <-- here
    nextNoteTime += stepDuration;
    step = (step + 1) % 16;
  }
}
```

It sounds perfect. It is also three separate problems.

**The first is the invariant.** `patternHasSpawn`, `step`, `stepDuration` and
`nextNoteTime` are all in JavaScript, and between them they decide what enemies
exist and when. That is game state, and
[the third invariant of this repository](../CLAUDE.md) says JavaScript does not
get to have any:

> **JavaScript owns no game state.** It forwards input, calls `step(dt)`, and
> reads entity records out of linear memory to draw them. If a rule lives in
> the widget, it is in the wrong file.

That is not pedantry about file layout. It is the reason
[`getState()`](15-game-loop-architecture.md) can be one line, the reason the
engine can be benched headlessly with no DOM, and the reason there is exactly
one place to look when a spawn happens at the wrong time.

**The second is that lookahead is a lie about the present.** Scheduling books
notes for a future that has not happened in the simulation yet. Restart the
game and 200ms of the old bar is already in the audio graph. Pause it and the
music plays on. Let a frame take 90ms — which happens — and the simulation is
now behind music that was written when it was not.

**The third is the one that actually kills it.** Even if you keep the two
clocks perfectly in step, you now have two of them, and the player is being
judged against one while listening to the other. "The beat and the spawn were
forty milliseconds apart" is not a bug you can find, because there is no single
place where it is decided that they were the same moment.

---

## The inversion

There is a cleaner answer, and it falls straight out of the invariant once you
stop trying to work around it.

> **The engine is the sequencer. The widget is the instrument.**

The engine owns the tempo, the bar, the step counter and the pattern. It
decides what spawns and when. It does not make a sound, because it cannot — it
has no imports and nothing to call. Instead it does what every other engine in
this repository does with an event: it **increments a counter**.

```wat
;; games/pulse/game.wat
(global $songT (mut f32) (f32.const 0.0))    ;; seconds into the current step
(global $stepIdx (mut i32) (i32.const 0))    ;; which of the sixteen
(global $steps (mut i32) (i32.const 0))      ;; monotonic, never resets

(func $step_dur (export "get_step_dur") (result f32)
  (f32.div (f32.const 60.0) (f32.mul (call $bpm) (f32.const 4.0))))
```

and the widget plays whatever it finds:

```js
// games/pulse/pulse.js
var st = e.get_steps();
if (st > prevSteps) {
  var n = Math.min(4, st - prevSteps);
  for (var i = 0; i < n; i++) sound.step(e.get_step_idx());
  prevSteps = st;
}
```

That is the same three lines as `get_kills` or `get_hits` in every other title
in `games/`. The soundtrack is not a subsystem. **It is an event counter with a
synthesiser attached**, and the reason that works is that a sixteenth note and
a spawn are not two things that have to be synchronised — they are one thing,
read off one counter.

---

## What it costs

Be honest about this, because it is a real trade and the guides are not wrong.

A note is played on the frame the counter moves, so it lands with up to one
frame of jitter: **16ms at 60fps**, against a sixteenth note of 156ms at
Pulse's opening tempo. That is about a tenth of a note. It is audible if you
listen for it, and it is worse on a machine that is dropping frames — which is
exactly when a scheduled design would be smoothest.

What is bought for it:

| | scheduled ahead | played off the counter |
|---|---|---|
| Timing precision | sample-accurate | ±1 frame |
| Who decides a spawn | JavaScript | the engine |
| Restart / pause | music outlives the simulation | nothing to flush |
| Can the two drift? | yes, and silently | no — there is one clock |
| Headless bench | must stub the audio clock | nothing to stub |
| `getState()` | must include the song | already includes it |

The last row is the one to hold on to. Because the song clock is engine state,
the headless bench in
[`games/pulse/README.md`](../games/pulse/README.md) can drive the whole thing
from Node with no `AudioContext` at all — and that is how the beat window got
tuned, by measuring what fraction of a button-masher's shots landed inside it.

For a music *application* — a DAW, a metronome, a backing track — schedule
ahead. For a game where the beat is a **rule**, the rule belongs where the rest
of the rules are.

---

## Advancing a clock you cannot trust

One detail that looks like an implementation note and is not.

```wat
(global.set $songT (f32.add (global.get $songT) (local.get $d)))
(local.set $sd (call $step_dur))
(block $ticked
  (loop $tlp
    (br_if $ticked (f32.lt (global.get $songT) (local.get $sd)))
    (global.set $songT (f32.sub (global.get $songT) (local.get $sd)))
    (global.set $stepIdx (i32.add (global.get $stepIdx) (i32.const 1)))
    ...
    (br $tlp)))
```

A loop, not a single subtraction. At 168 BPM a sixteenth note is 89ms, and a
frame that took 90ms is not exotic — a garbage collection, a tab regaining
focus, a laptop switching GPUs. If the clock advanced one step per frame, that
frame would swallow a step, and the step it swallowed might have had a spawn on
it. The player would hear a bar with a hole in it, and the hole would be
different every time.

`dt` is clamped to 50ms at the top of `step`, exactly as
[chapter 15](15-game-loop-architecture.md) argues it should be, so the loop can
run at most a handful of times. The widget does the same thing on its side —
`Math.min(4, st - prevSteps)` — for the same reason and with the same cap:
**two notes close together are better than a missing one.**

---

## Where the pattern lives, and who is allowed to read ahead

Pulse writes the coming bar into linear memory rather than into globals:

```wat
;; bar @0 : stride 4, 16 steps
;;          byte 0  seg + 1, or 0 for no spawn on this step
;;          byte 1  kind
```

That is a deliberate exception to the habit of the recent engines, which put
scalars in globals because
[the `get_*` readers are the only consumer](08-globals-and-state.md). Here they
are not: the **widget reads the plan ahead of the simulation**, and draws the
sixteen steps of the coming bar as a ring of ticks outside the tube, coloured
by what will arrive on each.

That is worth being precise about, because it looks like a violation of the
invariant and is the opposite of one. The widget is not *deciding* anything —
the plan was written by `$plan_bar` at the bar boundary and the widget cannot
change it. It is reading state that the engine has already committed to, which
is the same thing it does when it reads an enemy's position. The difference is
only that this particular state describes the future.

And it changes the game. Without it, a rhythm game is whack-a-mole with a
soundtrack: things appear, you react. With it, the pattern is *legible* two
seconds before it happens, and the skill becomes reading it.

---

## Making the music sound like music

A last note that is not about architecture but is about why this works at all.

The first version of `$plan_bar` picked spawn steps uniformly at random out of
the sixteen. Every position was equally likely, which a listener hears as a
stuttering machine and a player cannot anticipate at all — and the whole point
of putting the pattern on screen is that it can be anticipated.

What ships is rejection sampling against a weight:

```wat
(func $step_weight (param $s i32) (result i32)
  (if (i32.eqz (i32.rem_u (local.get $s) (i32.const 4))) (then (return (i32.const 9))))
  (if (i32.eqz (i32.rem_u (local.get $s) (i32.const 2))) (then (return (i32.const 4))))
  (i32.const 1))
```

Nine for the four quarter notes, four for the off-eighths, one for the
sixteenths in between. Three integers, and the difference between a drum
pattern and a random-number generator with a speaker attached.

The same idea runs through [chapter 21](21-generated-worlds.md): a generator
that is *correct* is not the same as a generator that is *good*, and the gap
between them is usually a weighting nobody thought to write down.

---

## What to take from this

| Question | Answer here |
|---|---|
| Two clocks that must agree? | Do not have two. Make one of them derived state of the other |
| Where does musical time live? | Wherever the rules that depend on it live |
| Scheduled audio, or reactive? | Scheduled for a music app; reactive for a game where the beat is scored |
| What does reactive cost? | One frame of jitter. Measure it against a note length before deciding it matters |
| Frame longer than a step? | Loop the clock, cap the loop, and never silently drop a step |
| Can the widget read ahead? | Of state the engine has already committed to, yes — reading a decision is not making one |
| Random pattern sounds wrong? | It is uniform. Weight the strong beats; three integers is enough |

---

← [Generating a world that is always winnable](21-generated-worlds.md) · [Contents](README.md) · [Glossary](glossary.md) · [Further reading](further-reading.md)
