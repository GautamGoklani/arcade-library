# 05 · Linear memory

← [Control flow](04-control-flow.md) · [Contents](README.md) · next: [Functions and tables](06-functions-tables.md)

---

A wasm module's memory is **one flat, contiguous, mutable array of bytes**,
starting at address 0, addressed by `i32`. That is the entire memory model.

No heap. No stack in memory (the *call* stack is separate and invisible). No
objects, no allocator, no garbage collector, no protection pages, no virtual
addressing. If you want any of those, you build them, or your source language's
runtime brings them along.

This is the chapter that everything else rests on. It is also the one where
wasm feels most like the 1980s, in a way that turns out to be clarifying.

---

## Declaring it

```wat
(memory 1)                        ;; 1 page = 65536 bytes, no maximum
(memory 1 16)                     ;; 1 page initial, 16 pages maximum
(memory (export "memory") 1)      ;; …and let the host see it
```

The unit is a **page**: 65,536 bytes, always. Never a byte count.

- `memory.size` → current size **in pages**
- `memory.grow n` → grow by `n` pages; returns the *previous* size, or **`-1`**
  if it failed. It does not trap. Check the result — this is a classic silent
  bug, since `-1` used as a base address will happily compute nonsense.

```wat
(if (i32.eq (memory.grow (i32.const 4)) (i32.const -1))
  (then (unreachable)))            ;; out of memory
```

Growing may **detach and reallocate** the underlying buffer. In JavaScript that
invalidates every existing typed-array view — the classic symptom is an
`ArrayBuffer` that is suddenly `byteLength === 0`. [Chapter
7](07-javascript-interop.md) covers the fix; the short version is to re-create
your views after any call that could grow memory.

Every engine here declares exactly one page and never grows. Everything Pixel
Wave needs — the player, 33 enemies, 160 bullets, 20 asteroids, score, lives —
occupies 5,672 bytes. That is 8.7% of a single page, and it means the entire
world state is one cache-friendly block with no allocation anywhere in the frame.

---

## Loads and stores

```wat
(f32.load  (i32.const 100))              ;; read 4 bytes as f32 from address 100
(f32.store (i32.const 100) (f32.const 1.5))

(i32.load  (local.get $addr))
(i32.store (local.get $addr) (local.get $value))
```

### Narrow accesses

You can load and store less than the type's width. Loads must say how to fill
the top bits:

```wat
i32.load8_s   i32.load8_u    i32.load16_s   i32.load16_u
i64.load8_s   …  i64.load32_s  i64.load32_u
i32.store8    i32.store16     i64.store32   ;; stores just truncate — no _s/_u
```

`i32.load8_u` is how you read a byte. There is no byte type; this is it.

### `offset` is free

Every memory instruction takes a static `offset` and `align`:

```wat
(f32.load offset=16 (local.get $base))    ;; == load(base + 16)
```

The offset is encoded in the instruction, folded into the address at compile
time, and costs nothing. **This is the mechanism for struct fields**, and it is
why the entity code in these engines reads the way it does:

```wat
;; bot record: x@0 y@4 vx@8 vy@12 heading@16 alive@20 cooldown@24 …
(f32.load offset=0  (local.get $a))    ;; bot.x
(f32.load offset=16 (local.get $a))    ;; bot.heading
(f32.load offset=20 (local.get $a))    ;; bot.alive
```

Compute the record's base address once into a local, then use offsets for every
field. Writing `(i32.add (local.get $a) (i32.const 16))` instead is both slower
and much harder to read.

### Alignment is a hint, not a rule

```wat
(f32.load align=4 (local.get $a))   ;; "I promise this is 4-byte aligned"
```

`align` is a **promise to the engine**, not a constraint. An unaligned access
does not trap — it just may be slower. Declaring an alignment larger than the
actual address is allowed but pointless; the engine may generate a fast path
that then has to be fixed up. If you are unsure, omit it: the default is the
natural alignment of the type, which is what you want.

