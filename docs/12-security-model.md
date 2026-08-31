# 12 · The security model

← [Beyond the browser](11-beyond-the-browser.md) · [Contents](README.md) · next: [Debugging and profiling](13-debugging-and-profiling.md)

---

WebAssembly's sandbox is genuinely strong, and it is routinely described in a
way that overstates what it does. The precise claim is:

> **A wasm module cannot affect its host except through the imports the host
> gave it.**

That is a statement about the *host*. It says nothing about the module's
integrity with respect to itself, and the gap between those two things is where
the real vulnerabilities live.

---

## What the sandbox actually guarantees

**Memory isolation.** Linear memory is a bounds-checked byte array. Out of range
traps. There is no pointer to host memory, no way to construct one, and no
address space shared with the embedder. A module cannot read the JavaScript
heap, another instance's memory, or the process it runs in.

**Control-flow integrity.** Structured control flow ([chapter
4](04-control-flow.md)) means every branch target is statically known. Indirect
calls go through a table and are signature-checked at runtime ([chapter
6](06-functions-tables.md)). You cannot jump into the middle of a function, and
you cannot synthesise a code address.

**A protected call stack.** Return addresses live in engine memory the module
cannot address. **Stack smashing does not work.** Return-oriented programming has
no gadgets to chain, because it cannot reach the return addresses.

**No ambient authority.** No syscalls. No `fetch`, no clock, no filesystem, no
randomness — unless imported. A module you gave nothing to can compute and
nothing else.

**Type safety before execution.** The whole module is validated up front. There
is no runtime type confusion, and no way to reinterpret a function as data or
data as code.

**Code and data are separate.** Instructions are not addressable. You cannot
write bytes into memory and execute them, which forecloses the entire
shellcode-injection category.

That is a stronger position than a native process gets. It is fair to say wasm
is one of the better-designed sandboxes in wide deployment.

---

## What it does not guarantee

### Memory safety *inside* the module

This is the important one, and it is consistently undersold.

Linear memory is a flat byte array with no internal structure. Your allocator's
metadata, your arrays, your strings and your compiler's shadow stack are all in
it, adjacent, unprotected. So:

- **Buffer overflows work.** Writing past the end of one array corrupts the next
  one. Nothing knows they are two arrays.
- **Use-after-free works**, and is *more* exploitable than native, because wasm
  allocators reuse freed blocks eagerly and there are no guard pages, no ASLR
  and no hardened `malloc`.
- **The shadow stack is corruptible.** Locals live in engine memory, but any C or
  Rust variable whose address is taken is spilled to a compiler-managed stack
  *inside* linear memory. Overflowing a buffer next to it overwrites other
  locals — including, classically, a saved function-pointer value.
- **Uninitialised reads work**, returning whatever the last owner left there.

The research paper "Everything Old is New Again: Binary Security of WebAssembly"
(USENIX Security 2020) is the canonical treatment, and its finding is
uncomfortable: several mitigations that native platforms have had for twenty
years — ASLR, stack canaries, guard pages, W^X within the heap — are **absent**
in wasm. A heap overflow that would be caught natively can be a reliable
primitive in wasm.

The consolation is the blast radius. Corrupting your own linear memory cannot
reach the host. But if that memory holds another user's session data in a
multi-tenant module, "contained to the module" is not much comfort.

### Side channels

Spectre-class attacks are a CPU property, not a wasm one, and wasm gives an
attacker a convenient way to run timing code in a browser. Mitigations are at
the platform level: reduced timer resolution, `SharedArrayBuffer` gated behind
cross-origin isolation, site isolation. Do not assume the sandbox helps here.

### Resource exhaustion

Nothing in the MVP stops a module from looping forever or calling
`memory.grow` until the allocator refuses. In a browser that means a hung tab.
For untrusted guests you need runtime-level controls: **fuel metering**
(Wasmtime charges per instruction and traps at a budget), memory limits at
instantiation, and epoch-based interruption.

### Supply chain

A `.wasm` is opaque. A malicious dependency compiled into a module is as
invisible as any minified JavaScript, and rather harder to audit. `wasm2wat` and
`wasm-decompile` help, but nobody is reading 400 KB of decompiled output.
Reproducible builds and provenance matter more here than usual.

---

## The imports are the security boundary

