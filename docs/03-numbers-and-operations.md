# 03 · Numbers and operations

← [Reading and writing WAT](02-wat-syntax.md) · [Contents](README.md) · next: [Control flow](04-control-flow.md)

---

The MVP has **four value types**:

| Type | Is | Notes |
|---|---|---|
| `i32` | 32 bits, no sign | Also the type of every pointer, every boolean, every index |
| `i64` | 64 bits, no sign | Crosses to JavaScript as `BigInt` |
| `f32` | IEEE-754 single | |
| `f64` | IEEE-754 double | The type a JavaScript `number` actually is |

There is no `bool`, no `char`, no `string`, no struct, no array, no pointer
type, no unsigned type. Post-MVP adds `v128` (SIMD) and opaque reference types
`funcref` / `externref`; [chapter 14](14-post-mvp-features.md) covers those.

Everything else — a string, a linked list, a sprite, an enemy — is bytes in
[linear memory](05-linear-memory.md) that you interpret by convention.

---

## Signedness lives in the operator

This is the idea that most often catches people, and it is genuinely elegant
once it clicks.

An `i32` is 32 bits. Whether those bits mean −5 or 4294967291 is **not a
property of the value** — it is a property of the operation you apply. So
operations where the answer differs come in two flavours, suffixed `_s` and
`_u`:

```wat
i32.div_s   i32.div_u        ;; division
i32.rem_s   i32.rem_u        ;; remainder
i32.lt_s    i32.lt_u         ;; less-than (and le/gt/ge)
i32.shr_s   i32.shr_u        ;; right shift: arithmetic vs logical
i32.trunc_f32_s  …_u         ;; float → int conversion
i32.load8_s  i32.load8_u     ;; sub-width loads: sign-extend or zero-extend
```

Operations where the bit pattern makes the answer identical have **one** form:

```wat
i32.add   i32.sub   i32.mul
i32.and   i32.or    i32.xor   i32.shl
i32.eq    i32.ne
```

Two's complement is why: addition, subtraction and multiplication produce the
same bits either way. Division does not, and neither does ordering.

### The bug this causes

```wat
;; WRONG if $count could ever be negative or if $i wraps
(br_if $done (i32.ge_u (local.get $i) (local.get $count)))
```

With `_u`, `-1` compares as 4294967295 — greater than everything. With `_s` it
compares as less than zero. A loop counter that decrements past zero will
either exit immediately or run essentially forever, depending purely on which
suffix you typed. Both engines here use `_s` for loop bounds:

```wat
(br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
```

Pick a rule and hold it: **`_s` for indices and counts, `_u` for addresses and
bit manipulation.**

---

## Booleans are `i32`

There is no boolean type. Comparisons push `1` or `0` as an `i32`, and every
conditional treats "nonzero" as true.

```wat
(if (i32.lt_s (local.get $a) (local.get $b))
  (then …))
```

`i32.eqz` tests for zero and doubles as logical NOT. There is no `!=` against
zero — the idiom is just to use the value directly.

Both engines store booleans in linear memory as **`f32` 0.0 / 1.0** — the
`alive` and `active` fields of every entity. That is unusual and deliberate: the
entity records are otherwise all `f32`, and keeping one uniform type means the
whole record can be read as a single `Float32Array` from JavaScript without a
second typed-array view or any offset arithmetic on the JS side. The cost is a
float comparison instead of an integer one:

```wat
(if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
  (then …))                     ;; slot is free
```

---

## Integer operations worth knowing

```wat
i32.clz      ;; count leading zeros
i32.ctz      ;; count trailing zeros
i32.popcnt   ;; population count — set bits
i32.rotl     ;; rotate left
i32.rotr     ;; rotate right
i32.wrap_i64 ;; i64 → i32, discarding the top bits
i64.extend_i32_s / _u
```

`clz` gives you an integer log2 in one instruction, which is how you find the
enclosing power of two for a bucket index or an allocator size class:

```wat
;; 31 - clz(x) == floor(log2(x)) for x > 0
(i32.sub (i32.const 31) (i32.clz (local.get $x)))
```

### Traps

Two integer operations can **trap** — abort the whole call with a
`RuntimeError`, unwinding to the host:

- `i32.div_s`, `i32.div_u`, `i32.rem_s`, `i32.rem_u` with a zero divisor
- `i32.div_s` of `INT_MIN / -1`, whose true result is not representable

There is no exception to catch. Guard the divisor yourself if it can be zero.

`i32.trunc_f32_s` also traps on NaN or out-of-range input — a real hazard when
converting computed floats to indices. The saturating variants
`i32.trunc_sat_f32_s` / `_u` clamp instead of trapping and are the safer default
where they are available (they are, everywhere, since 2020).

---

## Floats