The one place it matters is atomics ([chapter 14](14-post-mvp-features.md)),
where misalignment **does** trap.

### Endianness

Little-endian, always, everywhere. The specification fixes it, so `i32.store`
followed by `i32.load8_u` gives you the low byte on every platform. No
byte-swapping, no host variation, ever. One fewer thing to think about than in
native code.

### Bounds

Every access is bounds-checked against the current memory size. Out of range
**traps** — a `RuntimeError` in the host, and the call unwinds. There is no
segfault, no adjacent-process corruption, and no way to reach the host's memory.

This is the load-bearing safety property of the whole format. It is also
usually free at runtime: 64-bit engines reserve 4 GiB of address space per
memory and let the MMU do the checking, so the fast path has no explicit
comparison at all.

But note what it does **not** protect: writing past the end of *your own* array
into *your own* next array is completely legal. Nothing in wasm knows those are
two arrays. Heap corruption inside a module is entirely possible; see [chapter
12](12-security-model.md).

---

## Data segments

Bytes written into memory at instantiation, before anything runs:

```wat
(data (i32.const 0) "hello\00")
(data (i32.const 1024) "\01\02\03\04")
```

Escapes are `\XX` hex pairs, plus `\n`, `\t`, `\\`, `\"`. A "string" in wasm is
a data segment plus a convention — you supply the length or the terminator
yourself. There is no string type and nothing knows about UTF-8.

Data segments are how compiled languages ship string literals, jump tables and
constant lookup tables. No engine here uses one: the world is generated at
`init` rather than loaded.

---

## Laying out a struct by hand

This is the core skill. There is no `struct` keyword — you decide the field
order, add up the sizes, and write the numbers down.

Pixel Wave's bot record:

| Field | Offset | Type | Meaning |
|---|---|---|---|
| `x` | 0 | f32 | position |
| `y` | 4 | f32 | |
| `vx` | 8 | f32 | velocity |
| `vy` | 12 | f32 | |
| `heading` | 16 | f32 | radians |
| `alive` | 20 | f32 | 0.0 / 1.0 |
| `cooldown` | 24 | f32 | seconds until it can fire |
| `wanderTimer` | 28 | f32 | seconds until it re-picks a target |
| `targetX` | 32 | f32 | where it is wandering to |
| `targetY` | 36 | f32 | |

**Stride: 40 bytes.** An array of 33 of them is 1,320 bytes.

The addressing helper is three instructions:

```wat
(global $BOTS_OFF   i32 (i32.const 24))
(global $BOT_STRIDE i32 (i32.const 40))

(func $bot_addr (param $i i32) (result i32)
  (i32.add (global.get $BOTS_OFF)
           (i32.mul (local.get $i) (global.get $BOT_STRIDE))))
```

`base + index * stride`, which is exactly what a C compiler emits for `bots[i]`.
Writing it by hand is the moment array indexing stops being magic.

### Choosing the stride

Keep it a multiple of the largest field's size — 40 is a multiple of 4, so every
`f32` in every record is naturally aligned. A stride of 38 would put half your
fields on odd addresses for no gain.

Powers of two let the multiply become a shift, which is one reason
`asteroid-miner` uses 32 bytes per rock. Whether that is worth constraining your
field count is a judgement call; at these sizes it is not measurable, and Pixel
Wave's 40 was chosen for the fields it needed rather than for the shift.

---

## The full map, and why it is a table in a comment

Every engine here opens with its memory map as a comment block, and this is not
decoration — it is the schema. Nothing in the language records it, nothing
checks it, and **three separate files depend on it agreeing**: the `.wat`, the
JavaScript renderer that reads the memory, and the documentation.

`games/pixel-wave/game.wat`:

