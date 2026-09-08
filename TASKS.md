# Open tasks

Everything known to be outstanding, in one place. [`CLAUDE.md`](CLAUDE.md) is
how the repository works; this is what is left to do in it.

Two rules for keeping this file honest:

- **A task is only here if it is real.** Not "would be nice" — something that is
  missing, unverified, or inconsistent, with enough detail to act on cold.
- **Delete tasks when they are done.** A backlog that only grows stops being
  read. The git history is the record of what was finished.

New games are *not* tracked here; they live in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md), which has
the concepts, the build order and the reasoning. The summary is at the bottom.

---

## 1 · Verification debt

The browser preview pane in the development environment stops issuing animation
frames within a fraction of a second of load (measured: 0 rAF/sec). Every engine
is benched headlessly and that catches simulation bugs well — but **rendering
and input have largely not been exercised by a human**. This is the largest
category of risk in the repository and none of it needs new design work, only
somebody playing the games in a real browser.

| Title | What is unverified | Risk |
|---|---|---|
| `circuit-runner` | The capacitor, chip and solder-bridge draw branches have never been seen rendered — only the resistor. All four are `fillRect` sequences in `drawParts`. | Low, but they are new code |
| `circuit-runner` | Tap-zone touch controls | Untested on a real touchscreen |
| `sector-defense` | A wave has never been played through in a browser | Medium — attacker behaviour, the shield bracket, the combo HUD |
| `worm-chase` | Hold-to-move controls and the trail-connector rendering | Medium — both were changed after the last live look |
| `asteroid-miner` | Everything past the first few seconds | Medium |
| all six | Touch controls on an actual device | Every touch scheme here is reasoned about, not tested |

**How to do this:** `npm run serve`, open each game, play for two minutes. It is
the cheapest high-value work outstanding.

---

## 2 · Guards and infrastructure

### CI does not exist

`npm run check` is the guard the whole repository leans on — it verifies the
committed `.wasm` against every `.wat`, the committed `docs/*.html` against
every `.md`, every relative link, and that each widget agrees with its engine
about linear memory. Nothing runs it automatically. There is no `.github/`.

A workflow that runs `npm ci && npm run check` on push would be a few lines.
`.gitattributes` already pins line endings, which is what previously made
`--check` fail on a clean clone, so this should now pass on a Linux runner
first time.

### Pixel Wave is excluded from the layout guard

`scripts/check-layout.mjs` covers five of six titles. Pixel Wave is skipped
because its widget predates the convention and spells the constants differently
on each side, so there is no shared name to match on. **Renaming them to match
is the way in** — the engine's globals are the names to keep.

### The layout guard cannot see field order

It compares named constants only. Neither side names *fields*: the `.wat`
documents them in a memory-map comment and the widget reads `f32[a + 4]`. Making
field 4 into field 5 is still a silent, unguarded break. A stricter check would
need the `.wat` comment to become machine-readable, which is a real design
decision, not an afternoon.

---

## 3 · Consistency debt

### Two titles predate the retro render treatment

`asteroid-miner`, `sector-defense` and `circuit-runner` draw into a 320×240
buffer blown up 3× with scanlines and no glow. `pixel-wave`, `grid-breaker` and
`worm-chase` do not, so the hub currently shows two visual generations side by
side.

Retrofitting is mechanical — the recipe is in
[`CLAUDE.md`](CLAUDE.md#the-retro-render-treatment) and the transform is the
entire adapter, so no draw-code coordinates change. The judgement call is
whether the library *should* be uniform: an argument exists that the earlier
titles are period pieces of their own and that forcing one look on six games
made over time is revisionism. **Decide before doing it, and record the
decision here.**

### Grid Breaker predates several conventions

It arrived from a portfolio repository. Its per-title `build.js` was already
dropped in favour of the shared builder, but it has not been audited against the
current invariants — event counters, the `get_*` reader surface, and where
scalars live are all worth a read.

---

## 4 · Library goals not built

### Shared high-score storage

The one item from the original "shared infrastructure" list that was neither
built nor deliberately abandoned. See the note in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md): the engine
template and sprite toolkit were dropped on purpose, because a shared library
means a change for one game can break another. High-score storage is different —
it is a hub concern, not an engine one, and would be **the first real piece of
shared code in the repository**. That makes it worth designing carefully:
`localStorage` per title behind one small module owned by `index.html`, with no
game depending on it.

### Pixel Wave's own roadmap

Sound, high-score persistence, pause, power-ups, boss waves, per-species enemy
behaviour, gamepad support, difficulty settings. Listed in full at the bottom of
[`games/plans-for-other-games.md`](games/plans-for-other-games.md). **Pulse is
blocked on the audio work** in that list, so it is the item with a dependency
hanging off it.

---

## 5 · Documentation

Nothing outstanding, but two things are deliberate and should not be "fixed":

- **Chapters 6, 7 and 17 teach from Vector Arena**, which was removed from the
  repository in `e90bc03`. The material stayed because those three techniques —
  the import index space, shipping a bare engine, closest-approach dodging —
  appear nowhere else in the course, and the code is quoted in full. Each says
  so inline.
- **`docs/reference/*.docx` describe an old balance.** They are historical
  records, kept unconverted on purpose;
  [`docs/reference/README.md`](docs/reference/README.md) lists the corrections.

---

## 6 · Remaining games

Detail, complexity and reasoning in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md).

| Title | State |
|---|---|
| **Starfield Runner** | Cheapest remaining, but it scrolls toward the player exactly as Circuit Runner does. Its distinguishing idea is tight-squeeze bonus scoring — **build that first, or do not build it** |
| **Pulse** | Blocked: needs the audio system from Pixel Wave's roadmap (§4) |
| **Tower Defense Lite** | Unblocked, and the most different from anything shipped |
