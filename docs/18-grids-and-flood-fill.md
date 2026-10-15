# 18 · Case study: a grid, and the flood fill that closes a loop

← [Maths without a standard library](17-math-without-a-stdlib.md) · [Contents](README.md) · next: [Pools that grow their own contents](19-pools-that-grow.md)

---

[Chapter 16](16-entity-pools.md) covered the layout the shooters use: a handful
of fixed-size arrays of records, each entity a struct at `base + i * stride`,
found by scanning for a free slot. That is the right shape when the world is a
few hundred things moving through continuous space.

[Worm Chase](../games/worm-chase/) is not that world. Its world is 768 cells
that never move, and the interesting operation is not "spawn a bullet" but
"decide which cells a closed loop has sealed off". This chapter is about the
layout that suits *that*, the breadth-first search that answers the question,
and one module property the other engines do not have: it imports nothing at
all.

Read it with [`games/worm-chase/game.wat`](../games/worm-chase/game.wat) open.

---

## An array with no `active` field

The whole board:

```wat
;; grid    @0     : stride 4, COLS*ROWS = 32*24 = 768 cells
;;                  byte 0  state   0 = open, 1 = owned, 2 = trail
;;                  byte 1  hazard  0 or 1
;;                  byte 2  mark    flood-fill scratch
;;                  byte 3  epoch   which capture claimed it, 1..6
;;                  cell (c,r) is at (r*COLS + c)*4
;;                  ends at 768*4 = 3072
```

Three differences from an entity pool, all of them consequences of the cells
being fixed:

**There is no free-slot scan, because there are no free slots.** Every cell
always exists. `$cell_addr` is the only lookup, and it is arithmetic rather than
a search:

```wat
(func $cell_addr (param $c i32) (param $r i32) (result i32)
  (i32.add (global.get $GRID_OFF)
    (i32.mul (i32.add (i32.mul (local.get $r) (global.get $COLS)) (local.get $c))
             (global.get $CELL_STRIDE))))
```

Row-major, exactly as C would lay out `cell[r][c]`. The inverse shows up in the
BFS, where the queue stores flat indices and has to get back to coordinates:
`c = idx % COLS`, `r = idx / COLS`, which in WAT is `i32.rem_u` and `i32.div_u`.
Both are unsigned because the index cannot be negative and the signed forms
would cost a check nothing needs.

**The fields are bytes, not floats.** A cell's state has three possible values
and its hazard flag has two, so `i32.load8_u` / `i32.store8` is the right
instruction and a four-byte cell holds four fields with nothing wasted:

```wat
(i32.load8_u offset=0 (local.get $a))    ;; state
(i32.store8 offset=1 (local.get $a) (i32.const 1))   ;; set hazard
```

Alignment is not a concern — byte accesses have none — but the stride is kept at
4 anyway so `i32.store` can clear a whole cell in one instruction, which is what
`$clear_grid` does at the start of every level:

```wat
(i32.store (call $idx_addr (local.get $i)) (i32.const 0))
```

One instruction zeroes state, hazard, mark and epoch together. A 3-byte cell
would have saved 768 bytes and cost that.

> **Post-MVP note.** With the bulk-memory proposal, `memory.fill` clears the
> whole grid in one instruction instead of a 768-iteration loop. This engine
> stays strict-MVP on purpose — see [chapter 14](14-post-mvp-features.md) — and
> the loop runs once per level, which is not a place where 768 stores matter.

**One byte exists purely for the renderer.** `epoch` is 1–6, cycling, stamped on
each cell as a capture claims it; the widget shades territory by it, so the
board shows which push took which ground. It is a good example of the boundary
in [chapter 7](07-javascript-interop.md) working in your favour: the renderer
needs a per-cell value that the simulation does not care about, and the cheapest
way to ship 768 of them across the boundary is to put them *in* the cell record
that JavaScript is already walking.

---

## The question: what does "enclosed" mean?

The rule of the game is that when the worm re-enters its own territory,
everything its trail sealed off becomes territory too. That needs a definition
of *sealed off*, and the obvious ones are all traps:

- **Point-in-polygon** requires the trail to be a polygon. It is not, once it
  doubles back across itself or touches the board edge.
- **Tracing the loop's interior** requires a consistent winding direction. A
  trail that leaves territory at one point and re-enters at an arbitrary other
  point does not have one.
