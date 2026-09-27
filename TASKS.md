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

### Pixel Wave's own roadmap — *product decisions*

Power-ups and boss waves. Listed in full at the bottom of
[`games/plans-for-other-games.md`](games/plans-for-other-games.md). Sound,
pause, difficulty settings, per-species enemy behaviour and gamepad support are
done. Both of the rest change what the game *is*, so they are for the owner to
choose between rather than for anyone to work through in order.

### Features the other eight could take — *product decisions*

Ideas fitted to particular games. None of this is a defect — it is a menu,
written down so the choice gets made once and on purpose. **Invariant 1 means
every row is per-game work**: each title gets its own hand-written copy, never a
shared helper.

**Pause and gamepad support are done everywhere**, all nine titles, each a
hand-written copy of the same shape.

Each of Pixel Wave's three remaining ideas — difficulty settings, power-ups,
boss waves — was asked of every title, and **not all of them fit**. A feature
that would blunt what a game is about is listed as a no, with the reason, so
nobody has to re-derive it later.

| Title | Difficulty settings | Power-ups | Boss waves | Its own idea |
|---|---|---|---|---|
| `pixel-wave` | **done** | yes | yes | — |
| `grid-breaker` | **done** | **has them** | yes | a tile that repairs its neighbours |
| `worm-chase` | **done** | yes | yes | a hunter that cuts your trail |
| `asteroid-miner` | **done** | yes | maybe | spend cargo at the depot |
| `sector-defense` | **done** | yes | yes | a carrier that lands attackers |
| `circuit-runner` | a gentler opening | **has them** | no | a named stretch of board |
| `starfield-runner` | **done** | **no** | yes | a squeeze that scores double |
| `tower-defense` | **done** | as abilities | yes | upgrade a tower in place |
| `pulse` | **done** | **no** | yes | a second instrument line |

**Difficulty settings** anywhere mean the same shape as Pixel Wave's: a tuning
table the engine's `init()` applies, a re-bench of every setting with a pilot
that plays badly, and one best score per setting. **Eight are done** — Pixel
Wave, Grid Breaker, Worm Chase, Asteroid Miner, Sector Defense, Starfield
Runner, Tower Defense and Pulse — each a hand-written copy of the same shape, and
in each of the seven that followed Pixel Wave, Normal replays the engine that
shipped before the setting existed.

Three lessons so far are worth carrying into the one left. From Sector Defense:
**the knobs named below may not be the ones that decide when a game gets hard.**
Its three were the right knobs and still produced columns that only separated in
the last minute of a six-minute run, because a shared curve elsewhere dominated
all of them. Bench the table, then instrument a run and look at *when* the
meters actually start moving. From Starfield Runner: **one pilot may not reach
the knob you care about.** A pilot that only dodges never grazed, so it could not
see the graze band at all; measuring that took a second pilot flying a *fixed*
standoff on every setting, so the band width was the only variable. From Pulse:
**move the rate, not only the start.** Its first Hard column opened denser and
killed the weak pilot at level 2; opening on Normal's bar and filling it faster
kept level 1 gentle and still separated the columns. For the one left:
**Circuit Runner is the exception**: speed is
its only curve, so "easier" is starting slower and ramping later, not a setting
with columns.

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

## 2 · Documentation

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
