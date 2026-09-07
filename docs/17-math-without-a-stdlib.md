# 17 · Case study: maths without a standard library

← [Entity pools](16-entity-pools.md) · [Contents](README.md) · next: [A grid, and the flood fill that closes a loop](18-grids-and-flood-fill.md)

---

WebAssembly gives you `+ - * / sqrt abs neg min max ceil floor trunc nearest
copysign` and nothing else. No sine, no cosine, no `atan2`, no `exp`, no
random number generator.

A game needs all of those. This chapter is what the engines here do about
it, and it turns out to be a good tour of the trade-offs, because each answer
went a different way.

---

## Random numbers: xorshift32

Wasm has no randomness — deliberately, because randomness is a capability
([chapter 12](12-security-model.md)). You either import one or write one.

Every engine here writes one. Nine lines, three shifts and three xors:

```wat
(global $rng (mut i32) (i32.const 88172645))

(func $rand_f32 (result f32)
  (local $x i32)
  (local.set $x (global.get $rng))
  (local.set $x (i32.xor (local.get $x) (i32.shl   (local.get $x) (i32.const 13))))
  (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
  (local.set $x (i32.xor (local.get $x) (i32.shl   (local.get $x) (i32.const 5))))
  (global.set $rng (local.get $x))
  (f32.div (f32.convert_i32_u (local.get $x)) (f32.const 4294967296.0)))
```

This is Marsaglia's xorshift32. The shift triple `(13, 17, 5)` is one of a small
set that gives the maximum period of 2³² − 1 — they are not arbitrary, and
changing one gives you a much shorter cycle. The seed `88172645` is Marsaglia's
own and must be non-zero: xorshift has a fixed point at zero and would emit
zeros forever.

Three details worth extracting:

**`shr_u`, not `shr_s`.** An arithmetic right shift would feed sign bits back
into the state and destroy the period.

**`convert_i32_u`, not `_s`.** With `_s`, half the outputs are negative, and
`$frand(lo, hi)` built on top returns values below `lo` half the time — enemies
spawning off the left edge, cooldowns that fire instantly. This is a genuinely
easy bug to write and an annoying one to find.

**Divide by 4294967296.0 = 2³².** Gives `[0, 1)`. The float division is one
instruction; multiplying by the reciprocal would be marginally faster and is not
worth the loss of clarity.

Built on it, the only other RNG primitive these engines need:

```wat
(func $frand (param $lo f32) (param $hi f32) (result f32)
  (f32.add (local.get $lo)
           (f32.mul (call $rand_f32) (f32.sub (local.get $hi) (local.get $lo)))))
```

Used for spawn positions, fire cooldowns, wander targets and asteroid timing —
which is essentially all the variety in either game.

**Is xorshift32 good enough?** For a game, comfortably. It passes basic
statistical tests, has a 4-billion period, and costs six instructions. It is
**not** cryptographically secure — the state is recoverable from one output —
and it is not good enough for Monte Carlo work, where PCG or xoshiro256++ are
the modern choices. Know which situation you are in.

The property that matters most here is that it is **internal and pure**. The
sequence depends on nothing outside the module. That is what makes deterministic
replay possible ([chapter 13](13-debugging-and-profiling.md)), and it is why
importing `Math.random()` would have been the worse choice even though it is one
line.

---

## Trigonometry: imported, and why

The other decision went the other way:

```wat
(import "env" "sinf" (func $sinf (param f32) (result f32)))
(import "env" "cosf" (func $cosf (param f32) (result f32)))
```

```js
{ env: { sinf: Math.sin, cosf: Math.cos } }
```

Three options were on the table, and the reasoning is worth spelling out
because it is the recurring shape of this decision.

### Option 1 — import from the host (chosen)

**For:** two lines. Full double precision. Zero binary size.

**Against:** a boundary crossing per call, and — the real cost —
**non-determinism**. `Math.sin` is *not* specified bit-exactly by ECMAScript.
V8, SpiderMonkey and JavaScriptCore may return results differing in the last
ulp, so a replay recorded in Chrome may not reproduce in Firefox. It also means
the module's import list grows, and every host must supply them.

