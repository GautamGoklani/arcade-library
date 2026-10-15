# Glossary

← [Contents](README.md)

Every term this course uses, defined once. Chapter references point at where it
is explained properly.

---

**AoS / Array-of-structs** — a layout where each entity's fields are contiguous
and entities are laid end to end. Contrast SoA. [ch. 16](16-entity-pools.md)

**Alignment** — the requirement or preference that a memory address be a
multiple of the access width. In wasm the `align=` immediate is a *hint*, not a
constraint; a misaligned access is legal but may be slower. Atomics are the
exception and do trap. [ch. 5](05-linear-memory.md)

**AssemblyScript** — a TypeScript-shaped language compiled directly to wasm.
Not TypeScript. [ch. 10](10-source-languages.md)

**Binaryen** — a compiler infrastructure library that uses wasm as its IR.
Source of `wasm-opt`. [ch. 9](09-toolchain.md)

**Block** — a structured control region. Branching to a block's label jumps to
just *after* the block — a `break`. [ch. 4](04-control-flow.md)

**Bulk memory** — the `memory.copy` / `memory.fill` family. Shipped everywhere.
[ch. 14](14-post-mvp-features.md)

**Bump allocator** — an allocator that only moves a pointer forward and never
frees individual objects. The simplest useful one. [ch. 5](05-linear-memory.md)

**Capability-based security** — the model where a component can only do what it
was explicitly handed the means to do. Wasm's import list is a capability list.
[ch. 12](12-security-model.md)

**Component Model** — a proposal layering typed, language-agnostic interfaces
and composition over core wasm. Interfaces are written in WIT.
[ch. 11](11-beyond-the-browser.md)

**Custom section** — a named binary section the engine ignores. Carries the
name section, DWARF debug info, producer metadata. Strippable.
[ch. 1](01-what-is-webassembly.md)

**Data segment** — bytes copied into linear memory at instantiation. How string
literals and constant tables get there. [ch. 5](05-linear-memory.md)

**Detached buffer** — what happens to a JavaScript `ArrayBuffer` view after
`memory.grow` reallocates. `byteLength` becomes 0. [ch. 7](07-javascript-interop.md)

**DWARF** — the debug-info format, carried in a custom section, that lets Chrome
step through original C/Rust source. [ch. 13](13-debugging-and-profiling.md)

**Emscripten** — a C/C++ toolchain that emulates POSIX on the web: filesystem,
SDL, pthreads, OpenGL→WebGL. Powerful and heavy. [ch. 10](10-source-languages.md)

**`externref`** — an opaque reference to a host value that a module can hold and
pass back but not inspect. [ch. 14](14-post-mvp-features.md)

**Folded form** — the parenthesised WAT syntax where an instruction's operands
are written as children. Pure sugar over linear form. [ch. 2](02-wat-syntax.md)

**Fuel metering** — a runtime feature that charges a guest per instruction and
traps at a budget. Wasmtime. [ch. 12](12-security-model.md)

**`funcref`** — a reference to a function; the element type of a table.
[ch. 6](06-functions-tables.md)

**Global** — a module-scoped typed value, mutable or not. **Has no address** —
`i32.load` cannot reach it. [ch. 8](08-globals-and-state.md)

**Host** — whatever embeds the wasm engine: a browser, Node, Wasmtime, Envoy.

**Import object** — the nested JS object supplying a module's declared imports.
Shape is `{ module: { name: value } }`. [ch. 7](07-javascript-interop.md)

**Instance** — a module plus its own memory, globals and tables. Instances share
nothing by default. [ch. 8](08-globals-and-state.md)

**Instantiation** — allocating memory, applying data segments, wiring imports,
running `start`. Fails with `LinkError`. [ch. 1](01-what-is-webassembly.md)

**Linear memory** — the single flat, growable, bounds-checked byte array a
module addresses with `i32`. [ch. 5](05-linear-memory.md)

**`LinkError`** — instantiation failed: a missing or mistyped import.

