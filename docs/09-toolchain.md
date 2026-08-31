# 09 · The toolchain

← [Globals and module state](08-globals-and-state.md) · [Contents](README.md) · next: [Source languages](10-source-languages.md)

---

## The two that matter

**WABT** — the WebAssembly Binary Toolkit. Reference-quality conversion between
`.wat` and `.wasm`, plus validation and inspection. This is what you want when
you are working *at* the wasm level.

**Binaryen** — a compiler and optimiser library that treats wasm as its IR. This
is what you want when you are producing wasm from something else, and where
`wasm-opt` comes from.

Everything else in the ecosystem is built on one of these two.

---

## WABT

```bash
# Node — what this repository uses. No native build required.
npm install wabt

# Or native binaries
brew install wabt
apt install wabt
```

| Tool | Does |
|---|---|
| `wat2wasm` | Assemble text → binary |
| `wasm2wat` | Disassemble binary → text |
| `wasm-validate` | Validate; exit code and a message |
| `wasm-objdump` | Section-by-section dump — the `objdump` analogue |
| `wasm-decompile` | Binary → a C-like pseudocode. Genuinely readable |
| `wasm-strip` | Remove custom sections (names, debug info) |
| `wasm-interp` | A reference interpreter. Slow, correct, scriptable |

```bash
wat2wasm game.wat -o game.wasm
wat2wasm game.wat --debug-names -o game.wasm    # keep $names for devtools
wasm2wat game.wasm -o roundtrip.wat
wasm-objdump -x game.wasm                       # headers and all sections
wasm-objdump -d game.wasm                       # disassembly
wasm-decompile game.wasm -o game.dcmp
```

`wasm-decompile` deserves the recommendation. Faced with an unfamiliar binary it
produces something much closer to readable code than a WAT dump:

```c
function step(a:float) {
  if (g_gameOver) return;
  update_player(a);
  update_bots(a);
  ...
}
```

### The JavaScript API

The build script here uses the npm package, which is the whole of WABT compiled
to — appropriately — WebAssembly:

```js
const wabt = await require('wabt')();
const mod = wabt.parseWat('game.wat', source);
mod.resolveNames();     // $names → indices
mod.validate();         // type-check; throws with a line number
const { buffer } = mod.toBinary({});
mod.destroy();          // it is wasm underneath; free it
```

**Call `resolveNames()` and `validate()`.** Skipping them will happily produce a
binary that fails at instantiation with a message far less useful than the one
the validator would have given you. `mod.destroy()` matters in a long-running
process — the module object holds wasm memory that is not garbage collected.

See [`scripts/build.mjs`](../scripts/build.mjs) for the version with error
handling.

---

## Binaryen and `wasm-opt`

```bash
npm install -g binaryen
# or: brew install binaryen
```

`wasm-opt` is the single highest-leverage tool in the ecosystem. Run it on
anything a compiler produced:

```bash
wasm-opt -O3 in.wasm -o out.wasm       # optimise for speed
wasm-opt -Oz in.wasm -o out.wasm       # optimise hard for size
wasm-opt -Os --strip-debug --strip-producers in.wasm -o out.wasm
```

On typical Rust or Emscripten output, `-Oz` removes 15–40% of the binary that
the source compiler left behind. On hand-written WAT it does much less — there
is no dead code and no redundant temporaries to find — which is a reasonable
sanity check on your own output. Running `-Oz` over `games/pixel-wave/game.wasm`
changes very little, and that is the expected result.

Other Binaryen tools worth knowing: `wasm-metadce` (tree-shaking driven by a
graph of what the host actually calls), `wasm-merge`, `wasm2js` (a fallback
compiler to JavaScript for environments without wasm), and `wasm-ctor-eval`
(runs your initialisers at build time and bakes the resulting memory into a data
segment — a real win for startup).

---

## Language toolchains, in one place

| Language | Toolchain | Notes |
|---|---|---|
| **Rust** | `rustup target add wasm32-unknown-unknown`, then `wasm-pack` or `cargo build --target` | The best-supported path. `wasm-bindgen` generates the JS glue |
| **C / C++** | Emscripten (`emcc`), or clang with `--target=wasm32` | Emscripten brings a POSIX emulation layer; bare clang gives you nothing and a tiny binary |
| **AssemblyScript** | `asc` | TypeScript-shaped syntax compiled straight to wasm. Small output, gentle learning curve |
| **Zig** | `zig build-lib -target wasm32-freestanding` | Excellent output size, no runtime, first-class wasm support |
| **Go** | `GOOS=js GOARCH=wasm go build` | Ships the runtime and GC — 2 MB floor. `GOOS=wasip1` for WASI |
| **TinyGo** | `tinygo build -target wasm` | Same language, ~100× smaller output, a subset of the standard library |
| **Swift, Kotlin, Dart, Java, C#** | SwiftWasm, Kotlin/Wasm, `dart compile wasm`, TeaVM, Blazor | Increasingly viable, mostly via the GC proposal |

