# 01 · What WebAssembly actually is

← [Contents](README.md) · next: [Reading and writing WAT](02-wat-syntax.md)

---

WebAssembly is a **binary instruction format for a stack-based virtual
machine**, plus a specification of how a program in that format is loaded,
validated, instantiated and called. That is the whole of it. Everything else —
the browser, the toolchains, the "near-native speed" marketing — is context.

Three properties follow from that definition and are worth holding onto,
because most confusion about WebAssembly comes from missing one of them.

**It is a compilation target, not a language you are expected to write.**
The text format (WAT) exists so the binary can be read and debugged by humans.
It is not a productivity language. This repository hand-writes it deliberately,
as an exercise; that is the exception, not the practice.

**It is deterministic and sandboxed by construction.** A module cannot read a
byte it was not given, cannot call a function it was not handed, and cannot
observe anything about the host it was not told. It has no syscalls, no ambient
authority, and no way to obtain either. Capability comes in through imports and
nowhere else.

**It has no idea what a browser is.** There is no DOM in the specification, no
`console`, no network, no clock. A wasm module in a browser can reach those
things only because JavaScript passed it a function that does.

---

## The design goals, and what each one bought

The MVP shipped in 2017 across all four major engines simultaneously — which
almost never happens — because the goals were unusually narrow.

| Goal | What it produced |
|---|---|
| **Fast to decode** | A binary format that can be validated and compiled *while it downloads*. `instantiateStreaming` compiles from the network stream; a 3 MB module is often running before the last byte lands |
| **Predictable performance** | No JIT warm-up, no deoptimisation cliff, no hidden classes. The same code takes the same time on run one and run one million — the property JavaScript cannot offer |
| **Safe** | Memory-safe *with respect to the host*. A wasm module with a heap overflow corrupts its own linear memory and nothing else |
| **Language-agnostic** | Nothing in the format favours any source language. No GC in the MVP, no object model, no exception semantics — the deliberate absence of opinions |
| **Part of the web platform** | Same origin policy, same CSP, same devtools, same `fetch`. Not a plugin |

The cost of "language-agnostic" was that the MVP is very low-level: four number
types, one flat memory, no strings, no structs, no GC. Every higher-level idea
has to be built on top by the source language's runtime — which is why a Rust
"hello world" was 1.7 MB before anyone learned to trim it.

---

## Four things it is not

### It is not faster than JavaScript

Not in general. Modern JavaScript engines are extraordinary, and for
short-lived, monomorphic, numeric code a good JIT will match wasm or beat it.
What wasm gives you is different:

- **Predictability** — no warm-up, no deopt, no GC pause you didn't schedule
- **A floor under the worst case** — the pathological JS cases (megamorphic call
  sites, unexpected type transitions) don't exist
- **Startup** — compiling 1 MB of wasm is much cheaper than parsing 1 MB of JS

If your bottleneck is DOM work, layout, network, or crossing into JavaScript
constantly, WebAssembly will make your program **slower**, because you have
added a boundary and changed nothing that mattered. Measure before you port.

### It is not a JavaScript replacement

It cannot touch the DOM. There is no path by which it could, in the current
spec, without going through an imported JavaScript function. Frameworks that
advertise "no JavaScript" (Blazor WebAssembly, Yew, Leptos) ship a JavaScript
shim that does the actual DOM mutation and marshals calls across the boundary.
That shim is frequently the performance story.

### It is not only for the browser

Arguably the more important deployment now is server-side: WASI on the command
line, Fastly Compute and Cloudflare Workers at the edge, Envoy and Istio
filters, Shopify Functions, Figma plugins, Envoy's `wasm` extensions, and the
plugin systems of a dozen databases. See
[chapter 11](11-beyond-the-browser.md).

### It is not unsafe code made safe

The sandbox protects the *host* from the module. It does not protect the module
from itself. A C program compiled to wasm still has buffer overflows — they
just overflow into other parts of the same linear memory instead of into the
process. Use-after-free, uninitialised reads and heap grooming attacks all work
inside a wasm module. [Chapter 12](12-security-model.md) goes through this
properly, because it is routinely oversold.

---

