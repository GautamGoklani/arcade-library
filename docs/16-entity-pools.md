# 16 · Case study: entity pools in linear memory

← [Game loop architecture](15-game-loop-architecture.md) · [Contents](README.md) · next: [Maths without a standard library](17-math-without-a-stdlib.md)

---

There is no allocator in either engine. No `malloc`, no free list, no
`memory.grow` — the whole world lives in a fixed layout decided at authoring
time, and "spawning" a bullet means finding a slot whose `active` field is zero
and writing into it.

This chapter is about why that is a good trade, and where it stops being one.

---

## The layout

Pixel Wave, in full:

| Region | Offset | Stride | Count | Bytes | Fields |
|---|---|---|---|---|---|
| player | 0 | — | 1 | 24 | x, y, vx, vy, heading, alive |
| bots | 24 | 40 | 33 | 1,320 | x, y, vx, vy, heading, alive, cooldown, wanderTimer, targetX, targetY |
| bullets | 1,344 | 24 | 160 | 3,840 | x, y, vx, vy, owner, active |
| asteroids | 5,184 | 24 | 20 | 480 | x, y, vx, vy, radius, active |
| score | 5,664 | — | 1 | 4 | f32 |
| lives | 5,668 | — | 1 | 4 | f32 |

**Total: 5,672 bytes.** One 64 KiB page is 65,536, so the entire world occupies
8.7% of the smallest memory wasm can declare. There is no scenario in which this
engine needs to grow, which is why the buffer-detachment problem from [chapter
7](07-javascript-interop.md) simply does not exist for it.

Vector Arena is the same idea at a different scale: 8 bots at stride 32, 80
bullets at stride 24, no asteroids, 2,208 bytes total.

Each region starts where the last one ended, and the memory-map comment shows
the arithmetic:

```wat
;; bots      @24    : stride 40B, MAX_BOTS=33
;;             ends at 24 + 33*40 = 1344
;; bullets   @1344  : stride 24B, MAX_BULLETS=160
;;             ends at 1344 + 160*24 = 5184
```

Showing the sum is what makes changing `MAX_BOTS` a two-minute edit. Without it,
every offset below is a number of unknown provenance.

---

## Addressing

One helper per array, and never open-code the arithmetic:

```wat
(func $bot_addr    (param $i i32) (result i32)
  (i32.add (global.get $BOTS_OFF)    (i32.mul (local.get $i) (global.get $BOT_STRIDE))))
(func $bullet_addr (param $i i32) (result i32)
  (i32.add (global.get $BULLETS_OFF) (i32.mul (local.get $i) (global.get $BULLET_STRIDE))))
(func $ast_addr    (param $i i32) (result i32)
  (i32.add (global.get $AST_OFF)     (i32.mul (local.get $i) (global.get $AST_STRIDE))))
```

`base + i * stride`, which is exactly what a C compiler emits for `bots[i]`.
Then fields come from the static `offset=` immediate, which costs nothing:

```wat
(local.set $a (call $bot_addr (local.get $i)))
(local.set $bx    (f32.load offset=0  (local.get $a)))
(local.set $by    (f32.load offset=4  (local.get $a)))
(local.set $balive(f32.load offset=20 (local.get $a)))
```

Compute the base once into a local, then use offsets. Doing it the other way —
`(i32.add (local.get $a) (i32.const 20))` — is slower and reads worse.

Engines inline these three-instruction helpers, so there is no call overhead to
worry about.

---

## Array-of-structs vs struct-of-arrays

The layout above is **array-of-structs**: all of bot 0's fields, then all of bot
1's. The alternative is **struct-of-arrays**: every `x`, then every `y`, and so
on.

| | AoS (used here) | SoA |
|---|---|---|
| Access one entity's fields | One cache line | One cache miss per field |
| Access one field across all | Strided — wastes most of each line | Sequential, perfect |
| SIMD | Awkward — needs gather | Natural — load four `x`s at once |
| Readability | Reads like a struct | Reads like six parallel arrays |
| Add a field | Change one stride | Move every array below it |

AoS is right here because the access pattern is per-entity: the bot loop reads
nine of bot `i`'s ten fields together, and 40 bytes is well inside one 64-byte
cache line. It also happens to be what the renderer wants — one strided walk
per entity, reading position and heading together.

SoA wins when you sweep one field over everything, which is exactly what a
SIMD-vectorised integrator does: `f32x4` over four `x`s at a time. If these
engines ever used SIMD ([chapter 14](14-post-mvp-features.md)), the bullet pool
is where it would pay, and it would want restructuring first.

At 213 entities neither choice is measurable. At 200,000 it is the whole
performance story. Know which one you have picked and why.

---

## Spawning: the free-slot scan

There is no allocator, so `spawn_bullet` linearly scans for a slot with
`active == 0` and takes the first:

```wat
(func $spawn_bullet (param $owner i32) (param $x f32) (param $y f32)
                    (param $vx f32) (param $vy f32)
  (local $i i32) (local $a i32)
  (local.set $i (i32.const 0))
  (block $done
    (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
      (local.set $a (call $bullet_addr (local.get $i)))
      (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
        (then
          (f32.store offset=0  (local.get $a) (local.get $x))
          (f32.store offset=4  (local.get $a) (local.get $y))
          (f32.store offset=8  (local.get $a) (local.get $vx))
          (f32.store offset=12 (local.get $a) (local.get $vy))
          (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $owner)))
          (f32.store offset=20 (local.get $a) (f32.const 1.0))
          (br $done)))                     ;; take the first free slot and stop
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))
```

