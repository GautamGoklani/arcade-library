# 11 · Beyond the browser

← [Source languages](10-source-languages.md) · [Contents](README.md) · next: [The security model](12-security-model.md)

---

WebAssembly's name has become the least accurate thing about it. Nothing in the
specification mentions the web, and the fastest-growing deployments are
server-side.

The reason is the property from [chapter 1](01-what-is-webassembly.md): a module
has **no ambient authority**. It cannot open a file, make a connection, read a
clock or spawn a thread unless something hands it a function that does. For a
browser that is a security necessity. For a plugin host, an edge runtime or a
multi-tenant platform it is exactly the isolation model you would have designed
anyway — and it comes with microsecond startup instead of a container's
hundreds of milliseconds.

---

## WASI

**The WebAssembly System Interface** is a standard set of imports for the things
a program normally gets from an operating system: files, clocks, random numbers,
environment variables, sockets.

Crucially it is **capability-based**. There is no global filesystem. A module
receives *pre-opened directory handles* from the runtime and can reach nothing
outside them:

```bash
wasmtime run --dir=./data app.wasm      # ./data is the entire visible filesystem
wasmtime run app.wasm                    # no filesystem at all
```

That single design decision is why WASI is interesting. A native binary given a
path can read anything the user can; a WASI module given a path can read that
path.

Two versions are in play:

**Preview 1** (`wasi_snapshot_preview1`) — the widely-deployed one. A flat set
of POSIX-ish function imports. Supported everywhere, stable, and what
`GOOS=wasip1` and Rust's `wasm32-wasip1` target.

**Preview 2 / WASI 0.2** — rebuilt on the Component Model (below), with
interfaces defined in WIT rather than as raw imports. Adds proper networking,
HTTP, and composable interfaces. This is the direction, and adoption is
underway.

### Runtimes

| Runtime | Notes |
|---|---|
| **Wasmtime** | The Bytecode Alliance reference. Cranelift JIT, excellent WASI support, embeddable from Rust/C/Python/Go |
| **Wasmer** | Multiple compiler backends, a package registry, strong embedding story |
| **WasmEdge** | CNCF project; AI/ML extensions, tuned for edge and serverless |
| **wazero** | Pure Go, zero CGO. The obvious choice for embedding in a Go program |
| **wasm3 / WAMR** | Interpreters for microcontrollers. WAMR runs in tens of kilobytes |
| **Node.js / Deno / Bun** | All ship WASI support behind a flag or an import |

```bash
rustup target add wasm32-wasip1
cargo build --target wasm32-wasip1 --release
wasmtime target/wasm32-wasip1/release/app.wasm
```

That binary runs unmodified on Linux, macOS, Windows and ARM. "Compile once,
run anywhere" is an old promise, but the artefact here is 200 KB rather than a
JVM.

---

## Edge and serverless

The economics are startup time. A V8 isolate boots in ~5 ms; a wasm instance in
tens of *microseconds*; a container in hundreds of milliseconds. When you are
billing per request and cold-starting constantly, that is the whole argument.

- **Fastly Compute** — wasm-native, Lucet then Wasmtime. Sub-millisecond cold
  start, and the platform that made the case first.
- **Cloudflare Workers** — primarily V8 isolates, with wasm supported inside a
  Worker. Handy for a CPU-heavy step in an otherwise JS handler.
- **Vercel, Deno Deploy, AWS Lambda (via a custom runtime), Azure** — all have
  a wasm path.
- **Spin** (Fermyon) — a framework for wasm microservices, WASI-native.
- **wasmCloud** — a CNCF distributed application platform built on components.

The recurring shape: your handler is a wasm module, the platform supplies HTTP
in and out as imports, and there is no process, no container and no filesystem
unless you asked.

---

## Plugin systems

This is arguably wasm's best fit anywhere, and the list of adopters is long
because the alternative — loading a native `.so` into your process — has no
safe version.

