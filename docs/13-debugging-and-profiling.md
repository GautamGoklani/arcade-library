# 13 · Debugging and profiling

← [The security model](12-security-model.md) · [Contents](README.md) · next: [Post-MVP features](14-post-mvp-features.md)

---

Debugging wasm is worse than debugging JavaScript and better than it used to be.
The main adjustment is that many of your usual tools are gone — no `console.log`
without an import, no stepping through a hand-written module with meaningful
variable names, no exceptions with messages. What replaces them is discipline
about where the failure can be.

---

## Read the error, it tells you the phase

The four load phases from [chapter 1](01-what-is-webassembly.md) fail with
different exception types, and knowing which narrows the search enormously.

| Error | Phase | Means |
|---|---|---|
| `CompileError` | decode/validate | Malformed binary, or a type error the validator caught |
| `LinkError` | instantiate | An import is missing or has the wrong type |
| `RuntimeError` | execute | A trap — see below |
| `Incorrect response MIME type` | fetch | The server did not send `application/wasm` |

### Trap messages

```
RuntimeError: memory access out of bounds
RuntimeError: integer divide by zero
RuntimeError: unreachable
RuntimeError: call stack exhausted
RuntimeError: indirect call signature mismatch
RuntimeError: integer overflow          ← a trapping float→int conversion
```

**`memory access out of bounds`** is the one you will see most, and in a
hand-written module it almost always means an index that ran past a pool's
capacity — the engine checked the *address*, not your array length. The
diagnosis is nearly always to print the index, not the address.

**`unreachable`** means you hit an explicit `unreachable` or a compiler emitted
one for a path it believed impossible. In Rust it is what a `panic!` becomes when
you build with `panic = "abort"`.

**`call stack exhausted`** is infinite recursion, or genuinely deep recursion —
there is no tail-call elimination unless the tail-call proposal is enabled.

---

## `console.log` from wasm

There is no printing. Import one:

```wat
(import "env" "log_i32" (func $log_i32 (param i32)))
(import "env" "log_f32" (func $log_f32 (param f32)))
```

```js
env: {
  log_i32: (v) => console.log('i32', v),
  log_f32: (v) => console.log('f32', v),
}
```

Crude, and indispensable. Two refinements worth the ten minutes:

**Tag your call sites**, since one `log_f32` in a loop tells you nothing about
where it came from:

```wat
(import "env" "trace" (func $trace (param i32) (param f32)))   ;; (tag, value)
(call $trace (i32.const 7) (local.get $dist))
```

**Log strings without a string type** by putting the message in a data segment
and passing pointer and length:

```wat
(data (i32.const 60000) "bot spawn failed")
(call $log_str (i32.const 60000) (i32.const 16))
```

```js
log_str: (ptr, len) =>
  console.log(new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len))),
```

Keep the debug region at a high address, well clear of your live layout, so
adding a message never shifts anything.

---

## Inspecting memory from the console

Usually faster than any of the above. If you export the memory, the entire world
state is inspectable live:

```js
// paste into devtools while the game is running
const m = new Float32Array(game.memory.buffer);

// the player record: x, y, vx, vy, heading, alive
console.table([...m.slice(0, 6)]);

// every live bot
const BOTS = 24 / 4, STRIDE = 40 / 4;
for (let i = 0; i < 33; i++) {
  const b = BOTS + i * STRIDE;
  if (m[b + 5]) console.log(i, m[b].toFixed(1), m[b + 1].toFixed(1));
}
```

For anything you will run twice, write it as a helper on `window` at mount time.
The engines' renderers are a reasonable place for a `__dumpWorld()` behind a
flag.

**Watching a single address change** is the wasm equivalent of a watchpoint, and
Chrome's Memory Inspector (right-click an exported memory in the Scope pane →
*Reveal in Memory Inspector*) does it properly: a live hex view of linear memory
that updates as the program runs, with jump-to-address.

---

## Chrome DevTools

Genuinely good now, and better than most people expect.

**Assemble with names.** `wat2wasm --debug-names` writes the name custom section,
and then stack traces and the Sources panel show `$update_bots` instead of
`func[7]`. Costs a few hundred bytes; strip it in production if you care.

**The Sources panel shows the disassembled WAT** and lets you set breakpoints on
instructions, step, and inspect the operand stack, locals and globals in the
Scope pane. For a hand-written module this is close to a real debugger.

**For compiled languages, install the C/C++ DevTools Support (DWARF)
extension.** Build with `-g` (Emscripten) or `debug = true` (Rust) and you get
original source, real variable names, and stepping through the language you
actually wrote. This is the single biggest quality-of-life improvement available
if you are not writing WAT by hand.

**The Performance panel profiles wasm frames natively.** They appear in the flame
chart alongside JavaScript, so you can see the boundary in the trace — usually
the most valuable thing in it.

