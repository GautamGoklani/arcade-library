# 10 · Source languages

← [The toolchain](09-toolchain.md) · [Contents](README.md) · next: [Beyond the browser](11-beyond-the-browser.md)

---

Almost nobody should hand-write WAT. This chapter is about what to write
instead, and the honest cost of each option.

The decision comes down to four axes, and they trade against each other:

1. **Binary size** — how much runtime the language drags along
2. **Interop ergonomics** — how much glue you write to move a string across
3. **Ecosystem** — whether the libraries you need already compile
4. **Familiarity** — the one people undervalue, and shouldn't

---

## The comparison

Sizes are for a *non-trivial* module — a few thousand lines doing real work,
optimised and stripped, before compression. Hello-world numbers are misleading
in both directions.

| Language | Realistic size | GC shipped | Interop | Best for |
|---|---|---|---|---|
| **Rust** | 20–100 KB | No | Excellent (`wasm-bindgen`) | The default answer for new work |
| **Zig** | 5–30 KB | No | Manual, clean | Smallest sensible output; systems work |
| **C (bare clang)** | 3–20 KB | No | Manual | Porting existing C with no libc need |
| **C/C++ (Emscripten)** | 50 KB – several MB | No | Excellent, heavy | Porting anything that expects POSIX |
| **AssemblyScript** | 5–50 KB | Yes, small | Good | JS/TS teams; small numeric modules |
| **TinyGo** | 30–300 KB | Yes | Fair | Go, when size matters |
| **Go** | 2 MB+ | Yes | Fair (`syscall/js`) | Go, when it doesn't |
| **Hand-written WAT** | Exactly what you wrote | No | Manual, total control | Learning. Tiny kernels. Little else |

---

## Rust

The best-supported path, and the one to pick if nothing else decides it for you.

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-pack
wasm-pack build --target web
```

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn step(dt: f32) -> f32 { dt * 2.0 }

#[wasm_bindgen]
pub fn greet(name: &str) -> String {
    format!("hello, {name}")
}
```

`wasm-bindgen` generates the JavaScript glue for that second function — the
allocation, the UTF-8 encode, the pointer-and-length handoff, the free. Written
by hand it is the thirty lines from [chapter 7](07-javascript-interop.md), and
getting the ownership wrong leaks memory on every call. This is the single
strongest argument for Rust here: the boundary is the hard part, and it is
generated.

**What makes it big:** panic machinery and formatting. `format!` and friends
pull in a surprising amount. Mitigations that actually work:

```toml
[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
panic = "abort"      # removes unwinding — usually the single biggest win
strip = true
```

Then `wasm-opt -Oz`. A numeric module can land under 20 KB this way.

**Ecosystem note:** a large share of crates.io compiles to
`wasm32-unknown-unknown` unchanged. Anything touching the filesystem, threads or
sockets does not, unless you target WASI.

---

## Zig

The size champion among languages people would actually use, and it has no
hidden runtime at all.

```zig
export fn step(dt: f32) f32 {
    return dt * 2.0;
}
```

```bash
zig build-lib src/main.zig -target wasm32-freestanding \
    -dynamic -O ReleaseSmall -rdynamic
```

`wasm32-freestanding` means no libc, no allocator you did not ask for, no
initialisation. What lands in the binary is what you wrote plus what you called.
Explicit allocators are a language-level feature, which fits wasm's model
unusually well.

The cost is a smaller ecosystem and no `wasm-bindgen` equivalent — you write the
boundary by hand. For a numeric kernel that is a few lines; for a
string-and-object-heavy API it is real work.

Zig is also an excellent C cross-compiler (`zig cc`), which makes it a
convenient way to build C to wasm without installing Emscripten.

---

## C and C++

Two quite different paths, and picking the wrong one costs you a megabyte.

**Bare clang** — no runtime, no libc, no assumptions:

```bash
clang --target=wasm32 -nostdlib -O3 \
      -Wl,--no-entry -Wl,--export-all -Wl,--allow-undefined \
      -o out.wasm in.c
```

Output is tiny. You have no `malloc`, no `printf`, no `memcpy` unless you write
them. Appropriate for a self-contained algorithm.

**Emscripten** — a POSIX emulation layer for the web:

```bash
emcc in.c -O3 -s EXPORTED_FUNCTIONS='["_step"]' \
     -s MODULARIZE=1 -o out.js
```