- **Filling from a seed inside the loop** requires knowing a cell that is
  inside, which is the original question again.

`$capture` inverts it. Convert the trail to territory, then flood **inward from
the four edges of the board**, marking every cell the outside can still reach.
Whatever is left unmarked and unowned is, by definition, fenced in:

```wat
(call $flood_outside)
;; ... then, for every cell:
(if (i32.and
      (i32.ne (i32.load8_u offset=0 (local.get $a)) (global.get $OWNED))
      (i32.eqz (i32.load8_u offset=2 (local.get $a))))     ;; not marked
  (then
    (i32.store8 offset=0 (local.get $a) (global.get $OWNED))
    ...))
```

The inversion is the whole trick, and it is not a WebAssembly trick — it is the
same reasoning behind flood-filling a mask from outside rather than inside in
any image-processing library. What is worth noticing is that it makes the
algorithm *indifferent to shape*: a figure-of-eight, a loop drawn back across
old territory, a trail that runs along the board edge for ten cells all fall out
correctly, because none of them can produce an outside-reachable cell that
should have been captured.

---

## A queue with no allocator

Breadth-first search needs a frontier queue. There is no allocator ([chapter
16](16-entity-pools.md) again: no `malloc`, no free list), so the queue is a
region of linear memory sized for the worst case:

```wat
;; queue   @3072  : stride 4, one i32 cell index per slot, 768 slots
```

768 slots, because the worst case is every cell entering the queue once, and
that bound is guaranteed by the mark-on-push discipline: a cell is marked at the
moment it is pushed, never at the moment it is popped, so it can never be queued
twice. Get that backwards and the queue overflows on a large open board — the
classic BFS bug, and here it would not throw, it would write over the chaser
records at 6144.

Head and tail are two globals:

```wat
(global $qh (mut i32) (i32.const 0))
(global $qt (mut i32) (i32.const 0))

(func $qpush (param $idx i32)
  (i32.store (i32.add (global.get $QUEUE_OFF) (i32.mul (global.get $qt) (i32.const 4)))
             (local.get $idx))
  (global.set $qt (i32.add (global.get $qt) (i32.const 1))))
```

No wraparound, because the queue is never reused within a search and both
cursors reset at the start of the next one. A ring buffer would be strictly more
code for a case that cannot arise.

The search itself is the shape every structured-control-flow BFS takes in WAT —
a `block` for the exit and a `loop` for the body, with `br_if` as the test, in
exactly the pattern [chapter 4](04-control-flow.md) describes:

```wat
(block $bfs
  (loop $blp
    (br_if $bfs (i32.ge_s (global.get $qh) (global.get $qt)))     ;; queue empty
    (local.set $idx (i32.load (i32.add (global.get $QUEUE_OFF)
                                       (i32.mul (global.get $qh) (i32.const 4)))))
    (global.set $qh (i32.add (global.get $qh) (i32.const 1)))
    (local.set $c (i32.rem_u (local.get $idx) (global.get $COLS)))
    (local.set $r (i32.div_u (local.get $idx) (global.get $COLS)))
    (call $visit (i32.sub (local.get $c) (i32.const 1)) (local.get $r))
    (call $visit (i32.add (local.get $c) (i32.const 1)) (local.get $r))
    (call $visit (local.get $c) (i32.sub (local.get $r) (i32.const 1)))
    (call $visit (local.get $c) (i32.add (local.get $r) (i32.const 1)))
    (br $blp)))
```

Four `$visit` calls rather than a neighbour loop with a lookup table. Unrolled,
it is four calls; as a loop it would need the table in memory or a `br_table`
dispatch, and would read worse for no gain at a fixed arity of four.

**Cost.** The fill clears 768 marks, seeds at most 112 border cells, and visits
each cell at most once — a few thousand instructions, on the single tick that
closes a loop and on no other. That is the shape to aim for with any expensive
grid operation: not "make it fast", but "make it happen rarely, and prove when".

---

## Two clocks, and the fraction between them

[Chapter 15](15-game-loop-architecture.md) worked through who owns the clock:
JavaScript calls `step(dt)`, the engine integrates. Worm Chase does not
integrate — it *ticks*. The worm advances one whole cell at a time, and the
chasers advance on a second, slower clock:

