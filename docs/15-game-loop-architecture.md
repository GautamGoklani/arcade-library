# 15 · Architecture of a wasm game loop

← [Post-MVP features](14-post-mvp-features.md) · [Contents](README.md) · next: [Entity pools](16-entity-pools.md)

---

Part I was the language. This chapter and the ones after it are one worked
example: how the engines in `games/` are put together — `pixel-wave` first, and
then the later titles where a decision was made differently — and which of those
decisions generalise.

The architecture in one sentence: **the host owns time and pixels, the module
owns state and rules, and the only thing crossing between them is three
numbers in and a `Float32Array` out.**

---

## The split

```
┌─ JavaScript ──────────────────────────────────────────────┐
│  requestAnimationFrame  → compute dt                      │
│  keyboard / touch       → rotate, thrust, fire            │
│                                                            │
│      set_input(rot, thrust, fire)   ──────────────┐       │
│      step(dt)                       ──────────────┤       │
│      get_score() get_lives()        ◀─────────────┤       │
│                                                    │       │
│  read memory as Float32Array        ◀──────────────┤       │
│  draw sprites to <canvas>                          │       │
│  play sound                                        │       │
└────────────────────────────────────────────────────┼───────┘
                                                     │
┌─ game.wasm ─────────────────────────────────────────┴──────┐
│  player physics · enemy AI · bullet pool · asteroids       │
│  collisions · score, lives, level                           │
│  all of it in one 64 KiB linear memory                      │
└─────────────────────────────────────────────────────────────┘
```

Four ideas hold it up, and each is a choice that could have gone the other way.

### 1. The engine has no clock

`step(dt)` takes the elapsed time as a parameter. The module imports nothing
that could tell it what time it is.

This falls out of the sandbox — there is no clock unless you import one — but
it is worth *keeping* even where a clock is available:

- **Testability.** Three simulated seconds run in microseconds. You can assert on
  exact state at frame 180 ([chapter 9](09-toolchain.md) has the tests).
- **Replay.** A run is a function of the inputs and the `dt` sequence.
- **Slow motion, fast-forward, pause** are all "pass a different `dt`", or none.
  Pixel Wave's pause is `return` before `step`, and there is no pause code in the
  engine at all.
- **Portability.** The engine does not care whether it is driven by
  `requestAnimationFrame`, a fixed-rate worker, or a headless test loop.

The host's side of the bargain is to clamp `dt`:

```js
const dt = Math.min((now - last) / 1000, 0.05);   // never more than 50 ms
last = now;
```

Without the clamp, a backgrounded tab returning after thirty seconds delivers
`dt = 30`, and every entity moves thirty seconds' worth in one integration
step — straight through walls, past every collision test, out of the arena. This
is the single most common bug in variable-timestep loops, and one line fixes it.

### 2. The engine owns all state; the host renders a snapshot

JavaScript holds no game state. Not a position, not a score, not a "which
enemies are alive" array. Everything is in linear memory, and the renderer reads
it fresh each frame:

```js
const mem = new Float32Array(memory.buffer);

for (let i = 0; i < MAX_BOTS; i++) {
  const b = (BOTS_OFF + i * BOT_STRIDE) >> 2;
  if (mem[b + 5] > 0) drawBot(mem[b], mem[b + 1], mem[b + 4]);   // x, y, heading
}
```

There is exactly one source of truth, so the two halves cannot disagree. The
renderer is a **pure function of memory** — which is why you can pause the game
and still redraw on a resize, and why the same memory can be drawn by a canvas
renderer, a WebGL renderer, or a test harness that just counts sprites.

### 3. Commands cross the boundary; the world does not

Per frame: `set_input` (three numbers), `step` (one number), `get_score`,
`get_lives`. Four calls. The world — up to 213 live entities in Pixel Wave — is
never passed anywhere. It is read in place.

This is [chapter 7](07-javascript-interop.md)'s rule applied: make the boundary
wide and rare. A design that returned an array of entity objects from `step`
would allocate 213 objects per frame, 12,780 per second, and hand the garbage
collector a job it did not need.

### 4. Sound and score display are host concerns

