# 04 · Control flow

← [Numbers and operations](03-numbers-and-operations.md) · [Contents](README.md) · next: [Linear memory](05-linear-memory.md)

---

WebAssembly has **no `goto`**. Control flow is structured: nested regions with
explicit entry and exit, and branches that can only travel *outward* to an
enclosing region's label. This is not a stylistic preference — it is what makes
single-pass validation and streaming compilation possible, and it is why a wasm
binary cannot contain an irreducible control-flow graph.

The consequence for a human writing WAT is that you spend a while translating
familiar `break`/`continue`/`goto` shapes into blocks and loops. Once the
mapping is memorised it is fine.

---

## The three region constructs

```wat
(block $label  … )      ;; branching to $label jumps to just AFTER the block
(loop  $label  … )      ;; branching to $label jumps BACK to the loop's start
(if (cond) (then …) (else …))
```

**Say this out loud until it sticks:**

> `br` to a **block** label goes forward (a `break`).
> `br` to a **loop** label goes backward (a `continue`).

A `loop` does not loop on its own. Falling off the bottom of a `loop` exits it.
An infinite loop requires an explicit `br` back to the label. Getting this
backwards is the classic first-day bug: either the loop body runs exactly once,
or it never terminates.

---

## Branch instructions

```wat
(br $label)                    ;; unconditional
(br_if $label (cond))          ;; branch when cond is nonzero
(br_table $a $b $default (i))  ;; computed branch — a jump table
(return)                       ;; leave the function
(unreachable)                  ;; trap immediately
```

Labels can also be referenced by **relative depth**: `br 0` is the innermost
enclosing region, `br 1` its parent. Named labels compile to exactly this, and
a disassembler will show you the numbers. Use names.

`unreachable` is not "do nothing". It traps, producing a `RuntimeError` in the
host. Compilers emit it after calls that cannot return, and it is the right
thing to put in a branch you believe is impossible — a trap in development beats
silent corruption.

---

## The canonical loop

Every counted loop in both engines is this shape, and it is worth learning as a
single unit:

```wat
(local.set $i (i32.const 0))
(block $done
  (loop $next
    (br_if $done (i32.ge_s (local.get $i) (local.get $count)))   ;; exit test
    ;; ---- body ----
    (local.set $i (i32.add (local.get $i) (i32.const 1)))        ;; increment
    (br $next)))                                                 ;; continue
```

Four moving parts:

1. The **`block`** provides the exit label. Without it there is nowhere for the
   exit branch to go.
2. The **`loop`** provides the back-edge label.
3. `br_if $done` at the top is the `for` condition, **inverted** — you branch out
   when you want to stop.
4. `br $next` at the bottom is what actually repeats. Omit it and the body runs
   once.

The real thing, from `games/pixel-wave/game.wat`, walking the bullet pool:

```wat
(local.set $i (i32.const 0))
(block $done
  (loop $lp
    (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
    (local.set $a (call $bullet_addr (local.get $i)))
    (if (f32.ne (f32.load offset=20 (local.get $a)) (f32.const 0.0))
      (then
        ;; integrate this bullet's position …
      ))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $lp)))
```

### `continue`, in a loop with work after it

If you want to skip to the next iteration but the increment lives at the
bottom, you cannot `br $lp` — you would skip the increment and hang. Two fixes,
both used in practice:

**Wrap the body in an inner block:**

```wat
(loop $lp
  (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
  (block $continue
    (br_if $continue (call $should_skip (local.get $i)))
    ;; … body …
  )
  (local.set $i (i32.add (local.get $i) (i32.const 1)))
  (br $lp))
```

**Or increment first**, and index with `$i - 1`. Less readable; occasionally
worth it.

---

## `if` and its typed form

```wat
(if (i32.lt_s (local.get $x) (i32.const 0))
  (then (local.set $x (i32.const 0))))

(if (local.get $cond)
  (then (local.set $r (i32.const 1)))
  (else (local.set $r (i32.const 2))))
```

An `if` can also **produce a value**, which requires a result type and both
arms:

```wat
(if (result f32) (f32.gt (local.get $a) (local.get $b))
  (then (local.get $a))
  (else (local.get $b)))
```

For simple, cheap, side-effect-free arms, `select` is usually better — no
branch at all:

```wat
(select (local.get $a) (local.get $b) (f32.gt (local.get $a) (local.get $b)))
```

### Clamping, the everyday idiom

Two `if`s and no branch prediction to worry about, from `pixel-wave`:

