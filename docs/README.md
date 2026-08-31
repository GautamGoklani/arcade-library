# WebAssembly, from first principles

A course, not a changelog. It was written alongside two arcade engines in this
repository, but only the last third is about them — the rest is the language,
the toolchain and the ecosystem, written the way I wish they had been explained
to me.

Every code sample is real WAT that compiles. Where a chapter draws on
`games/pixel-wave/game.wat` or `games/vector-arena/game.wat` it says so, and you
can open the file and check.

---

## Who this is for

You write JavaScript, or C, or Rust, or Python. You have heard WebAssembly
described as "assembly for the web" or "near-native speed in the browser" and
found that neither claim tells you what to *do*. You want to know what the
thing actually is, when it is worth reaching for, and how it works underneath.

No prior assembly experience is assumed. Chapter 3 assumes you know what an
integer overflow is; chapter 5 assumes you know what a pointer is, or are
willing to learn in about four paragraphs.

---

## Part I — The language

| | | |
|---|---|---|
| 01 | [What WebAssembly actually is](01-what-is-webassembly.md) | The design goals, the four common misconceptions, and an honest account of when it is the wrong tool |
| 02 | [Reading and writing WAT](02-wat-syntax.md) | S-expressions, the stack machine, folded vs flat form, the module grammar |
| 03 | [Numbers and operations](03-numbers-and-operations.md) | Four value types and nothing else. Signedness in the operator, not the type. Float determinism |
| 04 | [Control flow](04-control-flow.md) | Structured blocks, `br` as "break to a label", loops that don't loop, the validation rules |
| 05 | [Linear memory](05-linear-memory.md) | One growable byte array. Addressing, alignment, endianness, bounds, and building an allocator |
| 06 | [Functions, tables and indirect calls](06-functions-tables.md) | The call stack you can't see, function pointers, and how dynamic dispatch works |
| 07 | [The JavaScript boundary](07-javascript-interop.md) | Imports, exports, typed-array views, strings, and what a crossing actually costs |
| 08 | [Globals, mutability and module state](08-globals-and-state.md) | Where state lives, why globals are not memory, and instance isolation |

## Part II — The ecosystem

| | | |
|---|---|---|
| 09 | [The toolchain](09-toolchain.md) | wabt, Binaryen, wasm-pack, wasm-opt, and reading a disassembly |
| 10 | [Source languages](10-source-languages.md) | Rust, C/C++, AssemblyScript, Zig, Go, TinyGo — what each one costs you in binary size and ceremony |
| 11 | [Beyond the browser](11-beyond-the-browser.md) | WASI, edge runtimes, plugin sandboxes, and the Component Model |
| 12 | [The security model](12-security-model.md) | What the sandbox does and does not protect, and the classes of bug that survive it |
| 13 | [Debugging and profiling](13-debugging-and-profiling.md) | Source maps, DWARF, trap messages, and how to find the frame that is costing you |
| 14 | [Post-MVP features](14-post-mvp-features.md) | SIMD, threads, bulk memory, reference types, GC, tail calls, exceptions — what has shipped |

## Part III — The engines in this repository

| | | |
|---|---|---|
| 15 | [Architecture of a wasm game loop](15-game-loop-architecture.md) | Who owns the clock, the fixed-timestep question, and the three-call frame |
| 16 | [Case study: entity pools in linear memory](16-entity-pools.md) | Fixed offsets, strides, the free-slot scan, and why there is no allocator |
| 17 | [Case study: maths without a standard library](17-math-without-a-stdlib.md) | xorshift RNG, why `sinf` is imported, distance without `sqrt`, and closest-approach dodging |

## Reference

- [Glossary](glossary.md) — every term this course uses, defined once
- [Instruction cheatsheet](cheatsheet.md) — the ~60 opcodes you will actually type
- [Further reading](further-reading.md) — specs, books, talks, and the handful of blog posts worth the time
- [reference/](reference/) — the original project documents for Pixel Wave (technical reference, roadmap, originality statement). They describe the **v2 engine at its original balance**; see [`../games/pixel-wave/README.md`](../games/pixel-wave/README.md) for what has changed since

---

## Three ways through this

**"I want to understand the technology."** Read Part I in order, then 11 and 12.
Skip Part III. About three hours.

**"I want to make my own thing go faster."** Read 01, then 07 (the boundary is
almost always where the performance went), then 10 to choose a source language,
then 13. You may never write a line of WAT, and that is the normal outcome.

**"I want to hand-write WAT like these engines do."** Read Part I completely —
you cannot skip chapter 5 — then Part III, with `game.wat` open beside it. Then
write something small and awful. That step is not optional.

---

## A note on scope

Hand-writing an engine in WAT, as this repository does, is **not** the
recommended way to build software. It was done here to learn the machine
without a compiler in the way, and the [chapter on source
languages](10-source-languages.md) is blunt about what it costs. The
documentation is the deliverable; the games are the excuse.
