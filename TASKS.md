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

## 1 · Library goals not built

### Pixel Wave's own roadmap — done

Sound, pause, difficulty settings, per-species behaviour, gamepad support,
power-ups, boss waves, the run-stats game-over screen, screen shake and
hit-stop have all shipped; the game's README has a section on each. The
long-term tier in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md) — multiplayer,
a level editor, achievements — was never adopted as work, and is listed there
rather than here.

**One thing about hit-stop is unmeasured: how it feels.** Which events earn a
stop was settled by measuring how far apart each comes (see "Game over, shake
and hit-stop" in the README), but the lengths — 110 ms for a life, 50 ms for a
boss section, 200 ms for the boss — are the conventional range, not a
measurement, because the preview pane here issues no animation frames. Play a
boss fight and adjust the three numbers in `pollEvents()` in `pixel-wave.js`.

### Decisions the benches turned up — *yours to make*

Each is measured, and none is a defect. Each needs a choice, not a number.

Decided in September 2026, and recorded in each game's README rather than
here: Pixel Wave's rapid fire keeps its share of drops, Starfield Runner's
Hard keeps its thin repair loop, Worm Chase's Hard now adds a chaser every
level and a half instead of every level, and Sector Defense's quiet Normal
opening stays (Hard is the answer for players who want the fight earlier).
None remains open.

### Features the other eight could take — done

**Pause, gamepad support and difficulty settings are done everywhere**, all
nine titles, each a hand-written copy of the same shape. Every difficulty table
keeps Normal byte-identical to the engine that shipped before it, and each
game's README has a "Difficulty" section with its bench. What benching them
taught is in CLAUDE.md's tuning lessons, where the next piece of tuning will
find it.

Each of Pixel Wave's two later ideas — power-ups and boss waves — was asked of
every title, along with one idea of each title's own, and **every row that fits
has now shipped**. Each is a hand-written copy (invariant 1), and each game's
README has a section with its bench. The table stays as the record of what was
built and what was refused:

| Title | Power-ups | Boss waves | Its own idea |
|---|---|---|---|
| `pixel-wave` | **done** | **done** | — |
| `grid-breaker` | **has them** | **done** — the warden | **done** — the same warden |
| `worm-chase` | **done** — freeze and surge | **done** — the hunter | **done** — the same hunter |
| `asteroid-miner` | **done** — magnet and drill | **done** — the rival | **done** — the depot's refit |
| `sector-defense` | **done** — the shield module | **done** — the carrier | **done** — the lander |
| `circuit-runner` | **has them** | no | **done** — three gauntlets |
| `starfield-runner` | **no** | **done** — the leviathan | **done** — the gate |
| `tower-defense` | **done** — the purge | **done** — the leader | **done** — upgrade in place |
| `pulse` | **no** | **done** — the conductor, on the drop | **done** — the lead line |

**The three noes, so nobody re-derives them.** Starfield Runner takes no
power-up because a close pass is its only score *and* its only repair, and a
pickup that repairs cuts the spine out of it. Pulse takes none because it pays
for on-beat shots, and a power-up that fires faster or harder is a way to stop
listening. Circuit Runner has no boss because there is nothing to shoot and no
waves; its gauntlets are the equivalent. Grid Breaker and Worm Chase each got
one feature that answered two columns, because the boss *was* the own idea.

---

## 2 · What the benches could not verify — closed

Every difficulty table, and Pixel Wave's features, were tuned against headless
pilots, and each game's README used to end with what its pilots could not
reach. All of those gaps were closed in September 2026 with pilots built for
the one thing in question, and each README now says what that pilot found. One
real bug came out of it (Pixel Wave's boss spawned on top of the ship), fixed.
The findings that need a decision rather than a number are in section 1. The
one thing no bench here can measure is feel: hit-stop's lengths, above, and
whether a player reads Grid Breaker's warden as the thing to go for. Its README
has the bench, which shows ignoring the warden costs time and aiming at it
costs lives, but not which of the two a person will choose.

The October 2026 features add four more of the same kind, each with its bench
in its README: whether Starfield Runner's gates read early enough at speed to
be a choice, whether Sector Defense's landing brackets are read as a warning,
whether Asteroid Miner's refit menu reads as a shop or as clutter, and whether
its rival reads as a race or as theft.

---

## 3 · Documentation

Three things are deliberate and should not be "fixed":

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