Three properties of this that are easy to miss:

**Failure is silent.** If every slot is taken, the loop ends and no bullet
appears. No trap, no error, no return value. For bullets that is genuinely the
right behaviour — the 161st simultaneous bullet is not something a player can
perceive, and 160 is chosen to be comfortably above what the fire rates can
produce. For anything where a dropped spawn matters, return a success flag and
handle it.

**Freeing is one store.** `active = 0` and the slot is available. No coalescing,
no metadata, no fragmentation — the defining advantage of fixed-size slots.

**The scan is O(n) worst case**, 160 iterations for a full pool. Called a few
times per frame, that is a few hundred iterations of a two-instruction test:
irrelevant. If it were called thousands of times per frame the fix is a free
list — store the next free index *in* the inactive slot's first field, and pop
the head in O(1). Twenty lines, and worth it only when you have measured that it
matters.

---

## Iteration and the alive flag

Every pass walks the whole pool and skips inactive slots:

```wat
(block $done
  (loop $lp
    (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
    (local.set $a (call $bot_addr (local.get $i)))
    (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
      (then …))                                   ;; alive
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $lp)))
```

So a pool with 3 live bots out of 33 still costs 33 iterations. The alternative —
swap-remove to keep the live entities packed at the front — halves the average
work and has one significant cost: **entity indices stop being stable**. Anything
holding an index (a bullet remembering who fired it, a target reference, a
renderer's per-entity animation state) breaks the moment an entity moves.

For a 33-slot pool where the whole array is one cache line's worth of stride,
the scan is free and stability is worth more. At ten thousand entities, pack
them and use generational handles instead of raw indices.

Note the flag is compared as a **float**: `f32.gt(alive, 0.0)`, not an integer
test. All entity fields are `f32` so the whole record can be read as one
`Float32Array` from JavaScript without a second view or byte arithmetic
([chapter 3](03-numbers-and-operations.md) has the reasoning). It is a small
cost paid at every iteration, in exchange for a much simpler renderer.

---

## Collision: O(n·m) and why that is fine

Bullet-versus-bot is a nested loop with no spatial structure at all:

```
for each active bullet:
    if owner == player:
        for each alive bot:
            if distance² < HIT_RADIUS²:  both die, score++
```

Worst case in Pixel Wave: 160 × 33 = **5,280 pair tests per frame**. Vector
Arena adds a bullet-versus-bullet dodge scan inside the bot loop — 8 bots × 80
bullets = 640 more.

That sounds bad and is not. Each test is a subtract, two multiplies, an add and
a compare — call it five instructions on data already in cache. Five thousand of
those is on the order of ten microseconds, against a 16.6 ms frame budget. Under
0.1%.

The point generalises: **a quadtree, a spatial hash or a sweep-and-prune would
all be slower here.** Each has to be built or updated every frame, each adds
pointer chasing and cache misses, and each has a fixed cost that a five-thousand-
iteration flat loop does not. The crossover is usually somewhere in the low
thousands of entities. Below that, the naive loop wins, and reaching for the
sophisticated structure is a real and common mistake.

### Squared distances

No `sqrt` in the collision test:

```wat
;; if (dx*dx + dy*dy) < r*r
(f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx))
                 (f32.mul (local.get $dy) (local.get $dy)))
        (f32.mul (global.get $HIT_RADIUS) (global.get $HIT_RADIUS)))
```

`sqrt` is one instruction in wasm, but it has real latency (roughly 10–15 cycles
on most hardware, and it is not pipelined the way a multiply is). Comparing
squares is exact — both sides are non-negative, so the ordering is preserved —
and costs a multiply. In a 5,000-iteration loop that is the difference between
free and noticeable.

Where the engines *do* call `sqrt` is where they need the actual magnitude: the
player's speed clamp, and normalising the bots' steering vector. There is no way
around it there, and it is once per entity rather than once per pair.

---

## When to abandon this design

The pool approach breaks down at four fairly clear boundaries:

**Variable-size entities.** A pool needs one stride. If entities differ in size,
you need either a union sized to the largest (wasteful, but often correct) or
separate pools per type (which is what these engines do — bots, bullets and
asteroids each get their own).

**Unbounded counts.** If the maximum is genuinely unknown you need
`memory.grow` and a real allocator, and with them the detached-buffer problem.
Usually the better answer is to find a defensible cap: 160 bullets is not a
limitation anyone has hit.

**Very large, sparse pools.** 10,000 slots with 50 alive means 99.5% of every
iteration is wasted. Pack the live entities and use generational handles.

**Genuinely dynamic structure** — trees, graphs, growable strings. Pools are for
uniform, independent, bounded records. That is a real constraint and a large
fraction of simulation state fits inside it.

---

## What transfers

Even if you never write WAT, three things here are worth stealing:

**Fixed capacity is a feature.** A cap you chose is better than an out-of-memory
you did not. It also makes the memory footprint a number you can state.

**No allocation in the hot loop.** True in wasm, in C, in Rust, and most of all
in JavaScript, where allocation means the garbage collector eventually pauses
your frame.

**Write the layout down, with the arithmetic.** Nothing in the language records
it, and three separate files depend on it agreeing. The comment *is* the schema.

---

← [Game loop architecture](15-game-loop-architecture.md) · [Contents](README.md) · next: [Maths without a standard library](17-math-without-a-stdlib.md)
