# 19 · Case study: pools that grow their own contents

← [A grid, and the flood fill that closes a loop](18-grids-and-flood-fill.md) · [Contents](README.md) · next: [Giving each entity its own intent](20-per-entity-intent.md)

---

[Chapter 16](16-entity-pools.md) described a pool as a fixed array of records
where "spawning" means finding a slot whose `active` field is zero. Every
example there had one property in common: **something outside the pool decided
what went into it**. The player fires, a bullet appears. A wave starts, enemies
appear.

[Asteroid Miner](../games/asteroid-miner/) breaks that. A rock in the pool, when
destroyed, puts two rocks *into the same pool* — while the loop that destroyed
it is still walking the array. This chapter is about why that turns out to be a
non-problem, what the interesting failure is, and one boundary decision that has
nothing to do with pools at all: the resolution you draw at.

Read it with [`games/asteroid-miner/game.wat`](../games/asteroid-miner/game.wat)
open.

---

## The split

```wat
(func $split_rock (param $a i32)
  ...
  (f32.store offset=24 (local.get $a) (f32.const 0.0))   ;; parent: active = 0
  ...
  (call $spawn_rock (local.get $x) (local.get $y) (i32.sub (local.get $size) (i32.const 1))
    (f32.add (local.get $vx) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
    (f32.add (local.get $vy) (f32.mul (call $cosf (local.get $ang)) (local.get $sp))))
  ...)
```

That is the whole mechanic. The parent is deactivated, and `$spawn_rock` — the
same free-slot scan from chapter 16 — writes two children somewhere in the
array.

**Nothing recurses**, and it is worth being precise about why, because "an
entity that creates entities" sounds like it should. A recursive formulation
would have `$split_rock` call itself for each child, which needs a depth bound,
a stack that can hold it, and a story about what happens when a boulder's whole
subtree is created inside one frame. None of that exists here. The children are
ordinary records in an ordinary array, and the only thing that ever advances
them is the same `$step_rocks` loop that advances everything else, on some
later frame.

**Nor does it matter whether the current loop reaches them.** A child written
into a slot the bullet loop has already passed simply starts moving next frame;
a child written into a slot ahead of the cursor gets one frame of movement
sooner. Neither is observable — these are drifting rocks whose starting
velocity is randomised anyway. Iteration-order questions only bite when the
order is load-bearing, and here it is not.

This is the general shape worth taking away: **a pool with an `active` flag is
already a queue of work for the next frame.** Writing into it mid-iteration is
safe precisely because nothing in the design depends on when the write is
observed.

---

## The interesting failure is a full pool

`$spawn_rock` scans for a free slot and, finding none, does nothing:

```wat
(block $done
  (loop $lp
    (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
    ...
    (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
      (then ... (return)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $lp)))
;; falls out having spawned nothing
```

So a full pool **silently drops the children**. A boulder is destroyed and
nothing replaces it.

That looks like a bug and is a deliberate choice, and the reasoning generalises
past this game. The alternative — refuse to destroy the parent when the pool is
full — sounds more correct and is much worse: it means a player shooting into a
crowded field watches their shots land and do nothing, for a reason that is
invisible on screen and impossible to reason about. Between "the field is
slightly smaller than the rules imply" and "the game stops responding to the
only verb you have", the first is the failure you want.

The general rule for a fixed pool: **decide what dropping looks like, and make
it the least surprising thing available.** Pixel Wave drops bullets the same
way — a player who fires with all 160 bullets alive gets no bullet, which is
indistinguishable from a fire-rate cap. Grid Breaker's MULTI power-up drops the
third ball if the pool is full. In every case the drop is invisible or reads as
a rule, never as a stall.

Sizing then becomes an ordinary engineering question rather than a correctness
one. Twenty-eight rock slots for ten boulders looks tight — 10 boulders is
10 + 20 + 40 = 70 rocks if the whole field were reduced to pebbles
simultaneously — but pebbles are *destroyed* rather than split, the field is
topped up toward a target count rather than a maximum, and the pool has never
been observed full in benching. The bound that matters is the realistic
concurrent population, not the theoretical total.

---

## Resource state, and where it lives

The other thing this engine has that the earlier ones do not is **resources**:
fuel and cargo, which are not positions and do not belong to any entity.

They are globals:

```wat
(global $fuel (mut f32) (f32.const 100.0))
(global $cargo (mut f32) (f32.const 0.0))
```