Everything a module can do is in its import list. This makes review unusually
tractable — you can enumerate a module's entire capability set from its
`(import …)` declarations, and you can grep for it.

```bash
wasm-objdump -x module.wasm | grep -A100 '^Import'
```

Both engines in this repository import exactly two functions:

```wat
(import "env" "sinf" (func $sinf (param f32) (result f32)))
(import "env" "cosf" (func $cosf (param f32) (result f32)))
```

The complete list of things they can do to the outside world is *ask for a sine
and a cosine*. No network, no storage, no clock, no randomness — the RNG is
internal and seeded from a constant. Hostile or not, the worst outcome is a
wrong number on a canvas.

That is a property you get by *design*, not by luck, and it generalises:

**Import the narrowest thing that works.** A module that needs one configuration
value should import a global, not a `getConfig()` function that could return
anything. A module that needs to log should import
`log(ptr: i32, len: i32)`, not a JavaScript function that receives an object it
could probe.

**Never import a general-purpose escape hatch.** An import that evaluates a
string, performs an arbitrary `fetch`, or exposes `postMessage` to the module
hands over the entire sandbox in one line. If the module can reach `eval`, there
is no sandbox.

**Validate on the host side of every import.** The module's own validation says
nothing about the values it passes you. An imported `draw(ptr, len)` must
bounds-check `ptr` and `len` against the memory it is reading — the module can
pass anything, including values that would make your host code read out of the
`ArrayBuffer` or allocate gigabytes.

```js
function readBytes(ptr, len) {
  const buf = memory.buffer;
  if (ptr < 0 || len < 0 || ptr + len > buf.byteLength) {
    throw new RangeError('module passed an out-of-range slice');
  }
  return new Uint8Array(buf, ptr, len);
}
```

Without that check the module cannot escape *its* sandbox — but it can make your
JavaScript throw, or allocate, or read the wrong region, and in a host with more
imports it can chain that into something worse.

---

## If you are the host, running untrusted modules

A checklist, roughly in order of importance:

1. **Enumerate and minimise imports.** This is the whole capability set. Review it
   like you would review a permissions manifest.
2. **Cap memory at instantiation.** `new WebAssembly.Memory({ initial, maximum })`,
   and declare the maximum in the module or refuse to instantiate one without.
3. **Meter execution.** Wasmtime fuel, epoch interruption, or run it in a Worker
   you can terminate. A browser main thread offers none of this.
4. **One instance per tenant.** Instances share nothing by default ([chapter
   8](08-globals-and-state.md)); do not undermine that by importing a shared
   memory.
5. **Validate everything crossing inward.** Every pointer, every length, every
   index.
6. **Do not let module-controlled data reach `eval`, `innerHTML`, a SQL string,
   or a filesystem path.** The sandbox is irrelevant if the host is the confused
   deputy.
7. **Isolate the page.** COOP/COEP if you use threads; a strict CSP regardless.

---

## If you are the module author

1. **Use a memory-safe source language.** Rust's guarantees hold inside wasm.
   C's absence of them holds too.
2. **Prefer fixed-size pools to a general allocator** where the shape allows.
   No allocator means no allocator metadata to corrupt — which is, incidentally,
   one more reason the entity-pool design in [chapter 16](16-entity-pools.md) is
   a reasonable choice beyond performance.
3. **Bounds-check indices that come from the host.** The engine checks the
   *address*; it has no idea your array is 33 elements long. An index of 500 into
   a 33-slot pool is a perfectly legal memory access into whatever lives after it.
4. **Trap rather than continue** when an invariant breaks. `unreachable` in
   development is worth more than a plausible wrong answer.
5. **Strip debug info from release builds.** `wasm-strip`, or
   `--strip-debug --strip-producers`. Custom sections leak paths, toolchain
   versions and sometimes source.

---

## An honest summary

WebAssembly's sandbox is one of the better ones available, and it is a real
improvement on loading native code into your process. It is not a fix for unsafe
code. A C program with a heap overflow, compiled to wasm, still has a heap
overflow — with **fewer** mitigations against exploitation than it would have
had natively, and a smaller blast radius if it is exploited.

Both halves of that sentence are true, and most writing on the subject picks
one.

---

← [Beyond the browser](11-beyond-the-browser.md) · [Contents](README.md) · next: [Debugging and profiling](13-debugging-and-profiling.md)