`f32` and `f64` are IEEE-754, and wasm's float semantics are **fully
deterministic** — the same operations on the same inputs give bit-identical
results on every conforming engine and every CPU. This was hard-won and is one
of the format's most valuable properties: a physics simulation, a checksum over
float output, or a replay recorded on one machine reproduces exactly on another.

The one deliberate exception is the **NaN payload**: which of the many NaN bit
patterns you get from an operation that produces NaN is not specified. If you
are hashing raw float bytes, canonicalise NaNs first.

Available on both float types:

```wat
f32.add  f32.sub  f32.mul  f32.div
f32.sqrt  f32.abs  f32.neg
f32.min  f32.max          ;; NaN-propagating, unlike C's fmin/fmax
f32.ceil  f32.floor  f32.trunc  f32.nearest
f32.copysign
f32.eq  f32.ne  f32.lt  f32.le  f32.gt  f32.ge    ;; no _s/_u — sign is in the type
```

**`f32.nearest` is round-half-to-even**, not round-half-up. `2.5 → 2.0`,
`3.5 → 4.0`. If you want the C `round()` behaviour you have to build it.

**`f32.min` propagates NaN**, unlike `Math.min` and unlike C's `fminf`. If
either operand is NaN the result is NaN. This is usually what you want and
occasionally a surprise.

### What is missing

There is **no `sin`, `cos`, `tan`, `exp`, `log`, `pow`, or `atan2`** in
WebAssembly. `sqrt` is the only transcendental-adjacent instruction, because it
is the only one IEEE-754 requires to be correctly rounded — and therefore the
only one that could be specified deterministically.

Everything else is either imported from the host or implemented in the module.
Both engines here import two functions and no more:

```wat
(import "env" "sinf" (func $sinf (param f32) (result f32)))
(import "env" "cosf" (func $cosf (param f32) (result f32)))
```

...supplied from JavaScript as `Math.sin` / `Math.cos`. [Chapter
17](17-math-without-a-stdlib.md) covers the trade-off — importing costs a
boundary crossing per call and forfeits determinism, since `Math.sin` is *not*
specified to the last bit across engines; a polynomial approximation in-module
costs code and accuracy. For a game the crossing is cheap and the determinism
does not matter, so importing wins. For a physics engine that needs replay
determinism, it does not.

This is also why a C program compiled to wasm carries a maths library with it.
`libm` is not free; you can see it in the binary size.

---

## Conversions

```wat
i32.wrap_i64                   ;; truncating narrow
i64.extend_i32_s / _u

i32.trunc_f32_s / _u           ;; float → int, toward zero, TRAPS out of range
i32.trunc_sat_f32_s / _u       ;; same, saturating — prefer this
f32.convert_i32_s / _u         ;; int → float
f32.demote_f64
f64.promote_f32

i32.reinterpret_f32            ;; same bits, different type — no conversion
f32.reinterpret_i32
```

The `reinterpret` pair is a free bit-cast. It is how you inspect a float's bit
pattern, and how the RNG in both engines converts a random `i32` into a float —
though there it does the honest arithmetic conversion instead:

```wat
;; xorshift32, then scale the full unsigned range into [0, 1)
(f32.div (f32.convert_i32_u (local.get $x)) (f32.const 4294967296.0))
```

Note `convert_i32_u`. With `_s` half the RNG's outputs would come out negative,
and every `frand(lo, hi)` built on it would return values below `lo` half the
time — the kind of bug that produces enemies spawning off-screen and takes an
hour to find.

---

## `select`

A branchless ternary:

```wat
(select (local.get $a) (local.get $b) (local.get $cond))   ;; cond ? a : b
```

Both arms are evaluated, so it is only valid when both are side-effect-free and
cheap. When they are, it avoids a branch — useful in a tight loop.

---

## Sizes and the case for `f32`

Both engines use `f32` throughout, never `f64`, and it is a considered choice:

- **Half the memory.** An entity record of 10 fields is 40 bytes instead of 80.
  Pixel Wave's 33 enemies, 160 bullets and 20 asteroids fit in 5.7 KB — under a
  tenth of one 64 KiB page.
- **Half the traffic across the boundary.** JavaScript reads the whole entity
  region as a `Float32Array` each frame. Doubling that doubles the copy.
- **Precision is irrelevant here.** `f32` gives ~7 significant decimal digits.
  A coordinate in a 1200×750 arena needs four. The error per frame is far below
  a pixel.

`f64` is the right default for anything accumulating over long runs — money,
integrators, statistics — because `f32`'s error compounds fast. For per-frame
positional state that is overwritten every tick, it is waste.

---

← [Reading and writing WAT](02-wat-syntax.md) · [Contents](README.md) · next: [Control flow](04-control-flow.md)
