# 08 · Globals, mutability and module state

← [The JavaScript boundary](07-javascript-interop.md) · [Contents](README.md) · next: [The toolchain](09-toolchain.md)

---

A wasm instance's state lives in exactly four places:

| Where | Holds | Addressable? | Survives a call? |
|---|---|---|---|
| **Locals** | Function-scoped scalars | No | No |
| **Operand stack** | Intermediate values | No | No |
| **Globals** | Module-scoped scalars | **No** | Yes |
| **Linear memory** | Everything else | Yes | Yes |

The row that surprises people is globals: **a global is not memory**. It has no
address, `i32.load` cannot reach it, and a pointer to it does not exist. It is a
named machine word owned by the instance, and the only way to touch it is
`global.get` / `global.set`.

That is a feature. A global cannot be corrupted by a buffer overflow, which is
why compilers keep the shadow stack pointer in one.

---

## Declaring globals

```wat
(global $MAX_BOTS i32 (i32.const 8))              ;; immutable
(global $rng (mut i32) (i32.const 88172645))      ;; mutable
(global $ROT_SPEED f32 (f32.const 2.8))           ;; immutable
```

Without `(mut …)` a global is a **constant**, and `global.set` on it is a
validation error — caught before anything runs. The initialiser must be a
constant expression: a literal, or a `global.get` of a previously-declared
*immutable* imported global. No arithmetic, no function calls.

That restriction is why `pixel-wave` writes:

```wat
(global $BULLETS_OFF i32 (i32.const 1344))    ;; 24 + 33*40, computed by hand
```

rather than the expression. The comment carries the arithmetic; the language
will not.

Globals can be **imported** and **exported**:

```wat
(import "env" "gravity" (global $gravity f32))
(global (export "BOTS_OFF") i32 (i32.const 24))
```

Exporting layout constants is the cheapest way to stop a host's copy of your
memory offsets from drifting — see [chapter 7](07-javascript-interop.md).

From JavaScript, an exported global is a `WebAssembly.Global` object with a
`.value` property, settable only if it was declared mutable:

```js
instance.exports.BOTS_OFF.value;   // 24
```

---

## Constants vs globals vs literals

Three ways to write the number 33, with real differences:

```wat
(global $MAX_BOTS i32 (i32.const 33))    ;; named, one place to change
(i32.const 33)                            ;; inline literal
```

Immutable globals are the right default for tuning constants. Engines constant-
fold `global.get` of an immutable global, so there is **no runtime cost** — you
get the readability for free. These engines use them exhaustively, and it is why
retuning the difficulty was a matter of editing thirteen lines at the top of a
file rather than hunting through 700:

```wat
(global $PLAYER_FIRE_CD f32 (f32.const 0.15))   ;; was 0.22
(global $BOT_MAX_SPEED  f32 (f32.const 145.0))  ;; was 165
(global $BOT_BULLET_SPEED f32 (f32.const 240.0));; was 300
(global $ORBIT f32 (f32.const 280.0))           ;; was 220
(global $FIRE_RANGE f32 (f32.const 360.0))      ;; was 480
```

**Keep the old value in the comment.** A tuning constant without its history is
a number nobody will dare touch, because there is no way to tell whether 145 was
reasoned about or typed at random.

---

## Mutable globals as engine state

Globals are for **scalars the whole module reads**, and memory is for
**anything with a shape**. The dividing line is whether JavaScript needs to see
it.

`pixel-wave`'s mutable globals, in full:

```wat
(global $rng            (mut i32) (i32.const 88172645))  ;; RNG state
(global $level          (mut i32) (i32.const 1))
(global $rotDir         (mut f32) (f32.const 0.0))       ;; input
(global $thrustOn       (mut i32) (i32.const 0))         ;; input
(global $firing         (mut i32) (i32.const 0))         ;; input
(global $playerCooldown (mut f32) (f32.const 0.0))
(global $gameOver       (mut i32) (i32.const 0))
(global $astTimer       (mut f32) (f32.const 2.0))       ;; next asteroid
(global $prevFiring     (mut i32) (i32.const 0))         ;; burst-fire edge
(global $burstLeft      (mut i32) (i32.const 0))
(global $pendingFire    (mut i32) (i32.const 0))
```

Eleven machine words. Meanwhile score and lives — two equally scalar values —
live in *memory*, at offsets 5664 and 5668. Why the split?

**Because JavaScript reads score and lives, and does not read the others.** A
global is reachable from JS only through an accessor or an exported
`WebAssembly.Global`; a memory word is reachable through the `Float32Array` view
the renderer already holds. Putting them in memory means the HUD can read them
in the same pass as everything else.

It is a defensible line: *state the host observes goes in memory; state only the
engine cares about goes in globals*. Pixel Wave then also exports `get_score`
and `get_lives` accessors, which is belt and braces — the accessor spares the
host from knowing the offset, and the memory location is there if it wants the
fast path.

The later titles here drop the second half of that. Worm Chase, Asteroid Miner
and Sector Defense keep every scalar in a global and expose it only through a
reader, because their renderers do not otherwise walk memory for those values —
so a global is one instruction to read and there is no offset to keep in sync.

---

## Input as globals: the double-buffer that isn't

```wat
(func $set_input (export "set_input") (param $rot f32) (param $thrust i32) (param $fire i32)
  (global.set $rotDir   (local.get $rot))
  (global.set $thrustOn (local.get $thrust))
  (global.set $firing   (local.get $fire)))
```

`$rot` is an `f32` rather than a sign flag, which is the small decision that
makes analogue input possible: a keyboard host passes −1, 0 or 1, and a gamepad
host passes the stick axis. The engine multiplies it by `$ROT_SPEED` either way
and never learns which kind of host it has.

