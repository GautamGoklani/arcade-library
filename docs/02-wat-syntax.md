# 02 · Reading and writing WAT

← [What WebAssembly is](01-what-is-webassembly.md) · [Contents](README.md) · next: [Numbers and operations](03-numbers-and-operations.md)

---

WAT — WebAssembly Text format — is the human-readable projection of the binary.
It is not a separate language: every WAT construct maps to bytes, and the
mapping is specified. If you can read WAT you can read any wasm binary, because
`wasm2wat` will hand you one.

Two things make it briefly disorienting: it looks like Lisp, and underneath it
is a stack machine. Neither is as bad as it first appears.

---

## The stack machine

Every instruction pops some values off an operand stack and pushes some back.
There are no registers. There are no expressions — only sequences.

```wat
i32.const 2      ;; stack: [2]
i32.const 3      ;; stack: [2, 3]
i32.add          ;; stack: [5]      pops two, pushes one
```

The signature of `i32.add` is `[i32 i32] → [i32]`. Every instruction has one,
and the validator checks the whole function's stack shape statically. If a
branch could leave the stack in two different shapes, the module does not
validate. This is the entire reason wasm can be trusted without runtime checks.

That flat listing is the **linear form**. It is exactly what the binary
encodes, and what a disassembler will show you.

## Folded form

Writing linear form by hand is miserable, so WAT allows a parenthesised
"folded" form that is purely syntactic sugar:

```wat
(i32.add (i32.const 2) (i32.const 3))
```

The rule: an instruction's parenthesised children are emitted **before** it, in
order. The two forms above compile to identical bytes. You can mix them freely.

This is why WAT looks like Lisp and is not: the parentheses are not function
application, they are "emit these operands first". A folded expression is a
tree that flattens to a stack sequence.

The engines here use folded form throughout, which is why they read like this:

```wat
;; heading += rotDir * ROT_SPEED * dt
(f32.store offset=16 (i32.const 0)
  (f32.add
    (f32.load offset=16 (i32.const 0))
    (f32.mul (global.get $rotDir)
             (f32.mul (global.get $ROT_SPEED) (local.get $dt)))))
```

Read it inside-out, like arithmetic. It is `player.heading += rotDir *
ROT_SPEED * dt` written by someone with no infix operators.

**Convention that helps enormously:** put the infix equivalent in a `;;`
comment above anything with more than two levels of nesting. The engines in
this repository do, and it is the difference between the files being editable in
six months and not.

---

## Comments

```wat
;; line comment, to end of line
(; block comment, nestable ;)
```

---

## Identifiers and indices

Everything in wasm is addressed by a numeric index: function 0, local 3, global
7. WAT lets you write a `$name` instead, and the assembler resolves it. The
names exist only in the text — the binary has indices, plus an optional custom
"name section" that debuggers read.

```wat
(func $bot_addr (param $i i32) (result i32) …)
(call $bot_addr (local.get 0))     ;; index
(call $bot_addr (local.get $i))    ;; name — identical output
```

Name your things. Index-only WAT is unreadable within about forty lines.

Names live in **separate index spaces** per kind, so `$score` as a global and
`$score` as a function do not collide. Within a function, parameters and locals
share one space and are numbered together: parameters first, then declared
locals.

---

## Module structure

A module is a sequence of **fields**. Order in the text is mostly free — the
assembler sorts them into the binary's required section order — with two
exceptions worth knowing: imports are numbered before locally-defined items of
the same kind, and `(local …)` declarations must come before any instruction in
a function body.

```wat
(module
  ;; ---- imports: everything the host must provide ----
  (import "env" "sinf" (func $sinf (param f32) (result f32)))
  (import "env" "log"  (func $log  (param i32)))

  ;; ---- state ----
  (memory (export "memory") 1)               ;; 1 page = 64 KiB
  (global $counter (mut i32) (i32.const 0))
  (global $LIMIT i32 (i32.const 100))        ;; no (mut …) = immutable

  ;; ---- data: bytes written into memory at instantiation ----
  (data (i32.const 0) "hello")

  ;; ---- functions ----
  (func $helper (param $x i32) (result i32)
    (i32.mul (local.get $x) (i32.const 2)))

  (func (export "run") (param $n i32) (result i32)
    (local $acc i32)                          ;; locals first, always
    (local.set $acc (i32.const 0))
    (call $helper (local.get $n)))

  ;; ---- start: runs once at instantiation ----
  (start $init)
  (func $init …)
)
```