**Local** — a function-scoped variable. Always zero-initialised, never
addressable. [ch. 2](02-wat-syntax.md)

**Loop** — a structured control region. Branching to a loop's label jumps *back*
to its start — a `continue`. A loop does not repeat on its own.
[ch. 4](04-control-flow.md)

**Memory64** — an in-flight proposal for 64-bit addressing.
[ch. 14](14-post-mvp-features.md)

**Minimax polynomial** — a polynomial approximation minimising *peak* error over
a range, as opposed to a Taylor series which minimises error at one point. What
`libm` actually uses. [ch. 17](17-math-without-a-stdlib.md)

**Module** — the compiled, validated code and declarations. Structured-cloneable,
so it can be posted to workers. [ch. 7](07-javascript-interop.md)

**Multi-value** — returning more than one value from a function or block.
Shipped. [ch. 14](14-post-mvp-features.md)

**Name section** — a custom section mapping indices to `$names`, so devtools show
`$update_bots` rather than `func[7]`. `wat2wasm --debug-names`.
[ch. 9](09-toolchain.md)

**Operand stack** — the value stack instructions push and pop. Its shape is
statically known at every point, which is what makes validation possible.
[ch. 2](02-wat-syntax.md)

**Page** — the unit of linear memory: **65,536 bytes**, always.
[ch. 5](05-linear-memory.md)

**Pool** — a fixed-size array of records with an `active` flag, used instead of
an allocator. [ch. 16](16-entity-pools.md)

**Relaxed SIMD** — SIMD operations that trade bit-exact determinism for hardware
speed. [ch. 14](14-post-mvp-features.md)

**`RuntimeError`** — a trap during execution: out of bounds, divide by zero,
`unreachable`, stack exhausted, signature mismatch. [ch. 13](13-debugging-and-profiling.md)

**Shadow stack** — a compiler-managed stack *inside* linear memory, for variables
whose address is taken. Unlike the engine's call stack, it is corruptible.
[ch. 6](06-functions-tables.md), [ch. 12](12-security-model.md)

**SIMD** — single instruction, multiple data. Wasm's `v128` type and ~200 lane
operations. [ch. 14](14-post-mvp-features.md)

**SoA / Struct-of-arrays** — a layout where each field gets its own array.
Better for sweeping one field; worse for touching one entity.
[ch. 16](16-entity-pools.md)

**Start function** — one function run at instantiation, before any export can be
called. [ch. 6](06-functions-tables.md)

**Stride** — the byte distance between consecutive records in a pool.
[ch. 5](05-linear-memory.md)

**Table** — an array of references, indexed for `call_indirect`. The MVP allows
one per module. [ch. 6](06-functions-tables.md)

**Tail call** — `return_call`, reusing the current frame instead of pushing one.
[ch. 14](14-post-mvp-features.md)

**Trap** — an unrecoverable abort that unwinds to the host. Surfaces as
`RuntimeError` in JavaScript. Not catchable inside wasm without the exception
proposal. [ch. 13](13-debugging-and-profiling.md)

**Validation** — the static type-check of an entire module before execution. The
property everything else rests on. [ch. 1](01-what-is-webassembly.md)

**WABT** — the WebAssembly Binary Toolkit: `wat2wasm`, `wasm2wat`,
`wasm-objdump`, `wasm-decompile`. [ch. 9](09-toolchain.md)

**WASI** — the WebAssembly System Interface. Capability-based POSIX-adjacent
imports for non-browser hosts. [ch. 11](11-beyond-the-browser.md)

**WAT** — WebAssembly Text format. The human-readable projection of the binary.
[ch. 2](02-wat-syntax.md)

**WIT** — WebAssembly Interface Types, the IDL of the Component Model.
[ch. 11](11-beyond-the-browser.md)

**xorshift** — a family of very fast PRNGs built from shifts and xors. The
engines here use xorshift32 with the `(13, 17, 5)` triple.
[ch. 17](17-math-without-a-stdlib.md)

---

← [Contents](README.md)
