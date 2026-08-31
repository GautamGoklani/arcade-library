# Original project documents

Three Word documents written alongside Pixel Wave's development. They are kept
here as a historical record, not as current documentation.

| File | Covers |
|---|---|
| [Technical Reference](Pixel_Wave_Technical_Reference.docx) | Architecture, memory layout, sprite pipeline, tuning guide |
| [Project Plan and Roadmap](Pixel_Wave_Project_Plan_and_Roadmap.docx) | Scope, milestones, planned features |
| [Originality Statement](Pixel_Wave_Originality_Statement.docx) | Provenance of the engine, art and design |

They are left as `.docx` rather than converted. Their value is being the
originals; a converted copy would be a second, subtly different version of a
document whose whole point is that it has not been edited since.

## Read these with two corrections in mind

**They describe the original balance, not the shipped one.** The tuning tables in
§7 quote the pre-August-2026 constants — `$MAX_SPEED 270`, `$PLAYER_FIRE_CD 0.2`,
enemy count 4→33, hold-to-fire rather than burst fire. Every one of those was
changed. [`../../games/pixel-wave/README.md`](../../games/pixel-wave/README.md)
has the current values and what moved.

**§7.1 calls `$ROT_SPEED` a "rotation accel (rad/sec²)". It is not.** The engine
applies it directly as a rate: `heading += rotDir * ROT_SPEED * dt`. The units
are radians per second.

**They describe v2 only.** Vector Arena has a different memory layout, different
AI and no levels. Reading these while editing
[`../../games/vector-arena/game.wat`](../../games/vector-arena/game.wat) will
mislead you on every offset.

For current, maintained documentation, use the [course](../README.md) —
particularly [chapter 15](../15-game-loop-architecture.md),
[16](../16-entity-pools.md) and [17](../17-math-without-a-stdlib.md), which
cover the same ground against the code as it actually stands.