### Inline vs standalone export

```wat
(func $step (export "step") (param f32) …)   ;; inline — usual
(func $step (param f32) …)
(export "step" (func $step))                 ;; standalone — identical
```

The inline form is what you will see; the standalone form is useful when you
want to export the same function under two names, or export something declared
far away.

### Imports must come first (in the binary)

An imported function occupies a lower function index than any defined one. The
assembler handles this, but it explains a class of confusing disassembly: in
`pixel-wave`, `$sinf` is function 0 and `$cosf` is function 1, so the first
function *you* wrote is function 2. In `worm-chase`, which imports nothing, your
first function is index 0.

---

## Locals and parameters

```wat
(func $example (param $a i32) (param $b f32) (result i32)
  (local $tmp i32)
  (local $flag i32)
  …)
```

- Parameters are initialised from the call. Locals are **always zero**-initialised
  — there is no uninitialised local in wasm, which removes a whole category of
  bug and is one of the format's better decisions.
- `local.get $x` pushes; `local.set $x` pops; `local.tee $x` pops, stores, and
  pushes the value back — the assignment-as-expression idiom.
- Multiple locals of one type can share a declaration: `(local $i $j $k i32)`.

`local.tee` is worth internalising early. This:

```wat
(local.set $a (call $expensive))
(local.get $a)
```

is this:

```wat
(local.tee $a (call $expensive))
```

---

## Function types

A signature can be declared once and referenced, which matters for indirect
calls ([chapter 6](06-functions-tables.md)):

```wat
(type $binop (func (param f32 f32) (result f32)))
(func $add (type $binop) (param $a f32) (param $b f32) (result f32)
  (f32.add (local.get $a) (local.get $b)))
```

In the MVP a function returns **zero or one** value. Multi-value returns are a
shipped post-MVP feature ([chapter 14](14-post-mvp-features.md)) and are widely
supported now, but hand-written WAT rarely needs them — the usual workaround,
and what the engines here do, is to write extra outputs into linear memory.

---

## A complete, minimal module

Small enough to hold in your head, real enough to run:

```wat
(module
  (memory (export "memory") 1)

  ;; Sum the first $n f32s in memory starting at byte 0.
  (func (export "sum") (param $n i32) (result f32)
    (local $i i32)
    (local $acc f32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc
          (f32.add (local.get $acc)
                   (f32.load (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))
    (local.get $acc))
)
```

Driving it from JavaScript:

```js
const { instance } = await WebAssembly.instantiate(bytes);
const mem = new Float32Array(instance.exports.memory.buffer);
mem.set([1.5, 2.5, 3.0]);
instance.exports.sum(3);   // 7
```

Everything in the rest of this course is a variation on that shape: put numbers
in memory, call an export, read numbers back out.

---

## Things that will trip you the first day

**`(result …)` is a promise the validator enforces.** A function declaring
`(result i32)` must leave exactly one `i32` on the stack on every path,
including the fall-through at the end. "Function body must end with an
expression of type i32" means you forgot a path.

**A `loop` label branches to the *top*, a `block` label to the *bottom*.**
`(br $loop)` continues; `(br $block)` breaks. This is the single most common
source of accidental infinite loops. [Chapter 4](04-control-flow.md) is about
exactly this.

**Unreachable code still has to validate.** Instructions after a `br` are dead
but still type-checked, unless the validator has marked the position as
polymorphic-after-branch. Delete dead code rather than reasoning about it.

**Offsets are unsigned and part of the instruction.** `f32.load offset=16` is a
static addend to the dynamic address, encoded in the opcode. It is free — use it
for struct fields instead of adding constants.

**`i32` is signedness-agnostic.** `i32.lt_s` and `i32.lt_u` are different
instructions over the same bits. Picking the wrong one for a loop counter gives
you a loop that runs two billion times. See [chapter 3](03-numbers-and-operations.md).

---

← [What WebAssembly is](01-what-is-webassembly.md) · [Contents](README.md) · next: [Numbers and operations](03-numbers-and-operations.md)