```wat
(func $clampf (param $v f32) (param $lo f32) (param $hi f32) (result f32)
  (local $r f32)
  (local.set $r (local.get $v))
  (if (f32.lt (local.get $r) (local.get $lo)) (then (local.set $r (local.get $lo))))
  (if (f32.gt (local.get $r) (local.get $hi)) (then (local.set $r (local.get $hi))))
  (local.get $r))
```

Wrapping — the arena edge in `vector-arena` — is the same shape:

```wat
(func $wrap (param $v f32) (param $max f32) (result f32)
  (local $r f32)
  (local.set $r (local.get $v))
  (if (f32.lt (local.get $r) (f32.const 0.0))   (then (local.set $r (f32.add (local.get $r) (local.get $max)))))
  (if (f32.gt (local.get $r) (local.get $max))  (then (local.set $r (f32.sub (local.get $r) (local.get $max)))))
  (local.get $r))
```

Note it corrects by **one** `max` and no more. That is a real assumption: an
entity that moves more than a full arena width in one frame is not wrapped
correctly. At the speeds and timestep involved it cannot happen, and the
alternative — a modulo, or a loop — costs more than the case is worth. Knowing
which of these shortcuts you have taken is the difference between a tuned engine
and a fragile one.

---

## `br_table`

A jump table: pops an index, branches to the label at that position, or to the
last label if the index is out of range.

```wat
(block $default
  (block $case2
    (block $case1
      (block $case0
        (br_table $case0 $case1 $case2 $default (local.get $kind)))
      ;; $case0 lands here
      (br $default))
    ;; $case1
    (br $default))
  ;; $case2
  (br $default))
;; $default and everything after
```

Verbose, and the nesting is inside-out — the *first* label in the table is the
*innermost* block. Hand-written WAT rarely needs it; compilers emit it for dense
`switch` statements. It is worth being able to recognise in a disassembly.

---

## Early return

```wat
(func $find (param $target f32) (result i32)
  (local $i i32)
  (block $done
    (loop $lp
      (br_if $done (i32.ge_s (local.get $i) (global.get $MAX)))
      (if (f32.eq (call $value_at (local.get $i)) (local.get $target))
        (then (return (local.get $i))))          ;; straight out of the function
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
  (i32.const -1))                                 ;; not found
```

`return` pops the function's declared result from the stack and leaves. Note
that the fall-through at the bottom still has to supply an `i32` — every path
must satisfy `(result i32)`, and the validator will tell you which one doesn't.

---

## What the validator enforces

Worth knowing, because the error messages are terse:

- **Every path out of a region agrees on the stack.** If a `block` has a result
  type, every `br` to it must carry a value of that type, and so must the
  fall-through.
- **You cannot branch inward or sideways.** Only to an enclosing label. This is
  what forbids `goto` and guarantees reducibility.
- **Code after an unconditional branch is polymorphic.** The validator knows it
  is unreachable and stops constraining the stack there — which is why an
  obviously-wrong instruction after a `br` sometimes validates fine. Do not read
  anything into that; delete the dead code.
- **Depth is bounded at compile time.** There is no dynamic label. A branch
  target is always statically known, which is exactly why the compiler can lay
  out the jumps ahead of time.

---

## The frame step, as a control-flow shape

The `step` export in both engines is one long function: a guard, then a
sequence of passes over the world, each pass a loop of the canonical shape.

```wat
(func $step (export "step") (param $dt f32)
  (local $px f32) (local $py f32) (local $pvx f32) (local $pvy f32)
  (local $i i32) (local $a i32) (local $b i32)
  ;; … ~35 more locals, all declared here …

  (if (global.get $gameOver) (then (return)))    ;; guard first

  ;; ===== player =====      load, integrate, clamp, store
  ;; ===== bots =====        one loop: AI steer, move, fire
  ;; ===== bullets =====     one loop: integrate, cull off-screen
  ;; ===== asteroids =====   one loop: fall, spawn on a timer
  ;; ===== collisions =====  nested loops: bullet×bot, bullet×player, ship×ship
  ;; ===== level check =====
)
```

**All locals are declared at the top**, because WAT requires it — every
`(local …)` must precede the first instruction of the body. With no lexical
scoping inside a function, that produces the long declaration block both engines
open with, and the reason they are one big function rather than six small ones
is honest inertia: the passes share a dozen of those locals, and splitting them
would mean either passing state or re-loading it.

The ordering is not arbitrary. Each pass reads the world as the previous pass
left it, so a bullet spawned during the bots pass **is integrated in the same
frame**, because bullets are updated after bots. Move the bullet pass above the
bot pass and every enemy shot is one frame late. [Chapter
15](15-game-loop-architecture.md) goes into that properly.

---

← [Numbers and operations](03-numbers-and-operations.md) · [Contents](README.md) · next: [Linear memory](05-linear-memory.md)