Emscripten gives you a filesystem, `SDL`, `OpenGL` mapped onto WebGL, pthreads
mapped onto Web Workers, and `main()` semantics. It is how FFmpeg, SQLite,
Blender, Doom and Photoshop reached the browser, and for porting an existing
codebase it is close to magic.

It is also why some wasm bundles are 5 MB. Emscripten's job is to make
`fopen("data.bin")` work in a browser, and the machinery for that is not free.
If your C does not need POSIX, do not use Emscripten.

---

## AssemblyScript

TypeScript-shaped syntax, compiled directly to wasm. Not TypeScript — a strict
subset with wasm's type system exposed.

```ts
export function step(dt: f32): f32 {
  return dt * 2.0;
}

export function sum(ptr: usize, n: i32): f32 {
  let acc: f32 = 0;
  for (let i = 0; i < n; i++) acc += load<f32>(ptr + i * 4);
  return acc;
}
```

Note `f32`, `usize`, and `load<f32>` — it is wasm's model with familiar syntax
over the top. Output is small, the compiler is fast, and the mental distance
from the machine stays short.

The trade is that it is **not** TypeScript: no `any`, no closures over mutable
captures in older versions, no union types, no npm ecosystem. Code that looks
like TS but rejects half of it is its own kind of friction.

Best fit: a JS/TS team that wants a numeric hot path in wasm without learning
Rust. It is a genuinely good on-ramp, and it is the closest thing to "write WAT
but pleasantly".

---

## Go and TinyGo

Standard Go ships its scheduler and garbage collector in the binary. The floor
is around 2 MB, and there is no flag that removes it — it is not bloat, it is the
language's runtime.

```bash
GOOS=js GOARCH=wasm go build -o main.wasm    # browser, needs wasm_exec.js
GOOS=wasip1 GOARCH=wasm go build -o main.wasm # WASI, Go 1.21+
```

**TinyGo** recompiles Go with a different runtime and a much smaller GC:

```bash
tinygo build -o main.wasm -target wasm ./main.go
```

30–300 KB, at the cost of a standard-library subset and no `reflect`-heavy
packages. For Go on the edge or in a plugin, TinyGo is the answer; for a
browser SPA, reconsider the premise.

---

## Managed languages and the GC proposal

Java, Kotlin, C#, Dart, Scala, OCaml and Python all have wasm stories, and until
recently they all involved compiling a garbage collector into the binary —
which is why early Blazor payloads were measured in megabytes.

The **GC proposal** ([chapter 14](14-post-mvp-features.md)) added struct and
array types managed by the *host's* collector. Kotlin/Wasm and Dart's `dart
compile wasm` target it directly, and output shrank by an order of magnitude.
This is the most consequential recent change in the ecosystem for these
languages, and it is shipped in Chrome, Firefox and Safari.

**Python** remains a special case. Pyodide is CPython compiled with Emscripten
plus a scientific stack: about 6 MB before you import anything. It is
extraordinary engineering and completely unsuitable as a way to make a web page
a bit faster. Use it when you need CPython semantics — notebooks, teaching,
running real scientific packages in a browser — and never as a performance play.

---

## So: hand-written WAT?

For learning, yes, and it is worth doing once. Writing an entity pool by hand
teaches you what `bots[i].x` compiles to in a way that reading about it does
not, and the engines in this repository exist for that reason.

For production, the honest list of cases:

- A kernel of a few hundred instructions where you want to control every one
- A build step that generates WAT programmatically
- Patching or instrumenting an existing binary
- A polyfill for a proposal an engine has not shipped

Everything else: use Rust, or Zig, or AssemblyScript. The cost of WAT is not the
writing — it is that there is no type checker above the machine level, no
refactoring tool, no test framework, and the memory layout lives in a comment
where nothing can verify it. `games/pixel-wave/game.wat` is 700 lines and about
as far as that approach comfortably goes.

---

## Choosing, in three questions

**Do you have existing code?** Port it with its native toolchain. Emscripten for
C/C++, `wasm32-unknown-unknown` for Rust. Do not rewrite.

**Is binary size a hard constraint?** (An edge function, a plugin, a widget on a
marketing page.) Zig, bare C, or AssemblyScript. Not Go, not Emscripten,
not Pyodide.

**Otherwise?** Rust. The tooling is the best in the ecosystem, `wasm-bindgen`
removes the part that is genuinely hard, and the output size is fine once you
have set `panic = "abort"`.

---

← [The toolchain](09-toolchain.md) · [Contents](README.md) · next: [Beyond the browser](11-beyond-the-browser.md)