---

## Profiling, and the mistake everyone makes

The mistake is profiling the wasm and finding it fast, when the cost was the
boundary or the drawing.

Measure in this order:

1. **The whole frame.** `performance.now()` around everything.
2. **`step()` alone.** The engine's actual work.
3. **The render pass alone.**
4. **Everything else** — the difference.

```js
let acc = { step: 0, draw: 0, n: 0 };

function frame(now) {
  const t0 = performance.now();
  set_input(rot, thrust, fire);
  step(dt);
  const t1 = performance.now();
  render();
  const t2 = performance.now();

  acc.step += t1 - t0; acc.draw += t2 - t1;
  if (++acc.n === 120) {
    console.log(`step ${(acc.step / 120).toFixed(3)}ms  draw ${(acc.draw / 120).toFixed(3)}ms`);
    acc = { step: 0, draw: 0, n: 0 };
  }
  requestAnimationFrame(frame);
}
```

For Pixel Wave at 33 enemies, 160 bullets and 20 asteroids, `step` lands in the
tens of microseconds and drawing takes the overwhelming majority of the frame —
which is the normal result for a canvas game, and the reason no optimisation
effort went into the engine. **Find out where the time is before you spend any.**

Use `performance.mark` / `performance.measure` instead of raw timers if you want
the results to appear in the Performance panel's timeline, which is usually
worth it.

---

## Deterministic replay

The strongest debugging technique available for a simulation, and these engines
are *most* of the way to supporting it:

- `step(dt)` takes the timestep as a parameter — the engine has no clock
- All state is in one linear memory, and nothing else
- The RNG is internal and pure — no `Math.random()` import

The gap is that `init` does not reset `$rng` ([chapter
8](08-globals-and-state.md)), so only the *first* run after instantiation is
reproducible. Make the seed a parameter — `init(seed)` — and a run becomes a
pure function of `(seed, [(dt, input)…])`. Then record the input
sequence and you can replay a bug exactly, in a test, headless, as fast as the
CPU will go:

```js
const recording = [];                      // capture during play
recording.push([dt, rot, thrust, fire]);

function replay(upTo) {                    // reproduce, no rendering
  init(SEED);
  for (let i = 0; i < upTo; i++) {
    const [dt, r, t, f] = recording[i];
    set_input(r, t, f); step(dt);
  }
  return snapshot();                       // inspect exact state at frame `upTo`
}
```

Bisecting on `upTo` finds the frame an invariant broke in a few seconds. This is
the payoff for the design in [chapter 15](15-game-loop-architecture.md) — host
owns the clock, engine owns the state — and it is worth preserving deliberately.

The one thing that would destroy it outright is importing `Math.random()`
instead of keeping an RNG in the module. Then the run depends on host state you
cannot record, and none of the above works at any price.

---

## Assertions in a language with no assertions

There is no `assert`. Build one:

```wat
(func $assert (param $cond i32) (param $tag i32)
  (if (i32.eqz (local.get $cond))
    (then
      (call $log_i32 (local.get $tag))
      (unreachable))))                     ;; trap with the tag already logged
```

Call it at the top of anything with an invariant:

```wat
(call $assert (i32.lt_u (local.get $i) (global.get $MAX_BOTS)) (i32.const 101))
```

The trap gives you a stack trace and the log line gives you which assertion. In
a build where you want them gone, make `$assert` a no-op body — the engine will
inline the empty function away.

---

## Common failures, and what they usually are

| Symptom | Usually |
|---|---|
| `LinkError: import object field 'sinf' is not a Function` | Typo in the import object, or the nesting is wrong — it is `{ env: { sinf } }` |
| Entities drawn at nonsense positions | The host's copy of the memory offsets disagrees with the `.wat` ([ch. 7](07-javascript-interop.md)) |
| `byteLength === 0` on a typed array | `memory.grow` detached the buffer; re-create the view |
| Works once, breaks after restart | A global not reset in `init` ([ch. 8](08-globals-and-state.md)) |
| Loop runs twice or forever | `br` to a `block` vs a `loop` label ([ch. 4](04-control-flow.md)) |
| Loop runs ~4 billion times | `_u` comparison on a counter that went negative ([ch. 3](03-numbers-and-operations.md)) |
| Half the RNG output is negative | `convert_i32_s` where you needed `_u` |
| Values slightly wrong, growing worse | `f32` accumulation where you needed `f64` |
| Fine locally, fails when deployed | MIME type, or compression stripping the `Content-Type` |
| Fast in a benchmark, slow in the app | Boundary crossings per item instead of per batch |

---

← [The security model](12-security-model.md) · [Contents](README.md) · next: [Post-MVP features](14-post-mvp-features.md)