```wat
(global.set $acc (f32.add (global.get $acc) (local.get $d)))
(block $wdone
  (loop $wlp
    (br_if $wdone (f32.lt (global.get $acc) (call $tick_len)))
    (br_if $wdone (i32.gt_s (local.get $guard) (i32.const 4)))
    ...
    (global.set $acc (f32.sub (global.get $acc) (call $tick_len)))
    (call $tick_worm)
    (br $wlp)))
```

This is the fixed-timestep accumulator from chapter 15, with the same guard
against the spiral of death: at most 4 ticks per call, whatever `dt` says. Two
independent accumulators is what lets the difficulty curve move the two speeds
separately — and they are deliberately *not* multiples of each other, because a
chaser ticking in lockstep with the worm is either always catchable or never,
depending on parity.

A tick at level 1 is 140ms. Drawing the worm only where the engine says it is
would animate it at seven frames a second on a sixty-frame canvas. So the engine
exports the leftover:

```wat
(func $get_tick_frac (export "get_tick_frac") (result f32)
  (call $clampf (f32.div (global.get $acc) (call $tick_len)) (f32.const 0.0) (f32.const 1.0)))
```

and keeps the previous cell alongside the current one, so the renderer can
interpolate:

```js
var f  = e.get_tick_frac();
var wx = e.get_prev_x() + (e.get_head_x() - e.get_prev_x()) * f;
```

This is the division of labour the whole repository is built on, in its clearest
form. **Where the worm *is* is simulation; where to draw it between two cells is
presentation.** The engine never rounds a position for the screen's benefit, and
the renderer never decides anything the next tick depends on.

---

## A module with no imports

Pixel Wave, Grid Breaker and Asteroid Miner all begin the same way:

```wat
(import "env" "sinf" (func $sinf (param f32) (result f32)))
(import "env" "cosf" (func $cosf (param f32) (result f32)))
```

WebAssembly has no trigonometry instruction ([chapter
17](17-math-without-a-stdlib.md) explains why importing is the right answer
there). Worm Chase imports nothing:

```js
WebAssembly.instantiate(bytes, {})   // the whole import object
```

Nothing here turns through an angle. Every heading is one of four `(dx, dy)`
pairs, every collision test is `i32.eq`, and the one piece of real arithmetic —
the difficulty curve — is integer multiply and clamp. The `sqrt` avoidance from
chapter 17 does not even arise, because the AI steers by Manhattan distance,
which is two `abs` and an add.

Three things follow, and they are worth wanting:

- **The module is a pure function** of `init`, the input stream and the `dt`
  sequence. Its RNG is an in-module xorshift seeded to a constant, so level 1 is
  the same board every run.
- **A headless bench can replay a run exactly**, which is how the difficulty
  numbers in the game's README were arrived at: drive the compiled binary with a
  scripted pilot, count deaths, classify them.
- **There is no import surface to get wrong.** Nothing in the linking step can
  fail, and the `LinkError` class of startup bug simply does not exist for this
  module.

None of that is a reason to avoid imports when you need them. It *is* a reason
to notice when you do not: an import is a boundary crossing, a dependency, and a
place where determinism can leak out of your module without announcing itself.

---

## Summary

| Question | Entity pools (ch. 16) | This grid |
|---|---|---|
| Where is entity *i*? | `base + i * stride`, found by scanning `active` | Every cell exists; `(r*COLS + c) * stride` |
| Field width | `f32` — positions are continuous | `u8` — four flags in four bytes |
| Clearing | Set `active = 0` on one record | `i32.store` zeroes a whole cell |
| Expensive operation | Pairwise collision, every frame | Flood fill, on the tick that closes a loop |
| Scratch space | None needed | A fixed 768-slot BFS queue, sized for the worst case |
| Imports | `sinf`, `cosf` | None |

The general lesson is the one that keeps recurring in Part III: **the layout is
the design decision, and the algorithm follows from it.** A pool of structs
makes "which of these is near that one?" cheap and "what region is enclosed?"
nearly impossible. A grid of bytes does the reverse. Neither is the better
layout; they are answers to different questions, and choosing one is choosing
which questions stay easy.

---

← [Maths without a standard library](17-math-without-a-stdlib.md) · [Contents](README.md) · next: [Pools that grow their own contents](19-pools-that-grow.md) · [Glossary](glossary.md)