| Product | Uses wasm for |
|---|---|
| **Envoy / Istio** | HTTP filters, written in any language, sandboxed from the proxy |
| **Figma** | Plugins, with a hard memory and CPU budget per plugin |
| **Shopify Functions** | Merchant-supplied logic in the checkout path |
| **Zellij, Lapce, Zed** | Editor and terminal extensions |
| **Redpanda, TiDB, SingleStore** | User-defined functions inside the database |
| **Suborbital, Extism** | Frameworks for making *your* app pluggable |

**Extism** is worth a specific mention: it is a plugin framework that gives you
host SDKs for a dozen languages and plugin SDKs for a dozen more, so "let users
extend this" becomes a dependency rather than a project.

The properties that make it work: per-instance memory caps, deterministic
execution, fuel metering (charge the guest per instruction and cut it off), and
a capability list you control. None of those are available for a native plugin.

---

## The Component Model

The MVP's interface vocabulary is four number types. Everything richer — a
string, a record, a list, an optional — is a private convention between a module
and its host, which is why `wasm-bindgen` glue only works with `wasm-bindgen`
modules.

The **Component Model** fixes this. Interfaces are described in **WIT**
(WebAssembly Interface Types):

```wit
package arcade:engine@1.0.0;

interface world {
  record vec2 { x: f32, y: f32 }

  record entity {
    position: vec2,
    velocity: vec2,
    heading: f32,
    alive: bool,
  }

  step: func(dt: f32);
  entities: func() -> list<entity>;
  set-input: func(rotate: s32, thrust: bool, fire: bool);
}

world engine {
  import host-math: interface { sin: func(x: f32) -> f32 }
  export world;
}
```

From that one file, `wit-bindgen` generates bindings for Rust, C, Go,
JavaScript, Python and more. A component written in Rust can be composed with a
component written in Go, with the types checked at composition time, and neither
knows the other's language.

What it gives you:

- **Language-agnostic interfaces** — real strings, records, lists, variants,
  results
- **Composition** — components link to each other, not just to a host
- **Virtualisation** — a component that imports `wasi:filesystem` can be handed a
  *different component* implementing it, with no code change. That is a
  remarkably clean way to sandbox or mock
- **Versioned, semver-aware interfaces**

Status: stabilised for WASI 0.2, tooling maturing fast (`wasm-tools`,
`jco` for JavaScript, `cargo-component`). Browser support for components is not
there yet — `jco transpile` produces a JS shim in the meantime.

If you are betting on where wasm goes next, this is the thing to read about.

---

## Embedded and IoT

**WAMR** (WebAssembly Micro Runtime) runs on microcontrollers in tens of
kilobytes of RAM, with an interpreter, an AOT compiler and an XIP mode for
running from flash. **wasm3** is a fast pure interpreter in similar territory.

The pitch is over-the-air updates for heterogeneous fleets: ship one wasm
module to devices with three different CPU architectures, sandboxed from the
firmware, with a memory budget you set. Compared to shipping native code to a
field device, the safety argument is strong.

---

## Blockchain

Several chains use wasm as their smart-contract VM — NEAR, Polkadot
(via `pallet-contracts`), CosmWasm, Internet Computer. The attraction is
determinism and metering: wasm's float semantics are bit-exact
([chapter 3](03-numbers-and-operations.md)), and a runtime can charge per
instruction precisely.

Included for completeness. It is a real deployment surface, but the constraints
there (gas metering, no floats in some chains, chain-specific host functions)
generalise poorly to everything else in this chapter.

---

## What this means for a browser developer

Two things worth taking away even if you never leave the browser.

**Your wasm module is more portable than you think.** A module that imports only
what it truly needs will run under Wasmtime, on Fastly, inside Envoy and on a
microcontroller. The engines in this repository import `sinf` and `cosf` — supply
those from any host and they run there. That is not an accident of these
engines; it is what a narrow import surface buys.

**Design the import surface as a capability list.** Ask what the module would be
able to do if it were hostile, and the answer is "exactly what you imported".
That framing improves browser code too — it is the same discipline that keeps
the boundary narrow for performance reasons in
[chapter 7](07-javascript-interop.md).

---

← [Source languages](10-source-languages.md) · [Contents](README.md) · next: [The security model](12-security-model.md)