[Chapter 8](08-globals-and-state.md) made the case in the abstract; this is what
it looks like in practice. There is exactly one fuel level, JavaScript reads it
through `get_fuel()` once a frame to size a bar, and nothing walks it in a loop.
A global is one instruction to read and needs no address arithmetic. Grid
Breaker puts its score *in memory* at a fixed offset, which is also right —
its renderer was already walking memory for the tile grid, so the score came
along for free. The question is not "which is better" but "is this value on a
path something already traverses".

What is worth copying is that the resources are **converted, not just spent**.
Thrust turns fuel into velocity; mining turns rocks into gems; only the depot
turns gems into progress. That last step is the one that makes the other two
decisions rather than habits, and it is implemented as a drip rather than a
single event:

```wat
(block $done
  (loop $lp
    (br_if $done (f32.lt (global.get $deliverAcc) (global.get $DELIVER_EVERY)))
    (br_if $done (f32.le (global.get $cargo) (f32.const 0.0)))
    (global.set $deliverAcc (f32.sub (global.get $deliverAcc) (global.get $DELIVER_EVERY)))
    (global.set $cargo (f32.sub (global.get $cargo) (f32.const 1.0)))
    ...
    (br $lp)))
```

An accumulator, the same pattern as the fixed-timestep loop in [chapter
15](15-game-loop-architecture.md) and the tick clock in [chapter
18](18-grids-and-flood-fill.md), used here for a game-design reason rather than
a numerical one: a hold that emptied in one frame would be a number changing,
where a drip is a sequence you can hear, and it costs the seconds that make
*when to come home* a real decision.

---

## A boundary decision: the resolution you draw at

Nothing in this section is about WebAssembly, which is the point of including
it. [Chapter 15](15-game-loop-architecture.md) drew the line as *simulation is
the engine's, presentation is JavaScript's*. Asteroid Miner is the clearest test
of that line in the repository, because it wants to look like a machine from
1983 and the engine knows nothing about it.

The renderer draws into a 320×240 buffer and blows it up 3× with smoothing off:

```js
var low = document.createElement('canvas');
low.width = WORLD_W / LOW_SCALE;    // 320
low.height = WORLD_H / LOW_SCALE;   // 240
var g = low.getContext('2d');
g.imageSmoothingEnabled = false;
// ...then, every frame, in world units:
g.setTransform(1 / LOW_SCALE, 0, 0, 1 / LOW_SCALE, 0, 0);
```

Every mark rasterises at the low resolution — a rotated rock, the depot's
rings, a particle — so nothing on screen can be finer than the sprites are.
**The engine still works in 960×720 and did not change by one constant**, and
that is the whole demonstration: the simulation's units are a coordinate
system, not a picture. The `1/3` transform is the entire adapter.

That last claim holds because Asteroid Miner was *drawn* for 320×240. When
Pixel Wave, Grid Breaker and Worm Chase were retrofitted to the same look, the
transform alone was not enough: their draw code had been written at full
resolution, with bevels one and three pixels wide, and a rectangle three pixels
wide at x = 31 lands between low-res pixels and comes out as a half-tinted
fringe. The fix went into the adapter rather than into sixty call sites — the
buffer's `fillRect` and `drawImage` round their edges to whole low-res pixels —
and the engines, again, did not change by one constant.

Two smaller consequences of committing to a resolution, both of which are the
kind of thing a "pixel-art filter" bolted on afterwards gets wrong:

- **Screen shake moves in whole low-res pixels.** A sub-pixel offset resamples
  the entire field every frame, which is exactly the smooth, floating look the
  buffer exists to prevent.
- **No glow anywhere.** `shadowBlur` is a giveaway that a picture was made after
  about 1995 — brightness on that hardware came from choosing a brighter
  colour, so a bullet here is a dark-amber block with a pale core.

If the goal had been a modern look, none of this would touch the engine either.
That is the property to keep: when the presentation layer can be rewritten
end-to-end without opening `game.wat`, the boundary is in the right place.

---

## Summary

| Question | Answer here |
|---|---|
| An entity spawns entities — does the loop need protecting? | No, if nothing depends on *when* the write is seen. A pool with an `active` flag is already next frame's work queue |
| Recursion? | None. The parent deactivates itself and writes children into the array |
| What happens when the pool is full? | The children are dropped. Choose the drop that is invisible or reads as a rule, never one that stalls the player's only verb |
| How big should the pool be? | The realistic concurrent population, not the theoretical total |
| Where do resources live? | A global, unless something already walks the memory they would sit in |
| Who decides how the game looks? | JavaScript, entirely. A 3× low-res buffer changed no engine constant |

---

← [A grid, and the flood fill that closes a loop](18-grids-and-flood-fill.md) · [Contents](README.md) · next: [Giving each entity its own intent](20-per-entity-intent.md) · [Glossary](glossary.md)
