# 06 · Functions, tables and indirect calls

← [Linear memory](05-linear-memory.md) · [Contents](README.md) · next: [The JavaScript boundary](07-javascript-interop.md)

---

## The call stack you cannot see

WebAssembly has two stacks and you can only touch one.

The **operand stack** is the one from [chapter 2](02-wat-syntax.md) — values
flowing between instructions, its shape known statically at every point.

The **call stack** holds return addresses, and parameters and locals for each
frame. It is entirely managed by the engine, in memory the module cannot
address. You cannot take the address of a local. You cannot smash the return
address. You cannot read another frame's locals.

This is a real and underrated security property: **stack-smashing attacks do
not work against WebAssembly**, because the return address is not in a place
the module can write. Return-oriented programming has nothing to build on.

The catch — and it is a significant one for compiled C and Rust — is that
anything needing an *address* cannot live in a local. `&x` on a stack variable
forces the compiler to keep `x` in a "shadow stack" carved out of linear
memory, managed by an ordinary mutable global as the stack pointer. That shadow
stack is inside your addressable memory, so it *can* be corrupted by an
overflow of an adjacent buffer. The engine's real stack is safe; the compiler's
emulated one is not.

Stack depth is bounded and exhausting it traps (`RuntimeError: call stack
exhausted`). The limit is engine-specific — usually a few tens of thousands of
frames. There is no tail-call elimination in the MVP; the tail-call proposal has
shipped in most engines and fixes this for functional-style code
([chapter 14](14-post-mvp-features.md)).

---

## Direct calls

```wat
(func $bot_addr (param $i i32) (result i32) …)

(call $bot_addr (local.get $i))
```

Arguments are pushed in order, the result comes back on the stack. Signature
matching is checked at **validation** time, so a direct call can never fail for
type reasons at runtime.

Calls are cheap — a wasm-to-wasm call is roughly a native call. In hot loops,
engines routinely inline small functions like `$bot_addr`. Do not hand-inline
for performance without measuring; you will lose readability and probably gain
nothing.

Note the index space: **imported functions come first**. In `pixel-wave`,
`$sinf` is function 0 and `$cosf` is function 1, so your first defined function
is index 2. In `worm-chase`, which imports nothing, it is index 0. This only
matters when reading a disassembly or a stack trace.

---

## Tables and indirect calls

A **table** is an array of references. In the MVP it holds `funcref` and it is
the only way to call a function you do not know statically — a function pointer,
a vtable, a callback, a dispatch table.

```wat
(type $step_fn (func (param f32)))

(table 4 funcref)
(elem (i32.const 0) $wander $orbit $charge $flee)   ;; fill slots 0..3

(func $update (param $behaviour i32) (param $dt f32)
  (call_indirect (type $step_fn) (local.get $dt) (local.get $behaviour)))
```

`call_indirect` pops the **table index last**, after the arguments. It then does
two runtime checks:

1. Is the index within the table, and is that slot non-null? If not, it traps.
2. Does the function's actual type **exactly** match the declared `(type …)`?
   If not, it traps.

That second check is what makes indirect calls safe. In native code a function
pointer with a mismatched signature is undefined behaviour and a common exploit
primitive; in wasm it is a clean trap. The check is a single integer comparison
against a canonicalised type index, so the cost is small but not zero — an
indirect call is measurably more expensive than a direct one.

This is also the enforcement point for **control-flow integrity**. A module can
only ever jump to a function that was explicitly placed in its table, with a
matching signature. An attacker who can corrupt a "function pointer" in linear
memory can only redirect it to another entry in the same table — a real
constraint, though not a complete defence. See [chapter
12](12-security-model.md).

Tables can be exported, imported, grown (`table.grow`), read (`table.get`) and
written (`table.set`) with the reference-types proposal. This is how dynamic
linking between wasm modules works, and how a host can hand a module a callback
without going through JavaScript.

---

## When you actually need a table

Hand-written WAT usually does not. Every engine here has zero tables, because
their dispatch is a small fixed set best written as an `if` chain:

```wat
;; enemy species: 0 crab, 1 hornet, 2 skull — behaviour differs only in
;; constants, so there is nothing to dispatch to
```

