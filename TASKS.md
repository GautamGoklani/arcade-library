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
| `pixel-wave` | **All of its sound**, which is new: shot, enemy fire, kill, asteroid, hurt, wave cleared, game over, and the mute button | Medium — levels and the rate limit on enemy fire are guesses |
| `pixel-wave`, `grid-breaker`, `worm-chase` | **The retro retrofit.** Each was checked in the browser for a first few seconds of play; nobody has played one through at the new resolution. Rotated sprites in Pixel Wave now alias at 400×250, and Grid Breaker's 26px tile rows do not divide by three, so its rows come out 21 and 24 low-res pixels tall in turn | Low — worth a look, not a worry |
| `grid-breaker` | The paddle, power-up and launch sounds, which existed for the title's whole life but were first played when the engine got event counters | Low |
| hub | Best-score tags on the cards, and `hiscores.js` recording a finished run from each page shell. Exercised in a browser once, not across real play sessions | Low |
| `pulse` | Whether ±1 frame of jitter is acceptable in practice. The trade is argued in [chapter 22](docs/22-engine-owned-time.md) and has not been listened to | Medium |
| `tower-defense` | Right-click-to-sell, and whether the cursor's range ring is legible over a busy board | Low |
| `starfield-runner` | Whether the graze band *reads* — the ring lights at 30px of clearance, and nobody has checked that a player can tell a graze from a miss | Medium — it is the entire scoring rule |
| `circuit-runner` | Tap-zone touch controls | Untested on a real touchscreen |
| `sector-defense` | A wave has never been played through in a browser | Medium — attacker behaviour, the shield bracket, the combo HUD |
| `worm-chase` | Hold-to-move controls and the trail-connector rendering | Medium — both were changed after the last live look |
| `asteroid-miner` | Everything past the first few seconds | Medium |
| all nine | Touch controls on an actual device | Every touch scheme here is reasoned about, not tested |
| CI | `.github/workflows/check.yml` has been written and its steps run locally, but it has **not run on GitHub yet** — nothing has been pushed since it was added | Low — the first push will say |

**How to do this:** `npm run serve`, open each game, play for two minutes. It is
still the cheapest high-value work outstanding.

---

## 2 · Guards and infrastructure

### The layout guard cannot see field order — *needs a decision*

It compares named constants only. Neither side names *fields*: the `.wat`
documents them in a memory-map comment and the widget reads `f32[a + 4]`. Making
field 4 into field 5 is still a silent, unguarded break. A stricter check would
need the `.wat` comment to become machine-readable — or every widget to read
fields through named index constants instead of `f32[a + 4]` — and either one
reformats the schema that nine engines' documentation is built around. That is
the owner's call rather than a refactor to do unasked.

This is not hypothetical. Capping Tower Defense's tower pool at 28 moved every
pool after it, and the throwaway bench harness — which had `PATH_OFF` written
out as a literal — went on reading the old address and reported, plausibly and
completely wrongly, that no tower had ever hit anything.

---

## 3 · Library goals not built

### Pixel Wave's own roadmap — *product decisions*

Pause, power-ups, boss waves, per-species enemy behaviour, gamepad support,
difficulty settings. Listed in full at the bottom of
[`games/plans-for-other-games.md`](games/plans-for-other-games.md). Sound is
done. Each of the rest changes what the game *is*, so they are for the owner to
choose between rather than for anyone to work through in order.

---

## 4 · Documentation

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