## When it is genuinely the right tool

A short and honest list:

- **You have an existing C/C++/Rust codebase and want it on the web.** FFmpeg,
  SQLite, ImageMagick, Blender, AutoCAD, Photoshop. This is the flagship use
  case and it is not close.
- **Sustained numeric work.** Codecs, compression, cryptography, physics,
  simulation, image and audio processing, ML inference.
- **You need predictable frame timing.** Games, audio worklets, anything where a
  GC pause is a visible glitch.
- **You need to run untrusted code.** A plugin system where the guest is a wasm
  module gets a real sandbox with per-instance memory limits, for free.
- **Cold start matters.** Edge runtimes boot a wasm instance in microseconds; a
  container takes hundreds of milliseconds.

And when it is not: DOM-heavy UI, glue code, anything I/O-bound, anything where
the hot path crosses the boundary per item rather than per batch, and any case
where you would be rewriting working JavaScript on a hunch.

---

## How a module gets from bytes to running

Four distinct phases. Knowing where they split is most of debugging.

```
  .wat  ──parse──▶  .wasm bytes  ──decode──▶  module  ──validate──▶  compile
                                                                        │
                                                                   instantiate
                                                                        │
                                              (imports supplied) ───────▶ instance
                                                                        │
                                                                   call exports
```

1. **Decode** — read the binary's sections. Fails on a malformed file.
2. **Validate** — type-check the whole module *before anything runs*. Every
   instruction's stack effects are checked statically; every branch target must
   agree on type; every memory access must be against a declared memory. This is
   why there is no such thing as a "type error at runtime" in wasm, and why a
   validated module cannot escape its sandbox.
3. **Instantiate** — allocate the memory, apply data segments, wire up imports,
   run the start function. Failures here are `LinkError`: an import you promised
   and did not supply.
4. **Execute** — call an export. Failures here are `RuntimeError`, always
   described as a **trap**: out-of-bounds access, integer divide by zero,
   `unreachable`, stack exhaustion, a failed indirect-call signature check.

Validation happening up front is the property everything else rests on. It is
what makes streaming compilation possible, what makes the sandbox provable, and
what makes a wasm binary safe to run from an untrusted source in a way that a
native `.so` never will be.

---

## What a module can contain

A module is a list of typed sections, all optional:

| Section | Holds |
|---|---|
| Type | Function signatures, deduplicated |
| Import | What the module demands from the host: functions, memories, tables, globals |
| Function / Code | The functions themselves — signature index and body |
| Table | Arrays of references, used for indirect calls ([ch. 6](06-functions-tables.md)) |
| Memory | The linear memory declaration: initial and maximum pages ([ch. 5](05-linear-memory.md)) |
| Global | Module-level typed values, mutable or not ([ch. 8](08-globals-and-state.md)) |
| Export | What the host may reach: functions, memory, tables, globals |
| Start | One function run at instantiation, before any export can be called |
| Element / Data | Initialisers for tables and memory |
| Custom | Anything — names, DWARF debug info, source maps. Ignored by the engine |

In the MVP a module may declare **at most one memory and one table**. The
multi-memory proposal relaxes this; see [chapter 14](14-post-mvp-features.md).

The engines in this repository use six of these. Here is the entire
declaration surface of `games/pixel-wave/game.wat`, which is a complete game:

```wat
(module
  (import "env" "sinf" (func $sinf (param f32) (result f32)))
  (import "env" "cosf" (func $cosf (param f32) (result f32)))
  (memory (export "memory") 1)          ;; 64 KB, exported so JS can read it
  (global $MAX_BOTS i32 (i32.const 33))
  ;; … ~40 more globals, ~20 functions …
  (func (export "step") (param $dt f32) …)
)
```

Two imports, one memory, some globals, some functions. That is the whole
vocabulary — and the next six chapters are about using exactly this much.

Two of the five engines here do not even need the imports:
`games/worm-chase/game.wat` and `games/sector-defense/game.wat` turn through no
angles at all, so their import section is empty and the whole module is a pure
function of its inputs.

---

← [Contents](README.md) · next: [Reading and writing WAT](02-wat-syntax.md)
