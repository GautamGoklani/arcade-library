# 07 · The JavaScript boundary

← [Functions and tables](06-functions-tables.md) · [Contents](README.md) · next: [Globals and module state](08-globals-and-state.md)

---

Most WebAssembly performance stories are boundary stories. A module that is
genuinely faster than the JavaScript it replaced, called once per pixel instead
of once per image, will lose. This chapter is about where the boundary is, what
crosses it, and what each crossing costs.

---

## Loading a module

Four APIs, and the differences matter:

```js
// Best: compiles while it downloads. Needs Content-Type: application/wasm.
const { instance } = await WebAssembly.instantiateStreaming(fetch('game.wasm'), imports);

// From bytes you already have.
const { instance } = await WebAssembly.instantiate(bytes, imports);

// Compile once, instantiate many times — each gets its own fresh memory.
const module = await WebAssembly.compile(bytes);
const a = await WebAssembly.instantiate(module, imports);
const b = await WebAssembly.instantiate(module, imports);

// Synchronous. Blocks the thread. Hard-limited to 4 KB on the main thread
// in Chrome; fine in a worker. Avoid.
const { instance } = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
```

`instantiateStreaming` is the one to reach for, and its most common failure is
mundane: a server sending `application/octet-stream`. Chrome then refuses with
`Incorrect response MIME type`. This is the reason
[`scripts/serve.mjs`](../scripts/serve.mjs) exists in this repository, and the
reason a `.wasm` fetched from `file://` never works.

A `WebAssembly.Module` is **structured-cloneable** — you can compile once and
`postMessage` the module to several workers, each of which instantiates it
cheaply with its own memory. Compiling in each worker instead is a common and
expensive mistake.

---

## Imports: what the module asks for

The import object is nested `{ module: { name: value } }`, matching the
two-level names in the `(import "env" "sinf" …)` declarations:

```js
const imports = {
  env: {
    sinf: Math.sin,
    cosf: Math.cos,
  },
};
```

Every declared import must be present and type-compatible, or instantiation
fails with a `LinkError`. This is the module's entire connection to the outside
world — no import, no capability. A module you did not give a `fetch` to cannot
make a network request, and there is no back door.

Four kinds can be imported: functions, memories, tables and globals. Importing a
memory instead of declaring one is how two modules share a heap, and how
Emscripten's dynamic linking works.

### The cost of an imported call

A JavaScript function called from wasm has to leave the wasm frame, enter the JS
frame, and come back. Engines have optimised this hard — modern V8 can inline a
small JS import into wasm code in some cases — but it is not free, and it is a
JIT-dependent optimisation, so it is not *predictable* either.

Most engines here import `Math.sin` and `Math.cos` and call them a few dozen times
per frame. At 60 fps that is a few thousand crossings per second, which is
nothing. Calling them per *bullet* per frame — tens of thousands — would start to
show up. Calling them inside a per-pixel loop would dominate the profile
entirely.

**The rule: batch at the boundary.** One call that processes 100,000 items beats
100,000 calls.

---

## Exports: what the host may touch

```js
const { init, step, set_input, get_score, memory } = instance.exports;
```

Functions come across as ordinary JavaScript functions. Numbers convert
automatically:

| wasm | JavaScript |
|---|---|
| `i32` | `number` (converted with the `ToInt32` rules — `2**31` arrives as `-2147483648`) |
| `f32` | `number`, widened to double; some precision was already lost at the f32 store |
| `f64` | `number`, exact |
| `i64` | **`BigInt`** — and passing a plain `number` throws a `TypeError` |

The `i64` boundary is a real annoyance. `BigInt` allocates and is slow. If you
have a 64-bit value crossing per frame, the usual fix is to split it into two
`i32`s or write it into memory instead.

---

## Reading memory from JavaScript

This is the important part, and it is simpler than it sounds: `memory.buffer`
is an `ArrayBuffer`, and you put typed-array views over it.

```js
const f32 = new Float32Array(memory.buffer);
const i32 = new Int32Array(memory.buffer);
const u8  = new Uint8Array(memory.buffer);
```

**Views are indexed in elements, not bytes.** A byte address of 1344 is
`f32[336]`. Getting this wrong gives you plausible-looking garbage, which is
worse than a crash.

```js
const BOTS_OFF = 24, BOT_STRIDE = 40;

function readBot(i) {
  const b = (BOTS_OFF + i * BOT_STRIDE) >> 2;   // byte address → f32 index
  return { x: f32[b], y: f32[b + 1], heading: f32[b + 4], alive: f32[b + 5] };
}
```

`>> 2` is the idiom for "divide by four", and it is exactly the mirror of the
`$bot_addr` helper on the wasm side.

The `+ 4` and `+ 5` are written out here so the view arithmetic is visible. The
widgets in this repository name them instead — `f32[b + FIELD.bot.alive]` — so
that a build check can notice when a field moves;
[chapter 16](16-entity-pools.md) explains why that check has to exist.

Reading this way is **free** — no copy, no marshalling, just an indexed read
into the same bytes the engine wrote. This is why the renderers in this
repository read entity state directly instead of calling a getter per field.
Per frame Pixel Wave reads 33 bots × 6 fields, 160 bullets × 6, 20 asteroids × 6
— about 1,300 array reads, which a JIT compiles to indexed loads and which cost
nothing measurable.

### Two ways to get it wrong

**Detached views.** If the module calls `memory.grow`, the `ArrayBuffer` may be
replaced and every existing view becomes detached — `byteLength === 0`, reads
return `undefined`. Anything that could grow means re-creating the views:

