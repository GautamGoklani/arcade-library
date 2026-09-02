# Future Games Roadmap

Reference list of original game concepts planned for this project, all reusing
the Sky Skirmish architecture: a hand-written WAT engine owning simulation
state, a pixel-sprite canvas renderer, keyboard + touch input, and the same
embeddable widget packaging (`mount / restart / destroy / getState`).

Every concept below is an **original design** — inspired by classic arcade
genres, but with its own name, mechanics, and art, not a clone of any
specific existing game. See `Sky_Skirmish_Originality_Statement.docx` for
the reasoning behind keeping designs original.

---

## Candidate Titles

| Working Title | Concept | Complexity |
|---|---|---|
| **Asteroid Miner** | Mine drifting rock fields for gems while dodging hazards. Rocks split when shot; cargo and fuel management add a strategy layer. | Medium |
| **Grid Breaker** | Ball-and-paddle destruction with unique tile patterns, chain-reaction tiles, and physics-bending power-ups. | Low |
| **Worm Chase** | Grid-based growth game with an original twist — territory capture and hazard tiles instead of simple self-avoidance. | Low |
| **Circuit Runner** | Endless lane-runner across a circuit board; dodge components, collect current, speed scales with survival time. | Low–Medium |
| **Sector Defense** | Wave-defense shooter with unpredictable horizontal enemy movement, shield recharging, and combo scoring. | Medium |
| **Pulse** | Abstract tube shooter driven by rhythm — enemy spawns sync to the beat of the soundtrack. | Medium–High |
| **Starfield Runner** | Vertical endless scroller through dense obstacle fields with tight-squeeze bonus scoring. | Low–Medium |
| **Tower Defense Lite** | Minimal tower placement and wave defense with original tower types and enemy roles. | Medium–High |

---

## Suggested Build Order

1. **Grid Breaker** — smallest engine, fastest to ship; validates reusing the widget template on a second title.
2. **Worm Chase** — introduces grid-based simulation to the engine library.
3. **Asteroid Miner** — richest evolution of the Sky Skirmish engine (splitting entities, resource state).
4. **Sector Defense** — deepens the enemy-behavior systems planned for Sky Skirmish v2.
5. **Pulse** — most ambitious; depends on the audio system planned for Sky Skirmish v1.x.

---

## Shared Infrastructure Goals

- A reusable **engine template** (entity pools, RNG, fixed memory-layout conventions) copied as the starting point for each new WAT engine.
- A shared **sprite toolkit** — the ASCII-grid sprite system extracted into a small library used by every title.
- A **consistent widget API** across all games so any site can host any title the same way.
- One **arcade hub page** hosting all titles with shared high-score storage.

---

## Sky Skirmish's Own Roadmap (for context)

Sky Skirmish (the first title) has its own planned evolution that the later
games will inherit pieces of:

- **Near term:** sound effects/music, high-score persistence, pause support, power-ups, run-stats game-over screen.
- **Medium term:** boss waves every 10 levels, distinct per-species enemy behavior, screen shake/hit-stop, gamepad support, difficulty settings.
- **Long term:** local co-op and online versus multiplayer (lockstep WASM), a level editor, achievements/unlockable skins.

See `Sky_Skirmish_Project_Plan_and_Roadmap.docx` for full detail on both Sky
Skirmish's own roadmap and this future-games list.