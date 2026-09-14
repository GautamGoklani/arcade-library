# Pixel Wave

A retro arcade wave shooter whose entire game engine — physics, enemy AI,
bullets, asteroids, collisions, level progression — is hand-written WebAssembly
Text in [`game.wat`](game.wat) and runs as a compiled `.wasm`. JavaScript
pre-renders pixel-art sprites, forwards input, draws what it reads out of wasm
linear memory, and plays synthesised sound off the engine's event counters.
Nothing else.

Desktop keyboard and mobile touch, detected automatically.

**[Play it](index.html)** · **[How it works](../../docs/15-game-loop-architecture.md)**

---

## Files

```
pixel-wave/
├── pixel-wave.js    ← the widget, engine embedded as base64   — REQUIRED
├── pixel-wave.css   ← scoped styles                            — REQUIRED
├── index.html       ← the standalone build (see the note below)
├── demo.html        ← minimal integration example
├── game.wat         ← engine SOURCE — edit this to change gameplay
├── game.wasm        ← compiled engine; also embedded in the .js
└── logo.svg         ← cover art, generated from the widget's own sprite grids
```

To put this in a page you need **two files**: `pixel-wave.js` and
`pixel-wave.css`.

---

## Integration

```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<link rel="stylesheet" href="pixel-wave.css">

<div id="game-container"></div>

<script src="pixel-wave.js"></script>
<script>
  const game = PixelWave.mount('#game-container');
</script>
```

The widget builds its own DOM — HUD, canvas, overlays, touch buttons — inside
your container, sizes itself to the container's width, and starts.

### API

```js
const game = PixelWave.mount(containerOrSelector, options?);

game.restart();    // fresh run
game.getState();   // { score, lives, level, enemiesAlive, gameOver }
game.destroy();    // stop the loop, remove DOM and every listener
```

| Option | Effect |
|---|---|
| `wasmUrl` | Load the engine from a `.wasm` URL instead of the embedded copy. Smaller JS, but the server must send `Content-Type: application/wasm` |
| `wasmBase64` | Supply your own base64 engine build |

Multiple instances on one page are independent — each `mount()` gets its own
wasm instance, and therefore its own memory and globals.

---

## Controls

| Action | Desktop | Mobile |
|---|---|---|
| Rotate | `A` / `D` or `←` / `→` | ◀ / ▶ |
| Thrust | `W` or `↑` | THRUST |
| Fire | `Space` — a **3-round burst** per press | FIRE |
| Restart | `R` | tap GAME OVER |
| Mute | `M` | the SOUND button |

Touch controls appear on coarse-pointer devices and support multi-touch.

---

## Rules

- Your fighter roams the **whole arena**; the swarm patrols the upper half, so
  climbing into it means taking the fight to them.
- Enemies wander and fire aimed shots only occasionally.
- Colliding with an enemy destroys both: **one life, no score**. Shoot, don't ram.
- Asteroids fall from the top. They damage **you** and not the swarm, and can be
  shot for score.
- **Levels 1–30:** each cleared wave adds one enemy — 2 at level 1, capped at 24.
  Enemy stats stay flat; the pressure is numbers.
- **Level 31+:** the count holds and the stat ramps start — faster movement,
  shorter cooldowns, more asteroids.
- **5 lives. Infinite levels.** Score = enemies + asteroids destroyed.

---

## Engine

~700 lines of hand-written WAT, 3.8 KB compiled, zero dependencies, zero runtime
network requests.

### Memory layout

| Region | Offset | Stride | Count | Fields |
|---|---|---|---|---|
| player | 0 | — | 1 | x, y, vx, vy, heading, alive |
| bots | 24 | 40 | 33 | x, y, vx, vy, heading, alive, cooldown, wanderTimer, targetX, targetY |
| bullets | 1344 | 24 | 160 | x, y, vx, vy, owner (0 = player), active |
| asteroids | 5184 | 24 | 20 | x, y, vx, vy, radius, active |
| score | 5664 | — | 1 | f32 |
| lives | 5668 | — | 1 | f32 |

5,672 bytes total — 8.7% of the single 64 KiB page the module declares. It never
grows.

**If you change this layout in `game.wat`, update the matching constants at the
top of `pixel-wave.js`.** Nothing links the two and nothing will fail to build.

### Exports

