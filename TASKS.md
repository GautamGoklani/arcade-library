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

### Pixel Wave's own roadmap — three items left

Shipped: sound, pause, difficulty settings, per-species behaviour, gamepad
support, power-ups and boss waves. Three items from the plan's near and medium
terms are **not** built, although an earlier version of this section said they
were — checked against the widget in September 2026:

- **A run-stats game-over screen** (near term). The overlay says GAME OVER and
  PRESS R TO RESTART and nothing else. The plan asked for accuracy, enemies
  destroyed and waves survived. Every number it needs already exists as an
  event counter — `get_shots`, `get_kills`, `get_rocks`, `get_waves`, and now
  `get_grabs` and `get_boss_downs` — so this is widget work, with no engine
  change and nothing to re-bench. Accuracy is kills plus rocks over shots, with a
  spread volley counting as one shot (see "Power-ups" in the game's README).
- **Screen shake** (medium term). Every other title shakes on a hit; Pixel Wave
  only flashes. The retro adapter already expects it — the comment above `Z` in
  `pixel-wave.js` says the transform's offset is "always a whole low-res pixel,
  screen shake included" — but nothing ever sets an offset. Copy the shape from
  a title that has it, snapped to whole low-res pixels, and drop it under
  `prefers-reduced-motion`.
- **Hit-stop** (medium term). A few frames of frozen simulation on a kill or a
  hit. This one is a design question before it is code: the engine takes
  whatever `dt` it is given, so hit-stop belongs in the widget's loop the way
  pause does ([chapter 15](docs/15-game-loop-architecture.md)), and a boss part
  going down every few seconds may make it tiring rather than weighty. Bench or
  play it before committing to it.

The long-term tier in
[`games/plans-for-other-games.md`](games/plans-for-other-games.md) — multiplayer,
a level editor, achievements — was never adopted as work, and is listed there
rather than here.

### Features the other eight could take — *product decisions*

Ideas fitted to particular games. None of this is a defect — it is a menu,
written down so the choice gets made once and on purpose. **Invariant 1 means
every row is per-game work**: each title gets its own hand-written copy, never a
shared helper.

**Pause, gamepad support and difficulty settings are done everywhere**, all
nine titles, each a hand-written copy of the same shape. Every difficulty table
keeps Normal byte-identical to the engine that shipped before it, and each
game's README has a "Difficulty" section with its bench. What benching them
taught is in CLAUDE.md's tuning lessons, where the next piece of tuning will
find it.

Each of Pixel Wave's two later ideas — power-ups and boss waves — was asked
of every title, and **not all of them fit**. A feature
that would blunt what a game is about is listed as a no, with the reason, so
nobody has to re-derive it later.

| Title | Power-ups | Boss waves | Its own idea |
|---|---|---|---|
| `pixel-wave` | **done** | **done** | — |
| `grid-breaker` | **has them** | yes | a tile that repairs its neighbours |
| `worm-chase` | yes | yes | a hunter that cuts your trail |
| `asteroid-miner` | yes | maybe | spend cargo at the depot |
| `sector-defense` | yes | yes | a carrier that lands attackers |
| `circuit-runner` | **has them** | no | a named stretch of board |
| `starfield-runner` | **no** | yes | a squeeze that scores double |
| `tower-defense` | as abilities | yes | upgrade a tower in place |
| `pulse` | **no** | yes | a second instrument line |

**Power-ups.** Grid Breaker already has them (WIDE, MULTI, SLOW, STICKY) and
Circuit Runner's charges and boosts are the same idea wearing its economy's
clothes — both would take new *kinds*, not a new system. Worm Chase could drop a
freeze or a burst of speed onto a claimed cell; Asteroid Miner could carry a
magnet or a bigger drill home; Sector Defense could drop a shield module from a
kill; Tower Defense's version is a bought one-shot ability rather than a pickup,
since nothing there flies over the board to collect. **Two say no.** Starfield
Runner's whole economy is that a close pass is the only score *and* the only
repair — a pickup that also repairs cuts the spine out of it. Pulse pays for
on-beat shots; a power-up that fires faster or harder is a way to stop listening,
which is the one thing the game asks of you.

**Boss waves.** The natural fits are the games with a wave structure already:
Sector Defense (a carrier that lands attackers instead of walking in), Tower
Defense (an armoured leader among the damper wave), Grid Breaker (an armoured
tile that repairs its neighbours until you break it first), Worm Chase (a hunter
chaser every few levels that cuts the trail rather than chasing the head), Pulse
(a boss on the drop, killable only on the beat, which its bar already knows how
to express). Starfield Runner's would be a leviathan to thread rather than a
thing to shoot. **Circuit Runner is a no**: there is nothing to shoot and no
waves — its equivalent is a named stretch of board, a gauntlet with a
recognisable shape, which is the "its own idea" column instead. Asteroid Miner
is a maybe: a rival miner working the same rocks is a better fit for it than a
boss with a health bar, and that is closer to its depot idea than to a wave.

---

## 2 · What the benches could not verify

Every difficulty table, and both Pixel Wave features, were tuned against
headless pilots, and each game's README says what its pilots could not reach.
Collected here so they are not only findable one README at a time. None is a
known bug; each is a number nobody has measured. The cheapest way to close most
of them is a pilot built to exercise the one thing in question — CLAUDE.md's
tuning lessons say how.

- **Pixel Wave — rapid fire's value.** The bench pilot is limited by its aim, not
  its rate of fire: firing four times as often left its survival exactly where
  it was. So rapid fire was worth nothing to it, and no pilot here shows what it
  is worth to a player who can aim.
- **Pixel Wave — the boss fight's edges.** The fight was benched from builds
  that start at level 10 with *full* lives; a real player arrives with what nine
  levels left them. The "reader" pilot only answers the aimed volley — nobody has
  measured the fan's gaps or the ring's spokes as things a player reads. A pilot
  that never dodges also sometimes fires at the plated core forever (5 of 64
  timeouts on Easy), because nothing tells it the tick means *stop*.
- **Asteroid Miner — above level 4.** The bench pilot never passes level 4, and
  the density caps are reached at levels 7, 8 and 9, so the field once density
  stops growing is untested on every setting.
- **Worm Chase — the per-level half of its table.** Its bench pilot never clears
  level 1, so how fast a new chaser arrives, how hazards grow and how the target
  tightens are untested; only the level-1 numbers are measured.
- **Starfield Runner — the repair loop.** No pilot, on any setting, ever filled
  the charge meter and bought a plate back. The half of the economy that makes
  flying close worth the risk is unmeasured.
- **Tower Defense — anything but reading-order placement.** Both pilots build in
  the first free square beside the track and never sell. How much good placement
  is worth, on each setting, is untested.
- **Sector Defense — Normal's quiet opening.** On Normal the sector is still
  untouched at wave 17 against the bench pilot. That is the balance the game
  shipped with, and Normal is byte-identical to it, so the difficulty table could
  not change it. Whether a quiet first several minutes is intended is the
  owner's call, not a tuning task — Hard is the answer for players who want the
  fight earlier.
- **Circuit Runner — one harsh Hard board.** One of 24 boards ends at 11 s on
  Hard (three early hits, two charges), against a worst of 24 s on Normal. It is
  Hard's hit cost doing it. Worth playing that seed before deciding whether it
  matters.

### One code hazard, in Pixel Wave's engine

**Losing a life is written out four times** in `games/pixel-wave/game.wat`: for
an enemy round, an asteroid, a bot ram and a boss ram. Each copy checks the
shield, spends it or takes a life, counts the hurt, and ends the game at zero.
The shield had to be added to three copies and then a fourth, and a fifth way to
be hit would need a fifth copy that could quietly differ. The copies live
because `$lives` and `$palive` are locals of `step`; a helper would take the
lives and return them, the way `$hit_boss` returns points to `step`. The
level-1-9 replay in the game's README is the check that such a change altered
nothing.

---

## 3 · Documentation

**One technique the course does not teach yet: a second random stream.** Pixel
Wave's power-ups roll from `$dropRng`, their own xorshift state, so that a run
where nothing is collected replays the engine that had no power-ups byte for
byte — which is what made the change checkable, and why the difficulty table
needed no re-tuning. The boss makes the related point from the other side: its
attacks draw nothing at all, so levels 1-9 replay exactly. [Chapter
8](docs/08-globals-and-state.md) already discusses how `$rng` carries across a
restart (the section around "`$rng` does not appear in that list"), which makes
it the natural home: *what you draw a random number from decides what a change
can disturb.* The game's README has the measurements to quote.

Beyond that, three things are deliberate and should not be "fixed":

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