[Chapter 10](10-source-languages.md) compares these on the axes that actually
decide the choice.

---

## Serving wasm correctly

Two headers and a MIME type. Getting them wrong accounts for a large share of
"WebAssembly doesn't work" reports.

```
Content-Type: application/wasm
```

Required for `instantiateStreaming`. Without it Chrome refuses outright.
Nginx: add `application/wasm wasm;` to `mime.types`. Express:
`express.static(dir, { setHeaders: (res, p) => p.endsWith('.wasm') && res.set('Content-Type', 'application/wasm') })`.

```
Content-Encoding: br      (or gzip)
```

wasm compresses extremely well — 60–70% is typical, because the opcode stream is
highly repetitive. Serve it compressed; it is the cheapest optimisation
available.

If you use **threads** (`SharedArrayBuffer`), you additionally need cross-origin
isolation:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

These have wide blast radius — they break embedded third-party iframes and
images without CORP headers. Budget for that before committing to threads.

Under a strict **Content-Security-Policy**, compiling wasm may require
`'wasm-unsafe-eval'` in `script-src`. The name is unfortunate; it does not
enable `eval`, it permits wasm compilation.

---

## Reading a disassembly

You will do this eventually — to check what a compiler emitted, or why a binary
is 400 KB.

```bash
wasm-objdump -x game.wasm
```

```
Sections:
     Type start=0x0000000a end=0x00000021 (size=0x00000017) count: 5
   Import start=0x00000023 end=0x0000004a (size=0x00000027) count: 2
 Function start=0x0000004c end=0x0000005f (size=0x00000013) count: 18
   Memory start=0x00000061 end=0x00000064 (size=0x00000003) count: 1
   Global start=0x00000066 end=0x000000f2 (size=0x0000008c) count: 43
   Export start=0x000000f4 end=0x00000152 (size=0x0000005e) count: 9
     Code start=0x00000154 end=0x00000a3c (size=0x000008e8) count: 18
```

Read it as a budget. If `Code` is small and the binary is large, something else
is the problem — usually a `Data` section full of string literals, or a `Custom`
section carrying debug info you meant to strip. `wasm-strip` handles the second;
the first is a source-language question.

---

## Testing wasm

There is no wasm test framework worth adopting, and you do not need one. The
practical approach is to drive the module from the host language you already
test in:

```js
import { test } from 'node:test';
import assert from 'node:assert';

const { instance } = await WebAssembly.instantiate(
  await readFile('game.wasm'),
  { env: { sinf: Math.sin, cosf: Math.cos } },
);
const { init, step, set_input, get_lives, memory } = instance.exports;
const mem = new Float32Array(memory.buffer);

test('player starts alive and centred', () => {
  init();
  assert.equal(mem[5], 1);            // player.alive
  assert.equal(get_lives(), 5);
});

test('burst fire yields exactly three rounds per press', () => {
  init();
  set_input(0, 0, 1);                 // hold fire
  for (let i = 0; i < 180; i++) step(1 / 60);   // three seconds
  assert.equal(countActiveBullets(mem, 0), 3);  // owner 0 = player
});
```

Because the engine is deterministic and takes `dt` as a parameter, you can run
three simulated seconds in microseconds and assert on exact state. That is a
much better testing position than most game code is in, and it is a direct
consequence of the host owning the clock ([chapter
15](15-game-loop-architecture.md)).

The burst-fire behaviour in these engines was verified exactly this way: holding
Space for 3 s yields 3 rounds, one one-frame tap yields 3, four presses yield
12, and mashing at 30 presses/second caps at 6.0 rounds/second.

---

## Editor support

- **VS Code** — "WebAssembly" (dtsvet) for syntax and `wat2wasm` on save; the
  "WebAssembly DWARF Debugging" extension for stepping through C/Rust source in
  Chrome devtools.
- **Chrome DevTools** — profiles wasm frames natively, shows the disassembly, and
  will step through original source given DWARF info. `--debug-names` at
  assembly time gets you readable function names in stack traces for free; do it.
- **`wat2wasm` online demo** (webassembly.github.io/wabt/demo/wat2wasm) — a live
  WAT editor with instant assembly and a JS scratchpad. The fastest way to try
  something.

---

← [Globals and module state](08-globals-and-state.md) · [Contents](README.md) · next: [Source languages](10-source-languages.md)
