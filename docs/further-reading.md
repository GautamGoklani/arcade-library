# Further reading

← [Contents](README.md)

Curated rather than exhaustive. Everything here is something I would actually
send someone.

---

## Specifications and canonical references

- **[WebAssembly Core Specification](https://webassembly.github.io/spec/core/)** —
  the actual document. Denser than you need for daily work, but the
  [instruction index](https://webassembly.github.io/spec/core/appendix/index-instructions.html)
  is the fastest way to settle "what exactly does this opcode do".
- **[MDN: WebAssembly](https://developer.mozilla.org/en-US/docs/WebAssembly)** —
  the practical reference for the JavaScript API. Start here for
  `instantiateStreaming`, `Memory`, `Table`, `Global`.
- **[MDN: Understanding the text format](https://developer.mozilla.org/en-US/docs/WebAssembly/Guides/Understanding_the_text_format)** —
  the best free WAT introduction after this course.
- **[webassembly.org/features](https://webassembly.org/features/)** — live
  proposal support matrix. Check before relying on anything post-MVP.
- **[WebAssembly proposals repo](https://github.com/WebAssembly/proposals)** —
  every proposal and its stage.

## Books

- **Rick Battagline, *The Art of WebAssembly*** (No Starch, 2021) — the only book
  that teaches hand-written WAT seriously. Closest in spirit to Part I here, and
  goes further on optimisation. If you want one book, this is it.
- **Brian Sletten, *WebAssembly: The Definitive Guide*** (O'Reilly, 2021) —
  broader and shallower: ecosystem, toolchains, non-browser hosts, history.
  Good complement.
- **Kevin Hoffman, *Programming WebAssembly with Rust*** (Pragmatic, 2019) —
  dated in specifics, still the clearest explanation of the Rust/wasm boundary
  and why `wasm-bindgen` exists.

## Papers

- **["Bringing the Web up to Speed with WebAssembly"](https://dl.acm.org/doi/10.1145/3062341.3062363)**
  (Haas et al., PLDI 2017) — the original design paper. Readable, and the best
  account of *why* the format looks like this.
- **["Everything Old is New Again: Binary Security of WebAssembly"](https://www.usenix.org/conference/usenixsecurity20/presentation/lehmann)**
  (Lehmann, Kinder, Pradel, USENIX Security 2020) — the honest treatment of what
  the sandbox does not protect. Background for
  [chapter 12](12-security-model.md); read it before you trust a wasm sandbox
  with untrusted C.
- **["An Empirical Study of Real-World WebAssembly Binaries"](https://dl.acm.org/doi/10.1145/3442381.3450138)**
  (Hilbig, Lehmann, Pradel, WWW 2021) — what is actually deployed on the web, as
  opposed to what the marketing suggests. A useful corrective.

## Tools

- **[WABT](https://github.com/WebAssembly/wabt)** — `wat2wasm`, `wasm2wat`,
  `wasm-objdump`, `wasm-decompile`. [Chapter 9](09-toolchain.md).
- **[Binaryen](https://github.com/WebAssembly/binaryen)** — `wasm-opt`. Run it on
  everything a compiler produced.
- **[wat2wasm online demo](https://webassembly.github.io/wabt/demo/wat2wasm/)** —
  live WAT editor with instant assembly and a JS scratchpad. The fastest way to
  try something.
- **[wasm-feature-detect](https://github.com/GoogleChromeLabs/wasm-feature-detect)** —
  runtime detection for every proposal, two lines.
- **[wasm-tools](https://github.com/bytecodealliance/wasm-tools)** — the
  Bytecode Alliance's Rust toolkit; the reference implementation for components.

## Toolchains

- **[wasm-pack](https://rustwasm.github.io/wasm-pack/)** and the
  **[Rust and WebAssembly book](https://rustwasm.github.io/docs/book/)** — the
  best-supported path, and the book's Game of Life tutorial is a genuinely good
  first project.
- **[Emscripten docs](https://emscripten.org/)** — for porting C/C++. The
  "Porting" and "Optimizing" sections are the ones to read.
- **[AssemblyScript](https://www.assemblyscript.org/)** — the gentlest on-ramp
  for a JS/TS developer.
- **[Zig's WebAssembly docs](https://ziglang.org/documentation/master/#WebAssembly)** —
  smallest sensible output, no hidden runtime.

## Non-browser

- **[Wasmtime](https://wasmtime.dev/)** — the reference standalone runtime.
- **[WASI](https://wasi.dev/)** and the
  **[wasi specs repo](https://github.com/WebAssembly/WASI)** — the system
  interface and its capability model.
- **[Component Model documentation](https://component-model.bytecodealliance.org/)** —
  the best introduction to WIT and composition.
- **[Extism](https://extism.org/)** — make your own application pluggable with
  wasm; host SDKs for a dozen languages.
- **[wazero](https://wazero.io/)** — pure-Go runtime, zero CGO.

## Game-specific

- **Glenn Fiedler, ["Fix Your Timestep!"](https://gafferongames.com/post/fix_your_timestep/)** —
  the canonical treatment of the fixed-vs-variable timestep question from
  [chapter 15](15-game-loop-architecture.md). Twenty minutes, worth it.
- **Robert Nystrom, *[Game Programming Patterns](https://gameprogrammingpatterns.com/)*** —
  free online. The Object Pool, Data Locality and Game Loop chapters are exactly
  the design space [chapter 16](16-entity-pools.md) operates in.
- **Craig Reynolds, ["Steering Behaviors For Autonomous Characters"](https://www.red3d.com/cwr/steer/)** —
  the 1999 paper that the closest-approach dodging in [chapter
  17](17-math-without-a-stdlib.md) descends from.
- **[Marsaglia, "Xorshift RNGs"](https://www.jstatsoft.org/article/view/v008i14)** —
  the original paper, including the shift triples.
- **[PCG](https://www.pcg-random.org/)** — if xorshift is not good enough. The
  site's comparison of PRNG families is the best short survey available.

## Talks

- **Lin Clark, ["A Cartoon Intro to WebAssembly"](https://hacks.mozilla.org/2017/02/a-cartoon-intro-to-webassembly/)** —
  a written series, not a talk, and still the clearest explanation of how the
  format compiles and why it is fast. Read it first if chapter 1 went too quickly.
- **Lin Clark, ["Standardizing WASI"](https://hacks.mozilla.org/2019/03/standardizing-wasi-a-webassembly-system-interface/)** —
  the same treatment for the capability model.
- **["WebAssembly: Building a New Kind of Cloud"](https://www.youtube.com/results?search_query=wasm+component+model+talk)** —
  search for recent Bytecode Alliance conference talks; the component-model story
  is moving fast enough that a specific link would be stale.

## Communities

- **[WebAssembly Discord](https://discord.gg/xMHKAyy)** and the
  **[Bytecode Alliance Zulip](https://bytecodealliance.zulipchat.com/)** — where
  the people building this actually are.
- **[r/WebAssembly](https://reddit.com/r/WebAssembly)** — low volume, decent
  signal.

---

## If you are starting today

1. Open the [wat2wasm demo](https://webassembly.github.io/wabt/demo/wat2wasm/)
   and write the `sum` module from [chapter 2](02-wat-syntax.md).
2. Read [Lin Clark's cartoon intro](https://hacks.mozilla.org/2017/02/a-cartoon-intro-to-webassembly/).
3. Work through the [Rust and WebAssembly book's](https://rustwasm.github.io/docs/book/)
   Game of Life. You will write no WAT and learn the boundary, which is the part
   that matters.
4. Come back to [chapter 5](05-linear-memory.md) and lay out a struct by hand.
   That is the moment the model clicks.

---

← [Contents](README.md)