The engine does not know sound exists. The obvious way for the renderer to find
out what happened is to watch state change between frames:

```js
let prevScore = 0, prevLives = 5;
const score = get_score(), lives = get_lives();
if (score > prevScore) sfx('explosion');
if (lives < prevLives) sfx('hit');
prevScore = score; prevLives = lives;
```

Crude, and it has two real limitations. It cannot tell events apart when they
move the same number — a bot shot down and an asteroid shot down both add one
to the score. And it can only hear events that **leave a mark in memory**. A
ball bouncing off a paddle changes a velocity; a caught power-up simply
vanishes; neither is anything you can diff. Grid Breaker carried paddle,
power-up and launch sounds for as long as it used this pattern, and not one of
them was ever played.

What every engine in this repository uses now is smaller than an event queue
and has neither limitation: an **event counter** per kind of event, incremented
at the exact line where the engine decides the event happened.

```wat
(global $kills (mut i32) (i32.const 0))
;; ... in the bullet-vs-bot collision, beside the score increment:
(global.set $kills (i32.add (global.get $kills) (i32.const 1)))
(func $get_kills (export "get_kills") (result i32) (global.get $kills))
```

```js
const kills = get_kills();
if (kills > prevKills) sfx('explosion');
prevKills = kills;
```

It looks almost identical to the crude version, and the whole difference is
where the decision lives. A counter is not inferred from state; it *is* the
event, written by the only code that knows it happened. It costs one global and
one export, never allocates, and cannot be missed by a slow frame, because it
only goes up. What it gives up is *where* — a count cannot say which bot died —
so Pixel Wave still reads positions out of memory to place its explosions,
which is a drawing question and belongs in the renderer.

---

## Variable vs fixed timestep

The engines here integrate with whatever `dt` arrives. That is the simple choice
and it has known costs.

**Variable timestep** (what these do):

```js
step(Math.min((now - last) / 1000, 0.05));
```

Simple, always in step with the display, no accumulator. But the simulation is
**not deterministic across machines** — a 144 Hz monitor and a 60 Hz monitor
produce different `dt` sequences and therefore slightly different runs. Physics
at very large `dt` degrades: Euler integration with drag behaves differently at
16 ms than at 50 ms, and tunnelling through thin objects becomes possible.

**Fixed timestep with an accumulator** (what a physics-dependent game should do):

```js
const FIXED = 1 / 120;
let acc = 0;

function frame(now) {
  acc += Math.min((now - last) / 1000, 0.25);
  last = now;
  while (acc >= FIXED) { step(FIXED); acc -= FIXED; }
  render(acc / FIXED);          // interpolation factor for smooth drawing
  requestAnimationFrame(frame);
}
```

Every simulation step is identical everywhere. Collisions are stable. Replay
works across machines. The costs are a variable number of `step` calls per
frame, the need to interpolate rendering (or accept judder), and the "spiral of
death" if `step` ever costs more than `FIXED` — hence the clamp on the
accumulator.

**Which to use.** Fixed if physics correctness or determinism matters —
platformers, anything with stacking or resting contacts, anything with replay or
netcode. Variable is fine for these games: entities are points, collisions are
circle overlaps, and nothing rests on anything. Glenn Fiedler's *Fix Your
Timestep!* is the canonical treatment and worth the twenty minutes.

Note that **the engine supports both without modification**, because `dt` is a
parameter. Switching Pixel Wave to a fixed timestep is a change to the
JavaScript and nothing else. That is the payoff for decision 1.

---

## Ordering inside `step`

`step` is one function — locals declared up front, then a guard, then passes:

```wat
(func $step (export "step") (param $dt f32)
  (local $px f32) (local $py f32) … ;; ~40 locals
  (if (global.get $gameOver) (then (return)))

  ;; ===== player =====      rotate, thrust, drag, clamp, wrap, fire
  ;; ===== bots =====        steer, dodge, move, fire
  ;; ===== bullets =====     integrate, cull, collide
  ;; ===== asteroids =====   fall, spawn        (Pixel Wave only)
  ;; ===== ship-vs-ship =====
  ;; ===== level check =====                    (Pixel Wave only)
)
```

