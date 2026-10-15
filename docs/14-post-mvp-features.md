# 14 · Post-MVP features

← [Debugging and profiling](13-debugging-and-profiling.md) · [Contents](README.md) · next: [Game loop architecture](15-game-loop-architecture.md)

---

The 2017 MVP was deliberately minimal. Everything since has arrived through the
proposal process, and a good deal of it is now so universally supported that
treating it as optional is a mistake.

Proposals move through five stages: 0 pre-proposal, 1 feature proposal, 2 spec
text, 3 implementation, 4 standardised. Below, "shipped" means available in
Chrome, Firefox and Safari without a flag.

Check current status at [webassembly.org/features](https://webassembly.org/features/)
and [caniuse.com/wasm](https://caniuse.com/wasm) — this chapter will age.

---

## Shipped and safe to assume

### Bulk memory operations

```wat
(memory.copy (dest) (src) (len))     ;; memmove
(memory.fill (dest) (byte) (len))    ;; memset
(memory.init $seg (dest) (off) (len))
(data.drop $seg)
(table.copy) (table.fill) (table.init)
```

Replaces hand-written byte loops with engine intrinsics, and the difference is
one to two orders of magnitude. If you are clearing a region — an entity pool at
`init`, for instance — use `memory.fill`.

### Multi-value

Functions and blocks may return more than one value.

```wat
(func $divmod (param i32 i32) (result i32 i32)
  (i32.div_s (local.get 0) (local.get 1))
  (i32.rem_s (local.get 0) (local.get 1)))
```

Removes a class of "write the second result into memory" workarounds and lets
compilers avoid spilling. Enabled by default in every toolchain now.

### Sign extension

`i32.extend8_s`, `i32.extend16_s`, `i64.extend8_s`, and so on. One instruction
for what used to be a shift-left-shift-right pair.

### Non-trapping float→int

`i32.trunc_sat_f32_s` and friends: saturate to the type's range instead of
trapping on NaN or overflow. Prefer these over the trapping originals unless you
specifically want the trap.

### Reference types

`externref` (an opaque host reference) and `funcref` as real value types, plus
`table.get`, `table.set`, `table.grow` and multiple tables.

`externref` is the important one: a module can now hold a JavaScript object —
a DOM node, a promise — without a side table of integer handles. It cannot
*inspect* it; it can only store it and pass it back. That removes a lot of glue.

### SIMD (fixed-width, 128-bit)

A `v128` type and roughly 200 instructions operating on lanes.

```wat
(v128.load (local.get $p))
(f32x4.mul (local.get $a) (local.get $b))    ;; four multiplies, one instruction
(i8x16.add …) (i16x8.add …) (i32x4.add …) (f64x2.add …)
```

Real speedups of 2–4× on the right workload: image filters, audio DSP, codecs,
matrix maths, string search. Nothing for branchy or pointer-chasing code.

Writing SIMD by hand in WAT is unpleasant. Use Rust's `core::arch::wasm32`
intrinsics, C's `wasm_simd128.h`, or a compiler autovectoriser and then check
the output.

**Relaxed SIMD** is a companion proposal trading bit-exact determinism for
speed on operations (FMA, some rounding) where hardware differs. Only take it if
you do not need reproducibility.

---

## Shipped, with conditions

### Threads and atomics

A `SharedArrayBuffer`-backed memory, atomic operations, and `memory.atomic.wait`
/ `memory.atomic.notify`.

```wat
(memory 1 1 shared)
(i32.atomic.rmw.add (local.get $addr) (i32.const 1))
(memory.atomic.wait32 (local.get $addr) (i32.const 0) (i64.const -1))
```

Threads themselves are Web Workers; the shared memory is what makes them
threads. Emscripten's pthreads and Rust's `wasm-bindgen-rayon` build on this.

**The condition is cross-origin isolation.** `SharedArrayBuffer` requires:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

which breaks embedded third-party content that does not send CORP headers.
That is often a bigger project than the threading. Budget for it.

Note also: `memory.atomic.wait` **traps on the main thread**. Blocking waits are
worker-only.

### Exception handling

Real `try`/`catch`/`throw` at the wasm level, with typed tags.

```wat
(tag $err (param i32))
(try (do (call $risky))
     (catch $err (call $handle)))
```

Before this, C++ exceptions and Rust unwinding were emulated through
JavaScript, at a cost high enough that most projects compiled with
`-fno-exceptions` or `panic = "abort"`. Shipped across engines; the legacy
`try_table` vs `try` encoding difference is a toolchain concern, not yours.

### Garbage collection

Managed `struct` and `array` types collected by the *host's* GC, with typed
references.

```wat
(type $point (struct (field $x f32) (field $y f32)))
(type $row (array (mut i32)))
```

The consequence is large: Kotlin/Wasm, Dart, Java (TeaVM), OCaml and Scheme
targets no longer compile a collector into the binary. Dart's `dart compile
wasm` and Kotlin/Wasm both target it, and output shrank by roughly an order of
magnitude.

It does **not** replace linear memory, and it is not useful for C, Rust or Zig,
which do not want it. For hand-written WAT it is mostly a curiosity.

### Tail calls

`return_call` and `return_call_indirect`: reuse the current frame instead of
pushing a new one.

```wat
(func $loop (param $n i32)
  (if (local.get $n)
    (then (return_call $loop (i32.sub (local.get $n) (i32.const 1))))))
```

Constant stack space for mutual recursion, state machines and continuation-
passing style. Functional-language backends needed this; imperative code rarely
notices.

### Extended constant expressions

Arithmetic in global initialisers and data-segment offsets. Small, and it
directly removes the annoyance from [chapter 8](08-globals-and-state.md) where
`(global $BULLETS_OFF i32 (i32.const 1344))` had to have its `24 + 33*40`
computed by hand.

---

## In flight

| Proposal | What it gives you |
|---|---|
| **Memory64** | 64-bit addressing — memories beyond 4 GiB |
| **Multiple memories** | More than one linear memory per module; clean separation between a shared buffer and private state |
| **Component Model** | Language-agnostic typed interfaces and composition ([ch. 11](11-beyond-the-browser.md)) |
| **Stack switching** | Coroutines, generators, async without unwinding tricks |
| **Custom page sizes** | Sub-64 KiB memories, aimed at embedded targets |
| **Branch hinting** | Static likely/unlikely annotations for the JIT |
| **Flexible vectors** | Variable-width SIMD, mapping to ARM SVE and AVX-512 |
| **Profile-guided optimisation hints** | Feed real execution data back into the binary |

---

## Choosing what to use

**Assume unconditionally:** bulk memory, multi-value, sign extension,
non-trapping conversions, reference types. These are everywhere, and avoiding
them costs you performance and clarity for no benefit.

**Use with a feature check:** SIMD, exceptions, tail calls, GC. Detect and fall
back:

```js
const hasSimd = WebAssembly.validate(new Uint8Array([
  0,97,115,109, 1,0,0,0, 1,5,1,96,0,1,123, 3,2,1,0,
  10,10,1,8,0,65,0,253,15,26,11,
]));
```

The pattern is to compile the tiniest module using the feature and see whether
`WebAssembly.validate` accepts it. The `wasm-feature-detect` package packages
this for every proposal and is two lines instead of the above.

**Ship two builds** when the gain justifies it — a SIMD build and a scalar
build, selected at load. Emscripten and `wasm-pack` both support this, and for
a codec it is routinely worth the extra artefact.

**Threads deserve a real decision.** The COOP/COEP requirement has consequences
well beyond your module. Confirm the whole page can live with cross-origin
isolation before you commit.

---

## What the engines here use

None of it. Every `game.wat` in `games/` is strict MVP: four value types, one
memory, one table's worth of nothing, structured control flow, and at most two
imports — Worm Chase and Sector Defense have none.

That is partly the point of the exercise — the MVP is enough to write a complete
game engine in — and partly a real property worth having: the binaries run on
any engine that has ever supported WebAssembly, including a 2017 browser and a
microcontroller interpreter, with no feature detection and no fallback build.

The one place a proposal would genuinely help is `memory.fill` for clearing the
entity pools in `init`, which is currently a byte loop. It is a few microseconds
once per run, so it has stayed a loop — but it is the honest example of what you
give up.

---

← [Debugging and profiling](13-debugging-and-profiling.md) · [Contents](README.md) · next: [Game loop architecture](15-game-loop-architecture.md)