```wat
;; ================= MEMORY LAYOUT =================
;; player    @0     : x,y,vx,vy,heading,alive                 (6 f32 = 24 B)
;; bots      @24    : stride 40B, MAX_BOTS=33
;;             x,y,vx,vy,heading,alive,cooldown,wanderTimer,targetX,targetY
;;             ends at 24 + 33*40 = 1344
;; bullets   @1344  : stride 24B, MAX_BULLETS=160 (x,y,vx,vy,owner,active)
;;             ends at 1344 + 160*24 = 5184
;; asteroids @5184  : stride 24B, MAX_AST=20 (x,y,vx,vy,radius,active)
;;             ends at 5184 + 20*24 = 5664
;; score @5664  lives @5668
;; ===================================================
```

Notice the arithmetic is written out. Each region's start is the previous
region's end, and if you change `MAX_BOTS` from 33 to 40 you must recompute
every offset below it. Showing the sum is what makes that a two-minute edit
instead of a debugging session.

**Regions in order of how often they change.** Scalars last, at the top of the
address space, so adding one does not move anything. Getting this backwards
means every new counter shifts the entity arrays and invalidates every offset
constant in the renderer.

---

## Building an allocator

You will not need one for a fixed world, but the moment you have variable-sized
data you do. The simplest useful allocator is a **bump allocator** — twelve
lines, no free:

```wat
(global $heap (mut i32) (i32.const 65536))   ;; start after the static region

(func $alloc (param $size i32) (result i32)
  (local $p i32)
  (local.set $p (global.get $heap))
  ;; round up to 8-byte alignment
  (global.set $heap
    (i32.and (i32.add (i32.add (local.get $p) (local.get $size)) (i32.const 7))
             (i32.const -8)))
  ;; grow if we have run past the end
  (if (i32.gt_u (global.get $heap)
                (i32.mul (memory.size) (i32.const 65536)))
    (then
      (if (i32.eq (memory.grow (i32.const 1)) (i32.const -1))
        (then (unreachable)))))
  (local.get $p))
```

That is genuinely all a bump allocator is, and for a program with an
arena-per-frame lifetime — reset `$heap` at the top of each frame — it is both
the fastest and the simplest option available.

Add `free` and you need a free list, size classes, coalescing, and the fragmentation
problem. That is `malloc`, it is a few thousand lines, and it is a large part of
what makes a compiled-C wasm binary bigger than you expected.

**The pool approach in these engines avoids the question entirely**: every
entity array is fixed-size, allocation is "find a slot with `active == 0`", and
freeing is "set `active = 0`". [Chapter 16](16-entity-pools.md) is about why
that trade is usually right for a simulation.

---

## Bulk memory operations

Shipped and universally available since 2020 ([chapter
14](14-post-mvp-features.md)):

```wat
(memory.copy (dest) (src) (len))     ;; memmove semantics — overlap is fine
(memory.fill (dest) (byte) (len))    ;; memset
(memory.init $seg (dest) (off) (len))
(data.drop $seg)
```

Before these, `memset` was a hand-written byte loop. `memory.fill` is an engine
intrinsic and orders of magnitude faster. If you are zeroing a region — clearing
an entity pool at `init`, for example — reach for it.

---

## Practical rules

1. **Write the layout as a comment, with the arithmetic shown.** It is the
   schema; nothing else records it.
2. **One address helper per array.** `$bot_addr`, `$bullet_addr`, `$ast_addr`.
   Never open-code `base + i*stride`.
3. **Compute the base into a local, then use static `offset=`.** Free, and it
   makes the field names visible.
4. **Order regions by volatility.** Fixed arrays first, scalars last.
5. **Keep strides a multiple of the widest field.**
6. **Check `memory.grow`'s return value.** It gives you `-1`, not a trap.
7. **Re-create JavaScript typed-array views after anything that might grow.**
8. **Zero what you assume is zero.** A memory is zeroed at instantiation, but not
   at your `init` — a restart that does not clear the pools inherits the last
   run's corpses. Every engine here clears explicitly in `init` for exactly this
   reason.

---

← [Control flow](04-control-flow.md) · [Contents](README.md) · next: [Functions and tables](06-functions-tables.md)