The order is load-bearing, and in two directions.

**Bullets are integrated *after* the things that fire them.** A shot spawned in
the player pass moves in the same frame it was created. Put the bullet pass
first and every shot is one frame late — 16 ms of input lag that no player
could name but every player would feel.

**Collisions happen after everything has moved.** All positions are current, so
there is no "half the world has moved" state for a test to see. This is the
standard structure and the reason to keep collision last.

There is a subtler consequence hiding in the bot loop. Bots are updated in index
order, and bot 3's dodge scan reads bullet positions — including any bullet bot 1
fired *this frame*, because bot 1 ran first. Later bots therefore see a very
slightly newer world than earlier ones. It does not matter here (bots dodge only
*player* bullets, `owner == 0`), but it is exactly the asymmetry that makes
index-ordered updates a real bug in games where entities interact with each
other. The fix, when you need it, is double-buffering: read from last frame's
state, write to this frame's.

---

## The player pass, in full

Worth walking, because it is the whole vocabulary of the engine in forty lines.

**Load the record into locals.** Six `f32.load`s at fixed offsets. Everything
after works on locals, which is both faster and much more readable than
repeatedly addressing memory.

**Rotate.** `heading += rotDir * ROT_SPEED * dt`. `$rotDir` is the `f32` the
host pushed — −1, 0 or 1 from a keyboard, or an analogue axis from a stick.

**Thrust.** Acceleration along the heading, which is the only place `$cosf` and
`$sinf` are needed for the player:

```wat
(local.set $ax (f32.mul (call $cosf (local.get $phead)) (global.get $ACCEL)))
(local.set $pvx (f32.add (local.get $pvx) (f32.mul (local.get $ax) (local.get $dt))))
```

**Drag**, as a multiplicative decay:

```wat
(local.set $pvx (f32.mul (local.get $pvx)
  (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))))
```

This is `v *= (1 - DRAG*dt)`, an approximation of exponential decay that is
cheap and correct enough. It has a failure mode worth knowing: if `DRAG * dt`
ever exceeds 1, velocity **flips sign** and the ship flies backwards. With
`DRAG = 0.6` you would need `dt > 1.67 s`. The 50 ms clamp on the host side is
what guarantees it never happens — the two constants are related, and neither
file says so. Now this one does.

**Clamp speed** to `MAX_SPEED` by normalising, which needs the one `f32.sqrt`
per frame the player costs.

**Integrate and wrap.** `x += vx * dt`, then `$wrap` for the toroidal arena.

**Fire.** The burst-fire state machine from [chapter
8](08-globals-and-state.md) — edge detect, arm, fire out one round per
`$BURST_GAP`, pay `$BURST_RECOVER` on the last one.

**Store the record back.** Five `f32.store`s. `alive` is untouched here; the
collision pass owns it.

Load → work in locals → store. That shape repeats for every entity type in both
engines, and it is the single most useful habit in hand-written WAT: memory
accesses are cheap but not free, and locals are where a register allocator can
help you.

---

## What the host still has to do

The engine is ~700 lines and the widget around it is ~800, which surprises
people who expect the wasm to be the bulk. The host's list:

- Build the DOM: canvas, HUD, overlays, touch buttons
- Size the canvas to its container and handle `devicePixelRatio`
- Read keyboard and touch, and reduce them to three numbers
- Own the `requestAnimationFrame` loop and compute `dt`
- Pre-render sprites (Pixel Wave draws its ASCII grids to offscreen canvases once
  at mount, then blits — drawing per-pixel per-frame would be the whole budget)
- Read memory and draw
- Infer sound events from state deltas
- Persist the high score
- Tear all of it down on `destroy()`

**None of that belongs in wasm.** It is DOM work, allocation-heavy, and would
require importing a dozen host functions — which would widen the capability
surface ([chapter 12](12-security-model.md)) for no gain. The division is not
"wasm is faster so put more in it"; it is "wasm owns the part that is pure
computation over its own state".

---

← [Post-MVP features](14-post-mvp-features.md) · [Contents](README.md) · next: [Entity pools](16-entity-pools.md)