**Why it won here:** the call count is small. The player calls `cosf`/`sinf`
twice per frame when thrusting; each bot calls them zero times, because the
wander steering is pure vector maths — the trig is concentrated in thrust and in
spawn-ring placement at `init`. A few dozen crossings per frame is nothing. And
these games have no replay feature, so the determinism forfeit costs nothing
real.

Two engines here took the forfeit off the table entirely by not needing the
imports: Worm Chase moves on a grid and Sector Defense steers toward a column,
so neither turns through an angle, and both are exactly reproducible on any
host.

### Option 2 — a polynomial approximation in-module

A minimax polynomial on a reduced range. Roughly forty lines for `sinf` to about
1e-7 accuracy:

```wat
;; sketch: reduce x into [-π, π], then evaluate a degree-7 odd polynomial
;;   sin(x) ≈ x - x³/6 + x⁵/120 - x⁷/5040        (Taylor — accurate near 0,
;;                                                 poor near ±π)
;; A minimax (Remez) fit of the same degree has ~40× lower peak error over
;; the whole range, which is why libm uses one and nobody uses Taylor.
```

**For:** deterministic, no imports, self-contained, and often *faster* than a
boundary crossing.

**Against:** forty lines of subtle numerics, a real accuracy budget to reason
about, and range reduction that is genuinely hard to get right near large
arguments.

**Take this option if** you need reproducibility, or if you are calling trig
tens of thousands of times per frame, or if the module must run on a host you do
not control.

### Option 3 — a lookup table

A `(data …)` segment of 4,096 pre-computed sines, indexed by angle, with linear
interpolation between entries.

**For:** very fast, deterministic, simple to reason about.

**Against:** 16 KB of memory for that resolution, and accuracy is bounded by the
table — fine for graphics, wrong for physics that integrates the error.

**Take this option if** angles are quantised anyway, or on a target where a
multiply is expensive and memory is not.

### The general shape

Import when the call is rare and precision matters more than determinism.
Approximate when the call is hot or determinism matters. Tabulate when precision
requirements are low and fixed. It is the same three-way choice in any
environment without a standard library — embedded, GPU shaders, kernel code —
and wasm just makes it unavoidable.

---

## Vector maths, written out

There is no vector type, so every operation is scalar arithmetic on pairs of
locals. Normalising, the most common one:

```wat
;; dist = sqrt(dx² + dy²);  nx = dx/dist;  ny = dy/dist
(local.set $dist (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx))
                                    (f32.mul (local.get $dy) (local.get $dy)))))
(if (f32.gt (local.get $dist) (f32.const 1.0))         ;; guard the divide
  (then
    (local.set $nx (f32.div (local.get $dx) (local.get $dist)))
    (local.set $ny (f32.div (local.get $dy) (local.get $dist)))))
```

**The guard is not optional.** A zero-length vector gives `0/0 = NaN`, and NaN
propagates through every subsequent operation and every comparison returns
false, so an entity that lands exactly on top of another silently stops
responding to anything. The threshold is `1.0` rather than an epsilon because at
sub-pixel separation the direction is meaningless anyway.

These engines use `> 1.0` or `> 0.001` guards before every division in the file.
That habit is worth more in WAT than anywhere else, because there is no
exception to catch and no stack trace when it goes wrong — just a ship that has
quietly become NaN.

---

## Steering: three behaviours, no trigonometry

Bot steering is where this pays off hardest, and it can be done with no trig at
all: everything below is vector arithmetic on the normalised player-relative
direction `(nx, ny)`.

The engine these excerpts are drawn from — a wrap-around dogfighting game whose
bots orbited at range, strafed and dodged — is no longer part of this
repository. The code is kept because the three techniques in it are not
demonstrated anywhere else in the course, and each is quoted in full and
compiles as shown.

### Range keeping, branchlessly

