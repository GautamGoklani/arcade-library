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
game.getState();   // { score, lives, level, enemiesAlive, gameOver, paused, difficulty }
game.destroy();    // stop the loop, remove DOM and every listener
```

| Option | Effect |
|---|---|
| `wasmUrl` | Load the engine from a `.wasm` URL instead of the embedded copy. Smaller JS, but the server must send `Content-Type: application/wasm` |
| `wasmBase64` | Supply your own base64 engine build |
| `difficulty` | `'easy'`, `'normal'` (the default) or `'hard'` for the first run; the HUD button changes it after that |

Multiple instances on one page are independent — each `mount()` gets its own
wasm instance, and therefore its own memory and globals.

---

## Controls

| Action | Desktop | Mobile |
|---|---|---|
| Rotate | `A` / `D` or `←` / `→` | ◀ / ▶ |
| Thrust | `W` or `↑` | THRUST |
| Fire | `Space` — a **3-round burst** per press | FIRE |
| Pause | `P` or `Esc`; leaving the tab pauses too | the PAUSE button; tap the arena to resume |
| Restart | `R` | tap GAME OVER |
| Mute | `M` | the SOUND button |
| Difficulty | the EASY / NORMAL / HARD button; changing it starts a fresh run | the same button |

Touch controls appear on coarse-pointer devices and support multi-touch.

**Gamepad**, standard mapping, no setup — plug one in and it works:

| Action | Button |
|---|---|
| Steer | left stick (point and aim, as on touch) or the d-pad |
| Thrust | `A`, right trigger, or d-pad up |
| Fire | `X`, left trigger, or `B` |
| Pause | `Start` |
| Restart | `Back` or `Y` |
| Mute | either shoulder button |

Thrust and fire each have a face button *and* a trigger, so a pad with worn
triggers still plays. The pad is polled once a frame rather than listened for,
because `getGamepads()` only refreshes its snapshots when it is called. A finger
on the touch stick takes priority over the pad's stick, so a controller resting
inside its deadzone cannot fight one.

Pause is entirely the widget's. The engine has no clock of its own and advances
by whatever `dt` it is handed, so pausing means the loop stops calling `step`
and stops its animation clock, and goes on drawing the frozen memory. There is
no pause code in `game.wat`, and the `.wasm` did not change when pause arrived.
[Chapter 15](../../docs/15-game-loop-architecture.md) makes the case for keeping
it that way.

---

## Rules

- Your fighter roams the **whole arena**; the swarm patrols the upper half, so
  climbing into it means taking the fight to them.
- Enemies wander and fire aimed shots only occasionally, in three roles.
  **Crabs** are the baseline. **Hornets** fly half again as fast, change course
  more often and fire less. **Skulls** fly slowly and aim where you are going,
  so flying in a straight line is how they hit you. See
  [Enemy species](#enemy-species-september-2026).
- Colliding with an enemy destroys both: **one life, no score**. Shoot, don't ram.
- Asteroids fall from the top. They damage **you** and not the swarm, and can be
  shot for score.
- **Power-ups.** About one enemy in seven drops a capsule when you shoot it
  down. It drifts toward your half of the arena and fades after nine seconds;
  fly into it to take it. **R** (yellow) is rapid fire, the three-prong fan
  (cyan) is a spread shot, the shield (blue) takes your next hit, and the heart
  (red) gives back a life — never more than you started with. Effects in force
  show as coloured squares beside LIVES and blink before they run out. See
  [Power-ups](#power-ups-september-2026).
- **Every tenth level is a boss** instead of a wave: one ship in five parts
  across the top of the arena. Shoot off the two wings and two guns in any
  order; the core in the middle is plated, and a round that hits it before
  they are gone just ticks off. Before every attack the parts about to fire
  **flash white** — guns throw a fan straight down, wings an aimed volley, the
  bare core a ring — so move when you see it. Flying into the boss costs a life
  and throws you clear. See [Boss waves](#boss-waves-september-2026).
- **Levels 1–30:** each cleared wave adds one enemy — on Normal, 2 at level 1,
  capped at 24. Enemy stats stay flat; the pressure is numbers.
- **Level 31+:** the count holds and the stat ramps start — faster movement,
  shorter cooldowns, more asteroids.
- **5 lives on Normal** (7 on Easy, 3 on Hard). **Infinite levels.** Score =
  enemies + asteroids destroyed. See [Difficulty](#difficulty-september-2026)
  for what else each setting changes.

---

## Engine

~1,490 lines of hand-written WAT, 7.6 KB compiled, zero dependencies, zero
runtime network requests.

### Memory layout

| Region | Offset | Stride | Count | Fields |
|---|---|---|---|---|
| player | 0 | — | 1 | x, y, vx, vy, heading, alive |
| bots | 24 | 40 | 33 | x, y, vx, vy, heading, alive, cooldown, wanderTimer, targetX, targetY |
| bullets | 1344 | 24 | 160 | x, y, vx, vy, owner (0 = player), active |
| asteroids | 5184 | 24 | 20 | x, y, vx, vy, radius, active |
| pickups | 5664 | 24 | 8 | x, y, vy, kind (0 rapid, 1 spread, 2 shield, 3 life), life, active |
| boss | 5856 | — | 1 | x, y, vx, state (0 idle, 1 winding up), timer, pattern (0 fan, 1 aimed, 2 ring), active, number |
| parts | 5888 | 28 | 5 | dx, dy, hp, maxHp, alive, flash, windup — 0 core, 1-2 wings, 3-4 guns |
| score | 6028 | — | 1 | f32 |
| lives | 6032 | — | 1 | f32 |

6,036 bytes total — 9.2% of the single 64 KiB page the module declares. It never
grows. Score and lives sat at 5664 and 5668 until power-ups arrived, then at 5856
and 5860 until boss waves did; each time the new region went in with the others
and the two scalars moved up past it, which is the rule
[chapter 5](../../docs/05-linear-memory.md) teaches from this map.

**If you change this layout in `game.wat`, update the matching constants and
the `FIELD` table at the top of `pixel-wave.js`.** Nothing links the two at
build time, but `npm run check` fails if an offset, a stride, or the position of
a field inside a record disagrees.

### Exports

```
memory · init() · set_input(rot: f32, thrust: i32, fire: i32) · step(dt: f32)
get_score() · get_lives() · get_level() · is_game_over() · bots_alive_count()
get_shots() · get_enemy_shots() · get_kills() · get_rocks() · get_hurts() · get_waves()
get_drops() · get_grabs() · get_blocks()
get_bosses() · get_warns() · get_clinks() · get_boss_parts() · get_boss_downs()
get_rapid_t() · get_spread_t() · get_shield_t()
set_difficulty(d: i32) · get_difficulty()
```

`get_shots` through `get_boss_downs` are **event counters**: integers that only ever go up, one per
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

Good news goes up. A cleared wave is a rising three-note figure, and a pickup
is the only other good news, so it gets two rising notes — never mistaken for
the wave. A shield taking a hit is a hard, high knock where a lost life is a low
one: it has to be heard as *that would have hurt*.

The boss adds the only low, slow sound in the game for its arrival; a rising
buzz on every wind-up, so the ear hears an attack coming the way the eye sees the
parts flash; and a dry tick for a round on the plated core, which is the only
way the game says *that shot was wasted*.

`init()` takes no arguments — wave size is `1 + level` capped at 24, computed
inside the engine — the opposite of taking the count as a parameter, which
[chapter 6](../../docs/06-functions-tables.md) contrasts it with.

---

### Drawn at 400×250

This title was retrofitted with the library's retro render treatment in
September 2026. It draws into a **400×250 buffer blown up 3× with smoothing off**,
with scanlines and a vignette in CSS (`.ss-scan`, dropped under
`prefers-reduced-motion`) and screen shake that moves in whole low-res pixels.
The CRT overlay used to be painted onto the canvas every frame; it is CSS now,
because one-pixel scanlines drawn into the buffer would have become three-pixel
bars. Rotated sprites — the ship, its bolts, the asteroids — now rotate at the
low resolution, so they alias the way a machine of the period would have.

The draw code was written at full resolution, so the snap to whole low-res
pixels lives in the adapter rather than at each call: the buffer's `fillRect`
and `drawImage` are wrapped to round their edges, and a one-pixel detail that
would round away keeps one low-res pixel. The engine did not change.

## Modifying it

**Visuals** — sprite grids and palettes near the top of `pixel-wave.js`. Sprites
are ASCII art: one character per pixel, `.` is transparent, every row in a sprite
must be the same length.

**Gameplay** — the globals at the top of `game.wat`:

| Constant | Meaning | Current |
|---|---|---|
| `$MAX_SPEED` | Player top speed | 270 |
| `$PLAYER_FIRE_CD` | Seconds between player shots | 0.14 |
| `$apply_difficulty` | Everything that differs by setting: lives, enemy speed and fire, wave size, asteroids | see [Difficulty](#difficulty-september-2026) |
| `$WORLD_W` / `$WORLD_H` | Arena size | 1200 × 750 |
| `$MID_Y` | Lower edge of the swarm's patrol | 375 |
| `$ROT_SPEED` | Turn rate, **radians/sec** | 2.5 |
| `$BURST_SIZE` / `$BURST_GAP` / `$BURST_RECOVER` | Burst fire | 3 / 0.09 s / 0.35 s |

Then rebuild from the repository root:

```bash
npm install
npm run build:pixel-wave    # game.wat → game.wasm, re-embedded into the .js
npm run check               # verify the binary matches its source
```

---

## Difficulty, September 2026

Three settings, picked with the HUD button or `mount(el, { difficulty: 'hard' })`.
The table lives in the engine: `set_difficulty(d)` records the choice (0 easy,
1 normal, 2 hard) and `init()` applies it, so a setting never changes halfway
through a run. The widget only remembers which setting was asked for, and
changing it starts a fresh run.

| | Easy | Normal | Hard |
|---|---|---|---|
| Starting lives | 7 | 5 | 3 |
| A wave's first shot | 4.0–7.0 s | 1.5–4.0 s | 1.5–4.0 s |
| Enemy fire cooldown | 5.5–9.0 s | 4.2–7.0 s | 3.0–5.5 s |
| Enemy bullet speed | 200 | 280 | 280 |
| Enemy speed: base / per level after 30 / cap | 42 / 4 / 160 | 50 / 5 / 190 | 60 / 8 / 230 |
| Wave size | 1 + level, cap 20 | 1 + level, cap 24 | 3 + level, cap 33 |
| Asteroid gap | 5.5–8.5 s | 4.5–7.0 s | 3.0–5.0 s |
| Asteroid fall, per level after 30 | 60–100, +3 | 70–115, +4 | 90–150, +6 |
| Boss wind-up (see [Boss waves](#boss-waves-september-2026)) | 1.4 s | 1.0 s | 0.7 s |

**Normal is the August balance.** When difficulty arrived, identical input
replayed through the previous engine and the new one gave byte-identical linear
memory on every frame, through level 40. The enemy species broke that replay on
purpose, and were balanced so the curve stayed where it was instead.

**Hard is the balance from before the August easing** (the *Was* column below),
with today's controls. The 241°/s turn rate and hold-to-stream fire were
unplayable rather than hard, so no setting brings them back.

**Easy was tuned by measurement, and the first version did nothing useful.** It
only lengthened the enemy fire cooldowns, and benches at 5.5–9 s and at 7–11 s
came out identical to the last death. A bot's *first* shot is timed when its wave
spawns, and a player who clears a wave in a few seconds rarely lets any bot fire
twice. So before level 30, most of the fire anyone faces is each wave's opening
volley, which the cooldowns never touched. Delaying that volley is what moved
the numbers:

(16 runs each, measured before the enemy species existed.)

| Easy's first shot | Bad pilot's median run | Median level |
|---|---|---|
| 1.5–4.0 s (Normal's) | 25 s | 7 |
| 3.0–6.0 s | 38 s | 9 |
| **4.0–7.0 s** | **49 s** | **10** |

Slower enemy bullets barely registered: 4.0–7.0 s with bullets at 280 also
lasted 49 s, because the bench pilot never dodges. Easy keeps 200 for the players
who do.

The settings as shipped, 64 runs each with a pilot that aims loosely at the
nearest enemy, fires on a fixed rhythm and never dodges:

| | Survived: worst / median / best | Median level | Runs reaching level 3 |
|---|---|---|---|
| Easy | 35 / 55 / 78 s | 11 | 64 of 64 |
| Normal | 12 / 19 / 32 s | 5 | 64 of 64 |
| Hard | 5 / 13 / 26 s | 3 | 48 of 64 |

Easy's worst run outlasts Normal's best, and no run on any setting reached the
10-minute cap: easier, still losable.

What kills changes with the setting. On Normal, enemy fire took 265 of 320 lives
and ramming 41. On Easy, where fire is thin and runs run long, ramming is the
single largest cause — 147 of 448 — because a pilot who flies at the swarm and
never dodges eventually flies into a hornet.

**Best scores are kept per setting.** The page shell records Normal under the
same key as before, so a best set before difficulty existed is still Normal's,
and the hub card keeps showing it. Easy and Hard get `pixel-wave:easy` and
`pixel-wave:hard`.

---

## Boss waves, September 2026

The plan's description, built as written: *every 10 levels, a large multi-part
enemy with destructible sections and telegraphed attack patterns.*

| Part | Hit points (first boss, +2 / +4 each boss) | Fires | Score |
|---|---|---|---|
| Wings (2) | 4 | an **aimed volley**: three rounds at the ship, 0.12 rad apart | 5 |
| Guns (2) | 4 | a **fan**: five rounds straight down, 0.25 rad apart | 5 |
| Core | 8, and plated until all four sections are gone | once bare, a **ring** of twelve, alternating with an aimed volley of its own | 20 |

The boss patrols side to side at the top of the arena, quicker each time. It
idles for 2.6 s, then **winds up** — the parts about to fire flash white for the
setting's wind-up time (1.4 / 1.0 / 0.7 s) — then fires. Guns and wings take
turns, a pair that has been shot off is skipped, and a bare core alternates its
ring with an aimed volley. Of each pair, only the one nearer the ship fires.
Flying into it costs a life, like any ram, and throws the ship clear below it,
because the boss survives the collision and a ten-frame overlap would otherwise
bill ten lives.

**None of it is random.** The rotation is fixed and draws nothing from `$rng`,
which is what makes the wind-up a telegraph rather than a warning: the player
can learn what comes next as well as see it coming. It is also why **levels 1-9
replay the previous engine exactly** — old and new, same seed, same input,
compared byte for byte up to level 10 over 24 seeds × 3 settings, 116,945 frames.

The engine marks which parts are winding up (`windup` on each part) and the
widget flashes exactly those. It could have worked them out from `pattern`, but
which part owns which attack is a rule, and a rule copied into the renderer is
one that quietly disagrees with the engine the day the rotation changes.

### Benching it, and two things the bench got wrong first

A boss level is reached by few of the pilots the rest of this README uses, so
the fight was benched from engine builds that start at level 10. Two mistakes in
the bench are worth recording, because both produced confident numbers.

**The pilot flew into the boss.** The README's pilot thrusts toward its target
until it is 320 px away, then coasts. Against a wave spread across the arena that
is fine; against one enemy at the top, with this little drag, the ship sailed
straight up past it and was shot at point-blank or rammed. The fight pilots
refuse to close faster than 80 px/s and back off inside 220 px — flying, not
dodging.

**Sixty-four runs were one run.** A boss level has no wave, so its only
randomness is the asteroids, and a fixed pilot against a deterministic boss
plays the same fight every time: every one of 64 "runs" rammed at exactly 10.12 s
from the same position. The fight pilots draw their own stand-off distance, aim
error, fire rhythm and start delay per run, so 64 runs are 64 players.

### Two things the bench changed about the boss

**One gun and one wing, not both.** As drafted, every attack came from both of
its pair. Both wings' centre rounds were aimed at the same point, so a ship that
was not moving took two hits from one volley; and the two guns' fans, 96 px
apart, interleaved into a round every ~45 px against a lethal width of 36 — a
wall, where a fan should have gaps you can read and sit in. From the nearer part
only, one telegraphed attack costs at most about one life.

**Attack rate and hit points are one budget.** An aimed volley aims where the
ship is, with no lead, so a pilot that never dodges is hit by every one, and its
losses are simply the fight's length over the volley period. The draft — 1.6 s
between attacks, 6-hp sections, a 12-hp core — beat half of 64 such pilots on
Easy and 15 of 64 on Normal, from full lives.

### The fight as shipped

Two pilots, identical except in one respect. **Still** never dodges. **Reader**
does exactly one thing differently: when the boss winds up an aimed volley, it
turns side-on and gets moving, so it is somewhere else when the rounds arrive.
64 varied runs each, from full lives:

| First boss | Easy | Normal | Hard |
|---|---|---|---|
| Still: wins | 52 / 64 | 34 / 64 | 8 / 64 |
| Reader: wins | 55 / 64 | **50 / 64** | **35 / 64** |
| Lives lost, median (still → reader) | 3 → 2 | **4 → 1** | 3 → 2 |

**That gap is the telegraph.** The reader's only advantage is acting on the
wind-up, and on Normal it takes the median cost of the fight from four lives to
one; on Hard it takes the win rate from one in eight to more than half. The
second boss, two hit points a section tougher and faster, takes those win
counts down by 13-29% depending on setting and pilot — harder, not a wall.

**What the bench does not cover.** A still pilot sometimes fires at the plated
core forever — it aims at the nearest part, and learns nothing from the tick —
and those runs time out (5 of 64 on Easy). A person learns from the tick in a
shot or two. And no pilot here dodges the way a player does, reading the fan's
gaps or the ring's spokes; the reader only answers the aimed volley. Every pilot
also arrives with full lives, where a real one arrives with what the first nine
levels left it.

---

## Power-ups, September 2026

The original plan's four, as a new entity pool in the engine: a bot shot down
drops a capsule with probability `$DROP_CHANCE`, and flying into it applies it.

| Kind | Share of drops | Effect |
|---|---|---|
| **Rapid fire** | 35% | a burst recovers in 0.12 s instead of 0.35, for 8 s |
| **Spread** | 30% | every round leaves the gun as three, 0.2 rad apart, for 8 s |
| **Shield** | 25% | the next hit of any kind — a shot, an asteroid, a ram — costs nothing; lasts 12 s if unused |
| **Life** | 10% | one life back, never past the setting's starting count |

Taking a kind already in force restarts its clock rather than stacking it:
eight seconds is the effect, not a bank. A life is capped at the starting count
because it is a repair, not a way to build a cushion — which is also why it is
the rarest: it is the only kind that outlasts its moment. A spread volley is
still one entry on `get_shots`, because that counter means *a round left the
gun* and the widget plays one sound for it, not three.

### Drops have their own random stream

Everything else in the engine draws from `$rng`, in an order the simulation
fixes. If a drop roll came out of the same stream, every kill would shift every
wander target and asteroid after it, and a run where the player never touched a
pickup would still be a different run. So drops draw from **`$dropRng`**, the
same xorshift on its own state.

That is what makes the change checkable. Old and new engine, compiled with the
same seed and driven with the same input, were compared until the first pickup
was collected — after that they are *meant* to differ. Over **24 seeds × 3
settings, 116,939 frames** — 63 of the 72 games played to the end with no grab,
110 drops rolled — the first 5,664 bytes of memory (everything that existed
before) and all eleven old readers were identical on every frame. A player who
ignores the capsules is playing the same game as before, on every setting, which
is why the difficulty table did not need re-tuning.

### Tuning the drop rate

The bench's pilot is written to the description [Difficulty](#difficulty-september-2026)
gives — aims loosely at the nearest enemy, fires on a fixed rhythm, never dodges
— with one change for this: it detours into any capsule on the board. The pilot
that produced the Difficulty table is not in the repository, and this one is
not it: its baseline on Normal is 25 s where that one's was 19. Every comparison
below is this pilot against itself. 64 runs per setting, median survival:

| Drop chance | Normal: grabs a game | Normal (25 s without) | Easy (51 s without) | Hard (11 s without) |
|---|---|---|---|---|
| 8% | 0.6 | 26 s | 55 s | 13 s |
| **14%** | **1.4** | **29 s** | **67 s** | **15 s** |
| 20% | 2.7 | 37 s | 77 s | 16 s |

At 8% half of all Normal games showed no capsule at all, so the feature was
invisible to the player it is for. At 20% chasing them lengthened a Normal run
by half — the size of the step between two settings, not a reward within one.
**14%** is about one kill in seven: a Normal game sees one or two, chasing them
is worth about 14%, and every setting *with* pickups still ends well short of
the easier setting without them.

The shipped rate, worst / median / best over 64 runs:

| | Before | Ignores capsules | Detours for them | Reaches level 3 (before → detours) |
|---|---|---|---|---|
| Easy | 30 / 51 / 83 s | 31 / 50 / 91 s | 26 / **67** / 142 s | 61 → 64 of 64 |
| Normal | 12 / 25 / 47 s | 11 / 24 / 49 s | 12 / **29** / 63 s | 59 → 52 of 64 |
| Hard | 4 / 11 / 31 s | 5 / 11 / 23 s | 4 / **15** / 51 s | 11 → 24 of 64 |

Two things in that table are worth reading twice. **The pilot that ignores them
is the old game**, within the noise of different runs — which the replay above
already said exactly. And **detouring is not free**: on Normal the chasing pilot
lives longer but fewer of its runs reach level 3 (59 → 52), because a detour is
time not spent shooting, and a capsule dropped near the swarm is flown into the
swarm to fetch. That is the trade the feature should be.

**What the bench does not cover: rapid fire.** This pilot's aim, not its rate
of fire, is what limits it — firing four times as often left its survival
where it was (51 / 25 / 11-12 s either way) — so rapid fire is worth nothing
to it. Rapid fire pays a player who can already aim, which is the right way
round, and no pilot here measures how much.

---

## Enemy species, September 2026

Pool slot `i` holds species `i % 3`: 0 crab, 1 hornet, 2 skull. The renderer has
always picked sprites that way; now the engine decides behaviour off the same
arithmetic, so there is no species field to store or keep in sync.

| | Crab | Hornet | Skull |
|---|---|---|---|
| Speed | the difficulty table's | ×1.5 | ×0.7 |
| Re-picks a target every | 1.2–3.2 s | 0.5–1.4 s | 1.2–3.2 s |
| Waits between shots | the table's | ×1.5 | the table's |
| Aims at | where you are | where you are | where you will be |

A skull leads its shot: time of flight to your current position, times your
velocity, capped at 1.5 seconds. That is one step of the intercept rather than
the exact quadratic, which is enough for the job it has.

**The lead does what it is for.** Measured on Hard with pilots that never shoot,
64 runs each, changing only the lead cap so crabs stay a control:

| Pilot | No lead | 1.5 s (shipped) | 3.0 s |
|---|---|---|---|
| Flies in straight lines | 5.4% | **10.0%** | 7.6% |
| Reverses every 2 s | 11.1% | 9.3% | 9.8% |

Hit rate is lives taken per shot fired. The lead nearly doubles a skull's hits
on a straight-line flier and buys nothing against one that turns, which is the
role. A longer cap is worse: it aims past the wall the ship turns at.

**The roles were balanced so the difficulty curve did not move.** As first
built, hornets waited twice as long between shots and skulls 1.3×, and a bad
pilot's mean run grew by about a quarter on every setting (Normal 19.3 s →
24.9 s, 64 runs). Hornets at ×1.5, with skulls firing as often as crabs, put it
back: 54.9 / 20.0 / 13.0 s on Easy / Normal / Hard against 50.4 / 19.3 / 12.8 s
before species existed.

In play on Normal, 64 runs: crabs fire most (249 shots, 55.8% of them taking a
life); skulls fire 138 and hit 60.1%, up from 37.3% for the same slots before
the lead existed; hornets fire least (83, down from 207) and live longest —
median 2.5 s against a crab's 2.2 s and a skull's 1.8 s. Hard to hit, not
deadly, as intended.

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

**The *Was* column is the only record of the original balance.** `index.html`
used to embed its own copy of the old engine, which made it a working record of
the harder game, but it now links `pixel-wave.js` like every other page shell,
so that copy is gone.

---

## Browser support

Any browser with WebAssembly — every evergreen browser, iOS Safari 11+, Android
Chrome. The engine is embedded in the JS, so there is no build step, no
dependency and no network request at runtime.
