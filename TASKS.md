# Open tasks

Everything known to be outstanding, in one place. [`CLAUDE.md`](CLAUDE.md) is
how the repository works; this is what is left to do in it.

Two rules for keeping this file honest:

- **A task is only here if it is real.** Not "would be nice" — something that is
  missing, unverified, or inconsistent, with enough detail to act on cold.
- **Delete tasks when they are done.** A backlog that only grows stops being
  read. The git history is the record of what was finished.

New games are *not* tracked here; they live in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md). **Every
concept on that list has now shipped** — anything new from here is a new idea
rather than a backlog item.

---

## 1 · Verification debt

The browser preview pane in the development environment stops issuing animation
frames within a fraction of a second of load (measured: 0 rAF/sec). Every engine
is benched headlessly and that catches simulation bugs well — but **rendering
and input have largely not been exercised by a human**. This remains the largest
category of risk in the repository and none of it needs new design work, only
somebody playing the games in a real browser.

Some of this debt was paid down while the last three titles were built, by a
trick worth reusing: **override `window.requestAnimationFrame` with a queue
before mounting, then pump it by hand from the console.** The pane's frozen rAF
is then irrelevant, the widget runs as many frames as you ask for, and you can
screenshot any moment you like. It found three real rendering bugs — a
collapsed `line-height` that made every game's overlay overprint itself at
phone widths, a crash on a negative frame index, and a HUD element too faint to
see. It cannot test *feel*, which is what is still missing.

| Title | What is unverified | Risk |
|---|---|---|
| `pulse` | **The soundtrack.** Every note is synthesised and has only ever been read, not heard. The whole title turns on whether the beat is findable by ear | High — it is the one thing the design rests on |
| `pulse` | Whether ±1 frame of jitter is acceptable in practice. The trade is argued in [chapter 22](docs/22-engine-owned-time.md) and has not been listened to | Medium |
| `tower-defense` | Right-click-to-sell, and whether the cursor's range ring is legible over a busy board | Low |
| `starfield-runner` | Whether the graze band *reads* — the ring lights at 30px of clearance, and nobody has checked that a player can tell a graze from a miss | Medium — it is the entire scoring rule |
| `circuit-runner` | Tap-zone touch controls | Untested on a real touchscreen |
| `sector-defense` | A wave has never been played through in a browser | Medium — attacker behaviour, the shield bracket, the combo HUD |
| `worm-chase` | Hold-to-move controls and the trail-connector rendering | Medium — both were changed after the last live look |
| `asteroid-miner` | Everything past the first few seconds | Medium |
| all nine | Touch controls on an actual device | Every touch scheme here is reasoned about, not tested |

**How to do this:** `npm run serve`, open each game, play for two minutes. It is
still the cheapest high-value work outstanding.

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

`scripts/check-layout.mjs` covers eight of nine titles. Pixel Wave is skipped
because its widget predates the convention and spells the constants differently
on each side, so there is no shared name to match on. **Renaming them to match
is the way in** — the engine's globals are the names to keep.

### The layout guard cannot see field order

It compares named constants only. Neither side names *fields*: the `.wat`
documents them in a memory-map comment and the widget reads `f32[a + 4]`. Making
field 4 into field 5 is still a silent, unguarded break. A stricter check would
need the `.wat` comment to become machine-readable, which is a real design
decision, not an afternoon.

This is not hypothetical. Capping Tower Defense's tower pool at 28 moved every
pool after it, and the throwaway bench harness — which had `PATH_OFF` written
out as a literal — went on reading the old address and reported, plausibly and
completely wrongly, that no tower had ever hit anything.

---

## 3 · Consistency debt

### Three titles predate the retro render treatment

`asteroid-miner`, `sector-defense`, `circuit-runner`, `starfield-runner`,
`tower-defense` and `pulse` draw into a 320×240 buffer blown up 3× with
scanlines and no glow. `pixel-wave`, `grid-breaker` and `worm-chase` do not, so
the hub shows two visual generations side by side.

Retrofitting is mechanical — the recipe is in
[`CLAUDE.md`](CLAUDE.md#the-retro-render-treatment) and the transform is the
entire adapter, so no draw-code coordinates change. The judgement call is
whether the library *should* be uniform: an argument exists that the earlier
titles are period pieces of their own and that forcing one look on nine games
made over time is revisionism. **Decide before doing it, and record the
decision here.**

### Pixel Wave still has no sound

Every other title synthesises its own. Pixel Wave's roadmap listed sound as a
near-term item and it never arrived; the widget has no `createSound()` at all.
The eight other titles are eight worked examples of what it would look like,
and [Pulse](games/pulse/) is the one to copy from if the answer should be
musical rather than a set of blips.

### Grid Breaker predates several conventions

It arrived from a portfolio repository. Its per-title `build.js` was already
dropped in favour of the shared builder, and its paddle bounce has since been
fixed, but it still has **no event counters** — its widget infers what happened
by watching state rather than diffing a counter, which is the thing invariant 4
exists to prevent. Pixel Wave has the same gap.

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

Nine titles now expose a `getState()` with a `score` in it, which is the whole
interface such a module would need.

### Pixel Wave's own roadmap

Pause, power-ups, boss waves, per-species enemy behaviour, gamepad support,
difficulty settings. Listed in full at the bottom of
[`games/plans-for-other-games.md`](games/plans-for-other-games.md). Sound and
music are no longer blockers for anything — Pulse answered that question — so
what is left here is Pixel Wave's own catching-up.

---

## 5 · Documentation

Nothing outstanding, but three things are deliberate and should not be "fixed":

- **Chapters 6, 7 and 17 teach from Vector Arena**, which was removed from the
  repository in `e90bc03`. The material stayed because those three techniques —
  the import index space, shipping a bare engine, closest-approach dodging —
  appear nowhere else in the course, and the code is quoted in full. Each says
  so inline.
- **Three engines have no chapter.** Grid Breaker arrived after the first
  seventeen were written; Starfield Runner and Tower Defense Lite are worked
  variations on ideas chapters 21 and 16 already cover, and a chapter that
  restates one is worse than no chapter. All three are documented at length by
  their own READMEs, and `docs/README.md` says which and why.
- **`docs/reference/*.docx` describe an old balance.** They are historical
  records, kept unconverted on purpose;
  [`docs/reference/README.md`](docs/reference/README.md) lists the corrections.