Input arrives once per frame, is stored in globals, and every subsequent pass in
`step` reads the same values. This gives the frame a **consistent view of
input** — the player-update pass and the firing pass cannot disagree about
whether Space was held, which they could if each polled the keyboard directly.

It is the same discipline as double-buffering, achieved by making the host push
rather than letting the engine pull. The engine has no way to poll anything; it
has no imports that could tell it. That constraint turned out to be a design
benefit.

---

## Edge detection: state the host cannot provide

The most interesting mutable global in this engine is `$prevFiring`, and it
exists because of a genuine gap in the interface.

`set_input` reports the **held state** of the fire key: 1 while Space is down.
But burst fire needs the **press**, the 0→1 transition. Nothing in the input
protocol carries that. Options were to change the protocol — add a `firePressed`
parameter and make every host compute it — or to have the engine remember last
frame's value and derive the edge itself:

```wat
(global $prevFiring (mut i32) (i32.const 0))

;; inside the player update:
(if (i32.and (global.get $firing) (i32.eqz (global.get $prevFiring)))
  (then (global.set $pendingFire (i32.const 1))))     ;; a rising edge
;; … at the end of the pass:
(global.set $prevFiring (global.get $firing))
```

The engine version won because it keeps the host dumb. A host that forwards raw
key state cannot get burst fire wrong, and there is exactly one implementation
of the edge rule instead of one per integration.

Three more globals complete the mechanism, and they are a nice illustration of
how much behaviour lives in a handful of words:

| Global | Role |
|---|---|
| `$burstLeft` | Rounds remaining in the current burst (counts 3 → 0) |
| `$pendingFire` | A press that arrived mid-burst, held until the gun is ready |
| `$prevFiring` | Last frame's held state, for the edge |

`$pendingFire` is there for a reason found by testing: dropping a press that
lands during the 0.35 s recovery cost anyone tapping at around 2 Hz roughly half
their inputs, which reads as *the key not working*. Queueing it costs one word.

---

## Initialisation, restart, and the bug that hides there

The subtlest thing in this chapter. Globals have declared initialisers, applied
once at instantiation. **They are not re-applied when you call `init()`.**

So an `init` that forgets to reset a global will behave differently on the
second run than on the first — the classic "only breaks after a restart" bug,
and one that no amount of testing the happy path will find.

Every engine here resets its mutable globals explicitly. Pixel Wave's `init`, with
the memory-clearing loops elided:

```wat
(func $init (export "init")
  (global.set $level (i32.const 1))
  (global.set $gameOver (i32.const 0))
  (global.set $playerCooldown (f32.const 0.0))
  (global.set $thrustOn (i32.const 0))
  (global.set $firing (i32.const 0))
  ;; a burst must not survive a restart, and a Space still held from the last
  ;; run must not count as the press that arms the next one
  (global.set $prevFiring (i32.const 1))          ;; ← see below
  (global.set $burstLeft (i32.const 0))
  (global.set $pendingFire (i32.const 0))
  (global.set $rotDir (f32.const 0.0))
  (global.set $astTimer (f32.const 2.5))
  ;; … player record, score, lives, spawn the wave, clear the pools …
)
```

**`$prevFiring` is seeded to 1, not 0.** If it were 0 and the player were still
holding Space from the run that just ended — which, on a death, they invariably
are — the very next frame would see a 0→1 edge that never happened and auto-fire
a burst. Seeding it to 1 means the engine believes the key was already down, so
the player must release and press again. One character, and it is the difference
between a restart that feels deliberate and one that feels haunted.

### The global that is deliberately *not* reset

`$rng` does not appear in that list. Its declared initialiser
runs once, at instantiation:

```wat
(global $rng (mut i32) (i32.const 88172645))
```

so the xorshift stream carries straight on across a restart. The consequence is
worth stating precisely, because it cuts both ways:

- **The first run after a page load is fully deterministic** — same opening wave
  positions, same asteroid timings, every time.
- **Every subsequent restart is different**, because the stream is wherever the
  previous run left it.

For a game that is the behaviour you want: a fresh run should not be a replay of
the one that just killed you. For *debugging* it is the awkward half — a bug
fourteen seconds into your fifth run is not reproducible by restarting. The fix
when you need it is to reset `$rng` in `init` too, or better, take a seed as a
parameter so the host can choose:

```wat
(func $init (export "init") (param $seed i32)
  (global.set $rng (local.get $seed))
  …)
```

That is the version to write if you ever want deterministic replay, which
[chapter 13](13-debugging-and-profiling.md) argues is the strongest debugging
tool available for a simulation. No engine here does, and it is the one
design choice in them I would change.

Pixel Wave has since gained a second global that `init` reads and never resets,
for the same reason: `$difficulty`. The widget calls `set_difficulty(d)` and
then `init()`, and `init` copies that setting's row of tuning values into the
globals `step` reads. The choice has to survive the restart it is made for, so
it stays out of the reset list, and the tuning it selects is re-applied in full
every time, so an Easy run followed by a Normal one cannot keep any of Easy.

---

## Instance isolation

Each `WebAssembly.Instance` gets its **own** globals and its **own** memory,
even when instantiated from the same compiled `Module`. There is no shared
mutable state between instances unless you explicitly import the same memory or
the same mutable global into both.

This is what makes `PixelWave.mount()` safe to call several times on one page —
two games on the same page share the compiled code and nothing else. It is also
the property that makes wasm attractive for plugin systems: per-instance memory
limits, per-instance state, and a hard wall between tenants.

---

← [The JavaScript boundary](07-javascript-interop.md) · [Contents](README.md) · next: [The toolchain](09-toolchain.md)