Reach for a table when you have **open-ended** dispatch: a plugin registry,
user-supplied callbacks, a large `switch` over function bodies rather than
constants, or a compiled language's virtual methods. For a closed set of three,
branches are faster and clearer.

The place you *will* meet tables is reading compiler output. Every C++ class
with virtual methods, every Rust trait object, every Go interface becomes table
entries.

---

## Multiple results

Post-MVP, and widely supported:

```wat
(func $divmod (param $a i32) (param $b i32) (result i32 i32)
  (i32.div_s (local.get $a) (local.get $b))
  (i32.rem_s (local.get $a) (local.get $b)))
```

Both values land on the operand stack, in order. Useful, but hand-written WAT
usually finds it simpler to write extra outputs to a known address in linear
memory — which is what these engines do for everything JavaScript needs to read.

---

## The start function

```wat
(start $init)
(func $init … )
```

Runs once at instantiation, after imports are wired and data segments applied,
before any export can be called. It cannot take parameters or return anything.

No engine here uses it — all export an explicit `init()` that JavaScript calls,
which is the better choice here for one specific reason: **restart**. `R`
restarts a run by calling `init()` again, re-seeding the RNG and clearing the
pools. A `start` function can only ever fire once per instance, so the restart
path would have to be a separate export anyway. Having one function that both
paths use means the first run and the fiftieth run go through identical code —
and that is exactly the kind of asymmetry that produces "it only breaks after a
restart" bugs.

---

## Designing the export surface

The exports **are** the API, and this is worth more thought than it usually
gets. Pixel Wave exports nine things and no more:

```wat
(memory (export "memory") 1)
(func $init      (export "init"))
(func $set_input (export "set_input") (param f32) (param i32) (param i32))
(func $step      (export "step") (param $dt f32))
(func $get_score (export "get_score") (result f32))
(func $get_lives (export "get_lives") (result f32))
(func $get_level (export "get_level") (result i32))
(func $is_game_over     (export "is_game_over")     (result i32))
(func $bots_alive_count (export "bots_alive_count") (result i32))
```

Nine, for a complete game with 33 enemies and 160 bullets in flight.

Three principles hold this together, and all three are about keeping the
boundary narrow.

**Commands take scalars; state comes back through memory.** `set_input` takes
three numbers because that is all input is. But the *world* — 33 enemies, 160
bullets — is never returned; JavaScript reads it directly out of the exported
memory as a `Float32Array`. Returning it would mean copying it, per frame,
forever.

**The scalars that are read once per frame get accessors anyway.** `get_score`
is literally `(f32.load (global.get $SCORE_OFF))` — a memory read the host could
perform itself, at an offset the memory-map comment already documents. Exporting
it as a function means the renderer does not need that constant, which is one
fewer thing to keep in sync. Four scalars, four calls, once per frame: not
measurable.

**Nothing is exported that JavaScript does not need.** `$spawn_bullet`,
`$bot_addr`, `$rand_f32`, `$wrap` — all internal. Every export is a
compatibility surface you have promised to keep.

Whether `init` takes a parameter is where the policy line sits, and it is worth
noticing. Pixel Wave's takes nothing: `$wave_size` — `1 + level`, capped at 24 —
lives *inside* the engine, with `get_level` exported so the HUD can display it.
Every host that loads this binary plays the same game.

The other side of the same choice is an engine with **no concept of waves at
all**, whose `init(n)` spawns `n` enemies and stops having an opinion. Wave
progression then lives entirely in the host: watch `bots_alive_count()`, and
when it reaches zero, call `init(n + 1)` — a difficulty curve added, or changed,
without recompiling the binary.

Neither is wrong. The first guarantees every host plays the same game; the
second exposes mechanism and lets the host set policy. Decide which you want
before you write the signature, because changing it later breaks every
integration.

---

## Function references and the GC proposal

Newer proposals add typed function references (`(ref $type)`) and, with the GC
proposal, actual struct and array types with a garbage collector. These change
the picture substantially for languages like Java, Kotlin, Dart and OCaml, which
previously had to ship their own GC compiled into the binary.

They do not much change hand-written WAT, and they are covered in [chapter
14](14-post-mvp-features.md).

---

← [Linear memory](05-linear-memory.md) · [Contents](README.md) · next: [The JavaScript boundary](07-javascript-interop.md)