```js
let f32 = new Float32Array(memory.buffer);
function refresh() {
  if (f32.buffer !== memory.buffer || f32.byteLength === 0) {
    f32 = new Float32Array(memory.buffer);
  }
}
```

Every engine here declares one page and never grows, so this problem does not exist
here. That is a design choice with a real payoff — the view is created once at
mount and held for the lifetime of the instance.

**Duplicated offsets.** The `BOTS_OFF = 24, BOT_STRIDE = 40` constants above are
a **copy** of numbers that live in `game.wat`, and nothing links them. Change the
layout, forget the renderer, and you get a game that draws enemies at nonsense
positions and does not fail to build.

Three mitigations, in increasing order of effort:

1. Write the layout comment in the `.wat` and refer to it from the JS. (What
   these engines do.)
2. Export the offsets as wasm globals and read them at startup — the layout then
   has exactly one source of truth.
3. Generate both from one description. Worth it above a handful of structs.

Option 2 is nearly free and underused:

```wat
(global (export "BOTS_OFF")   i32 (i32.const 24))
(global (export "BOT_STRIDE") i32 (i32.const 40))
```

```js
const BOTS_OFF = instance.exports.BOTS_OFF.value;
```

---

## Strings

There is no string type. A string crossing the boundary is bytes in linear
memory plus a length, encoded and decoded by hand:

```js
function writeString(str, ptr) {
  const bytes = new TextEncoder().encode(str);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return bytes.length;
}

function readString(ptr, len) {
  return new TextDecoder('utf-8').decode(new Uint8Array(memory.buffer, ptr, len));
}
```

Note that `readString` copies. `TextDecoder` on a subarray of wasm memory is
fast, but it is still O(n) — string-heavy interop is the single most common
reason a wasm port ends up slower than the JavaScript it replaced.

Where does `ptr` come from? Either a fixed scratch address you agreed on, or an
allocator export from the module. This is exactly the plumbing that
`wasm-bindgen` generates for you, and seeing it written out is a good argument
for using it.

No engine here has a single string. All communication is numbers, which is
why the boundary code in `pixel-wave.js` is about thirty lines.

---

## The complete pattern, as these engines use it

```js
// 1. Instantiate with the host functions the module demands.
const { instance } = await WebAssembly.instantiate(bytes, {
  env: { sinf: Math.sin, cosf: Math.cos },
});
const { init, set_input, step, get_score, get_lives, is_game_over, memory } =
  instance.exports;

// 2. One typed-array view over linear memory, created once.
const mem = new Float32Array(memory.buffer);

// 3. Start the world.
init();

// 4. Per frame: push input, advance, read out, draw.
function frame(now) {
  const dt = Math.min((now - last) / 1000, 0.05);   // clamp — see ch. 15
  last = now;

  set_input(rotDir, thrustOn, firing);              // 3 numbers in
  step(dt);                                         // 1 call, all the work

  drawPlayer(mem[0], mem[1], mem[4]);               // x, y, heading
  for (let i = 0; i < MAX_BOTS; i++) {
    const b = (BOTS_OFF + i * BOT_STRIDE) >> 2;
    if (mem[b + 5]) drawBot(mem[b], mem[b + 1], mem[b + 4]);
  }
  hud(get_score(), get_lives());

  if (!is_game_over()) requestAnimationFrame(frame);
}
```

**Four crossings per frame** — `set_input`, `step`, `get_score`, `get_lives` —
plus two imported `Math` calls per entity that turns. Everything else is
indexed reads into a `Float32Array`. That ratio is the whole design: the
boundary carries commands and scalars, never the world.

---

## What actually costs what

Rough, and worth re-measuring on your own workload, but the ordering is stable:

| Operation | Cost |
|---|---|
| wasm → wasm call | ~free, often inlined |
| Typed-array read of wasm memory from JS | ~free, an indexed load |
| JS → wasm call with number args | tens of nanoseconds |
| wasm → JS imported call | tens of nanoseconds, JIT-dependent |
| Anything with `BigInt` (`i64`) | allocates — avoid per-frame |
| String encode/decode | O(length), allocates |
| Passing an object or array | not possible; it is always a serialise |
| `memory.grow` | may reallocate and copy the entire memory |

The design conclusion is always the same: **make the boundary wide and rare, not
narrow and frequent.**

---

## The two integration shapes

Worth naming, because the choice recurs and this repository contains one of
each.

**A bare engine.** Ship the `.wasm`; the host writes a renderer. Maximum
flexibility — the host can render however it likes, and can set policy the
engine declined to own, such as a wave curve ([chapter
6](06-functions-tables.md)) — at the cost of duplicating the memory layout into
the host's code, with nothing to keep the two in step. This repository shipped a
title in that shape once and no longer does; the drift is a real tax, and every
title here now carries its own renderer.

**A self-contained widget.** Ship a `.js` with the engine embedded as base64 and
a `mount()` API. Every game here works this way. Pixel Wave, for instance:

```js
const game = PixelWave.mount('#container');
game.restart();
game.getState();     // { score, lives, level, enemiesAlive, gameOver, paused }
game.destroy();
```

No offsets escape the package, integration is two files and one line, and
updating means dropping in a new build. The cost is a bigger JS file — base64 is
33% overhead on top of the binary — and a host that cannot render it its own way.

Prefer the widget when a title offers one. Nothing outside the package needs to
know the memory layout, so the entire class of drift described above cannot
happen.

---

← [Functions and tables](06-functions-tables.md) · [Contents](README.md) · next: [Globals and module state](08-globals-and-state.md)