A bot wants to sit at `$ORBIT` distance — approach if far, retreat if near,
strafe if about right. Rather than three branches, it computes three 0-or-1
factors and blends:

```wat
;; farF  = dist > ORBIT + 40
;; nearF = dist < ORBIT - 40
;; midF  = 1 - farF - nearF          ← exactly one of the three is 1
(local.set $farF  (f32.convert_i32_u (f32.gt (local.get $dist)
                    (f32.add (global.get $ORBIT) (f32.const 40.0)))))
(local.set $nearF (f32.convert_i32_u (f32.lt (local.get $dist)
                    (f32.sub (global.get $ORBIT) (f32.const 40.0)))))
(local.set $midF  (f32.sub (f32.sub (f32.const 1.0) (local.get $farF))
                           (local.get $nearF)))
```

`f32.gt` pushes an `i32` of 0 or 1, and `f32.convert_i32_u` turns it into 0.0 or
1.0 — a comparison used as a *weight*. Then:

```wat
;; steer = (nx,ny) * (farF - nearF)          ← toward, or away
;;       + perp(nx,ny) * strafeDir * midF     ← or sideways
(local.set $steerX
  (f32.add (f32.mul (local.get $nx) (f32.sub (local.get $farF) (local.get $nearF)))
           (f32.mul (f32.mul (f32.neg (local.get $ny)) (local.get $bstrafe))
                    (local.get $midF))))
```

`(-ny, nx)` is the perpendicular — a 90° rotation with no trig at all, just a
swap and a negate. `$bstrafe` is ±1, chosen once per bot at spawn, and it is the
entire reason the swarm does not collapse into a single orbit direction.

The 40-unit dead band around `$ORBIT` is hysteresis. Without it a bot sitting
near the threshold flips between approach and retreat every frame and visibly
vibrates.

### Dodging: closest approach

The nicest piece of maths in the engine. For each incoming player bullet, the
bot computes the time at which that bullet will be nearest to it — the standard
closest-point-on-a-ray solution — and steers away only if the miss distance is
small:

```wat
;; rel = bullet.pos - bot.pos ;  v = bullet.vel
;; t   = -(rel · v) / (v · v)                  ← time of closest approach
(local.set $denom (f32.add (f32.mul (local.get $ovx) (local.get $ovx))
                           (f32.mul (local.get $ovy) (local.get $ovy))))
(if (f32.gt (local.get $denom) (f32.const 1.0))         ;; guard again
  (then
    (local.set $t (f32.neg (f32.div
      (f32.add (f32.mul (local.get $relx) (local.get $ovx))
               (f32.mul (local.get $rely) (local.get $ovy)))
      (local.get $denom))))
    (if (f32.lt (local.get $t) (f32.const 0.0)) (then (local.set $t (f32.const 0.0))))
    (if (f32.gt (local.get $t) (f32.const 1.2)) (then (local.set $t (f32.const 1.2))))
    ;; closest point, relative to the bot
    (local.set $cx (f32.add (local.get $relx) (f32.mul (local.get $ovx) (local.get $t))))
    (local.set $cy (f32.add (local.get $rely) (f32.mul (local.get $ovy) (local.get $t))))
    (local.set $cdist (f32.sqrt (f32.add (f32.mul (local.get $cx) (local.get $cx))
                                         (f32.mul (local.get $cy) (local.get $cy)))))
    (if (i32.and (f32.gt (local.get $t) (f32.const 0.0))
                 (f32.lt (local.get $cdist) (global.get $DODGE_RADIUS)))
      (then …add a strong steer along (cx,cy)…))))
```

Two clamps carry the behaviour:

- **`t < 0` → 0**: the bullet's closest approach is in the past; it is moving
  away, ignore it.
- **`t > 1.2` → 1.2**: do not react to threats more than 1.2 seconds out. Without
  this a bot dodges bullets fired from across the arena and never fights.

The dodge steer is weighted `3.0` against the range-keeping steer's `1.0`, so
avoiding a bullet dominates positioning — which is what makes the bots feel
alert rather than merely mobile.

