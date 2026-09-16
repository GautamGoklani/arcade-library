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

| Title | Would take | What it involves |
|---|---|---|
| `grid-breaker` | Difficulty settings | Paddle width, ball speed, starting lives. It already has power-ups |
| `worm-chase` | Difficulty settings | Chaser count and speed, hazard density |
| `asteroid-miner` | Difficulty settings; a depot upgrade | Fuel burn and rock density; or spend cargo on hold size, fuel or hull |
| `sector-defense` | Difficulty settings; a heavy attacker | Its intent lives per entity already, so a new kind is mostly a new column of constants |
| `circuit-runner` | A gentler opening | Speed is its only difficulty curve, so "easier" means starting slower and ramping later, not a new mechanic |
| `starfield-runner` | Difficulty settings | Graze band width and rock density. The band *is* the scoring rule, so widening it is the honest knob |
| `tower-defense` | Difficulty settings; tower upgrades | Starting funds and wave strength; upgrading a tower in place rather than adding a fourth kind |
| `pulse` | Difficulty settings | Tempo, and how full each bar is. The engine already owns the sequencer, so this is its table to extend |

Difficulty settings anywhere mean the same shape as Pixel Wave's: a tuning table
the engine's `init()` applies, a re-bench of every setting with a pilot that
plays badly, and one best score per setting.

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