```
memory · init() · set_input(rot: f32, thrust: i32, fire: i32) · step(dt: f32)
get_score() · get_lives() · get_level() · is_game_over() · bots_alive_count()
get_shots() · get_enemy_shots() · get_kills() · get_rocks() · get_hurts() · get_waves()
```

The last six are **event counters**: integers that only ever go up, one per
kind of event, incremented at the line in `game.wat` where the event is
decided and zeroed by `init()`. The widget diffs them between frames to decide
what to play and when to flash.

Pixel Wave was the first title and the last to get them. Until then its widget
learned what had happened by watching state change — a bot's alive flag
dropping, the lives float going down — which could not tell a kill from a ram
(both clear the same flag) and which [chapter 15](../../docs/15-game-loop-architecture.md)
quoted as the crude version. Adding them changed nothing about the simulation:
over the same 32-second headless run, level, score, lives and a hash of the
ship's path were identical before and after, and the counters agreed with the
state they replaced — 37 kills and 3 asteroids for a score of 40, 5 hurts for
5 lives lost, 7 waves for level 8.

### Sound

This title shipped silent — sound was the first item on its own roadmap — and
for a long time was the only game in the library without any. It now has a
synthesiser in the same style as the other eight: no audio files, oscillators
and noise built on the fly, and an `AudioContext` created on the first sound,
which is always the player's own shot and therefore a user gesture.

What it needed was never really the synthesiser. It was the counters, because
a sound has to know *that* something happened. Enemy fire is rate-limited to
one blip every 110ms, since thirty-odd bots late on would otherwise be a wall
of oscillators nobody needs to hear individually.

`init()` takes no arguments — wave size is `1 + level` capped at 24, computed
inside the engine — the opposite of taking the count as a parameter, which
[chapter 6](../../docs/06-functions-tables.md) contrasts it with.

---

## Modifying it

**Visuals** — sprite grids and palettes near the top of `pixel-wave.js`. Sprites
are ASCII art: one character per pixel, `.` is transparent, every row in a sprite
must be the same length.

**Gameplay** — the globals at the top of `game.wat`:

| Constant | Meaning | Current |
|---|---|---|
| `$MAX_SPEED` | Player top speed | 270 |
| `$PLAYER_FIRE_CD` | Seconds between player shots | 0.14 |
| `$BOT_SPEED_BASE` | Enemy speed before the level-30 ramps | 50 |
| `$WORLD_W` / `$WORLD_H` | Arena size | 1200 × 750 |
| `$MID_Y` | Lower edge of the swarm's patrol | 375 |
| `$ROT_SPEED` | Turn rate, **radians/sec** | 2.5 |
| `$BURST_SIZE` / `$BURST_GAP` / `$BURST_RECOVER` | Burst fire | 3 / 0.09 s / 0.35 s |
| lives (in `$init`) | Starting lives | 5.0 |

Then rebuild from the repository root:

```bash
npm install
npm run build:pixel-wave    # game.wat → game.wasm, re-embedded into the .js
npm run check               # verify the binary matches its source
```

---

## Difficulty tuning, August 2026

Eased so a first-time visitor gets past the opening levels. Every changed
constant is commented in place in `game.wat` with its original value.

| | Was | Now |
|---|---|---|
| Turn rate `$ROT_SPEED` | 4.2 rad/s (241°/s) | **2.5** (143°/s) |
| Fire mode | hold to stream | **3-round burst per press** |
| Starting lives | 3 | **5** |
| Player fire cooldown | 0.2 | **0.14** |
| Enemy fire cooldown | 3.0–5.5 s | **4.2–7.0 s** |
| Enemy speed | base 60, ramp +8, cap 230 | **50 / +5 / 190** |
| Wave size | 3 + level, cap 33 | **1 + level, cap 24** |
| Asteroid interval | 3–5 s | **4.5–7 s** |
| Asteroid fall speed | 90–150 | **70–115** |

Measured with the same scripted pilot before and after: died at 32.2 s with
score 34 on level 6 → died at 76.8 s with score 104 on level 13. Still losable —
the aim was approachable, not trivial.

**`index.html` still embeds the original, harder engine.** The build script only
re-embeds `pixel-wave.js`, which makes the standalone build a working record of
the original balance. That is deliberate; leave it.

---

## Browser support

Any browser with WebAssembly — every evergreen browser, iOS Safari 11+, Android
Chrome. The engine is embedded in the JS, so there is no build step, no
dependency and no network request at runtime.