This runs for every bot × every active bullet, 640 tests a frame in the worst
case, and is a few dozen microseconds.

### Leading a shot

Bots fire where the player *will be*, not where they are:

```wat
;; t = dist / bulletSpeed ;  aim at player.pos + player.vel * t
(local.set $leadT (f32.div (local.get $dist) (global.get $BOT_BULLET_SPEED)))
(local.set $ppx (f32.add (local.get $px) (f32.mul (local.get $pvx) (local.get $leadT))))
(local.set $ppy (f32.add (local.get $py) (f32.mul (local.get $pvy) (local.get $leadT))))
```

A first-order lead: it assumes the player keeps their current velocity for
`leadT` seconds, and it does not solve the true quadratic intercept. That
inaccuracy is a *feature* — a perfect solution is unbeatable and unfun, whereas
this one is beaten by changing direction, which is a skill the player can learn.

Note also that the aim uses the direction to the predicted point, normalised,
times the bullet speed. No `atan2` anywhere. **You almost never need `atan2` in
a game** — headings can be carried as normalised direction vectors, and every
rotation you actually want is a perpendicular or a blend.

### Velocity smoothing

The steer produces a *target* velocity; the bot eases toward it:

```wat
;; v += (target - v) * dt * 4.0
(local.set $bvx (f32.add (local.get $bvx)
  (f32.mul (f32.sub (local.get $tx) (local.get $bvx))
           (f32.mul (local.get $dt) (f32.const 4.0)))))
```

An exponential approach — the same shape as the drag in [chapter
15](15-game-loop-architecture.md), and with the same latent hazard: if `dt *
4.0` exceeds 1, the bot overshoots its target and oscillates. At `dt = 0.05`
the factor is 0.2, comfortably stable. The host's `dt` clamp is again what
guarantees it, and again neither file mentions the dependency.

The `4.0` is a responsiveness constant: higher is twitchier, lower is more
ponderous. It is the single most effective knob for changing how the bots
*feel*, and it is not in the tuning table because nobody thought of it as
tuning.

---

## What the pixel-art renderer does instead

Worth noting the division for completeness: Pixel Wave's sprites are ASCII grids
in JavaScript, pre-rendered once at mount to offscreen canvases and then blitted.

```js
const CRAB = [
  '..RR..RR..',
  '.RRRRRRRR.',
  'RR.RRRR.RR',
  // '.' is transparent; each letter indexes a palette
];
```

The engine knows nothing about any of this. It stores a position, a heading and
an alive flag; the renderer decides that bot index `i % 3` is a crab and which
of its two animation frames to draw. Sprite work is allocation-heavy DOM-adjacent
code with no arithmetic worth accelerating — exactly the sort of thing that
belongs on the JavaScript side of the line ([chapter
15](15-game-loop-architecture.md)).

---

## Summary

| Need | Answer here | Alternative, and when |
|---|---|---|
| Random | xorshift32, in-module | Import `Math.random` — never, it costs determinism for nothing |
| sin / cos | Imported from JS | Polynomial, if you need determinism or call it thousands of times |
| sqrt | `f32.sqrt` | Avoid it: compare squared distances |
| atan2 | Not used at all | Carry directions as vectors; perpendicular is `(-y, x)` |
| Normalise | Divide by length, guarded | Reciprocal-sqrt approximation, if profiling demands |
| Rotate 90° | Swap and negate | — |
| Smooth toward a target | `v += (target − v) · dt · k` | Spring-damper, if you want overshoot |
| Distance test | Squared comparison | — |

The recurring lesson: **the standard library you are missing is mostly
`sqrt`-avoidance and guarded division**. Once those two habits are in place,
game maths without a stdlib is not much harder than with one.

---

← [Entity pools](16-entity-pools.md) · [Contents](README.md) · next: [A grid, and the flood fill that closes a loop](18-grids-and-flood-fill.md) · [Glossary](glossary.md)
