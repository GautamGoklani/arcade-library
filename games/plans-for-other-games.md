# Future Games Roadmap

Reference list of original game concepts planned for this project, all reusing
the Pixel Wave architecture: a hand-written WAT engine owning simulation state,
a pixel-sprite canvas renderer, keyboard + touch input, and the same embeddable
widget packaging (`mount / restart / destroy / getState`).

Every concept below is an **original design** — inspired by classic arcade
genres, but with its own name, mechanics, and art, not a clone of any specific
existing game. See
[`../docs/reference/Pixel_Wave_Originality_Statement.docx`](../docs/reference/Pixel_Wave_Originality_Statement.docx)
for the reasoning behind keeping designs original.

> **A note on names.** The original planning documents call the first title
> *Sky Skirmish*. It shipped as **Pixel Wave**, which is what the folder,
> the widget and the rest of this repository call it. The `.docx` files in
> `docs/reference/` still use the old name in places.

---

## Shipped

| Title | Concept | Engine |
|---|---|---|
| **[Pixel Wave](pixel-wave/)** | Retro wave shooter: the swarm patrols the upper half of the arena, asteroids fall, every cleared level adds an enemy. | 3.8 KB |
| **[Grid Breaker](grid-breaker/)** | Ball-and-paddle destruction with chain-reaction bomb tiles and physics-bending power-ups. | 4.9 KB |
| **[Worm Chase](worm-chase/)** | Grid territory capture: leave your land, loop back, and everything the loop sealed off becomes yours. Hazards, and chasers that cannot follow you home. | 3.8 KB |
| **[Asteroid Miner](asteroid-miner/)** | Mine a drifting rock field for gems. Rocks split when shot; fuel and cargo make every run a round trip. | 4.2 KB |
| **[Sector Defense](sector-defense/)** | Wave defence on one axis. Attackers with individual intent, a shield that regenerates only out of contact, and a decaying combo. | 3.6 KB |
| **[Circuit Runner](circuit-runner/)** | Endless lane runner on a circuit board. Nothing to shoot, one draining meter, and a board generated so it is always passable. | 3.0 KB |
| **[Starfield Runner](starfield-runner/)** | Free flight through a debris field. Nothing to shoot and nothing to collect: close passes are the only score and the only repair. | 3.0 KB |
| **[Tower Defense Lite](tower-defense/)** | A generated route, a core at the end, and twenty-eight tower slots. Guns overheat; a vent shoots nothing and cools its eight neighbours. | 5.1 KB |
| **[Pulse](pulse/)** | A rhythm tube shooter whose engine is the sequencer: it owns the tempo, the bar and the pattern, and a shot on the beat hits three times as hard. | 3.4 KB |

---

## Still to build

**Nothing.** Every concept on this list has shipped. What follows is the record
of how the order actually went and what each step was for; anything new from
here is a new idea rather than a backlog item.

All four steps of the original order are done, and between them they did the
job that order was designed to do. Grid Breaker proved the widget template
survives a second title. Worm Chase brought grid-based simulation into the
library — a fixed grid, a flood fill, and an engine with no imports at all.
Asteroid Miner was the promised evolution of the Pixel Wave engine: entities
that spawn entities, and resource state that turns a shooter into a supply run.
Sector Defense deepened the enemy behaviour the order asked for — attackers
that hold their own intent rather than moving as a body — and replaced lives
with two meters, which is the first title here that cannot kill the player at
all.

It also set the visual bar. Asteroid Miner renders at 320x240 with scanlines
and no glow anywhere, which reads as a machine of the period rather than a
modern game with pixel sprites in it. Every title since follows it, and Pixel
Wave, Grid Breaker and Worm Chase were retrofitted to match in September 2026,
so the hub no longer shows two generations side by side.

Circuit Runner was taken next out of order because it was the cheapest of the
four remaining and the only one with a genuinely new shape: it is the first
title here with **nothing to shoot**, and the first whose world is generated
rather than placed.

Starfield Runner followed it, under the condition this list had already set
down: *build the tight-squeeze scoring first, or do not build it.* That
condition was the right one, and meeting it is what makes the title distinct
from Circuit Runner despite both scrolling toward the player. Everything else
in it was chosen to serve the squeeze — free analogue flight instead of lanes,
because a lane cannot express two pixels; nothing to collect, because a pickup
would make safe flying viable; and a hull whose only repair is the charge that
close passes bank, so playing safe is not a slower strategy but a losing one.
The bench put a number on that: a pilot that always takes the widest gap scores
**23 points a second and never repairs a plate**, against 200-plus for one that
threads.

Tower Defense Lite came next, and it is the one that most needed to be
different in *shape* rather than in theme: it is the only title here where the
player places rather than steers, and where the interesting state is the board
instead of a position. Its own idea is that the binding resource is heat rather
than money — guns trip and stop firing, and a vent shoots nothing and cools the
eight squares around it. The bench found something about that worth keeping: a
third of the slots given over to vents cut overheating by half on every board
it tried, and bought **nothing at all** on a board of cheap guns while buying
three whole waves on a board that also had mortars. Support only pays in
proportion to what it is supporting.

**Pulse was last, and it was blocked on a misdiagnosis.** This list said for a
long time that it needed "the audio system planned for Pixel Wave v1.x", and
that is why it stayed unbuilt: the missing piece was never a synthesiser. Every
title since Grid Breaker has one, in eighty lines of Web Audio. What was
missing was an answer to the question the third invariant asks — if the music
decides when enemies arrive, and the music lives in JavaScript, then JavaScript
owns game state.

The answer is that it does not live in JavaScript. **The engine is the
sequencer.** It owns the tempo, the sixteen-step bar, the step counter and the
pattern; the widget diffs the step counter like any other event counter and
plays a note. The music and the game therefore cannot drift, because the spawn
and the note are the same event. A player timing a shot to what they hear is
timing it to what the engine did — and on the bench, doing so is worth six
times the score per second.

---

## Shared Infrastructure Goals

- A reusable **engine template** (entity pools, RNG, fixed memory-layout
  conventions) copied as the starting point for each new WAT engine.
- A shared **sprite toolkit** — the ASCII-grid sprite system extracted into a
  small library used by every title.
- A **consistent widget API** across all games so any site can host any title
  the same way.
- One **arcade hub page** hosting all titles with shared high-score storage.

> **These four have not all held up, and one of them was deliberately
> abandoned.** Every title in `games/` shares *no code* with any other: the
> engine template and the sprite toolkit are conventions copied by hand, not
> libraries, and each game's README says so. A shared library would mean a
> change made for one game could break another, which is the opposite of what
> this repository wants. The widget API *is* consistent and is worth keeping.
> The hub page exists as [`../index.html`](../index.html), and shared
> high-score storage now does too, as [`../hiscores.js`](../hiscores.js). It is
> the first real piece of shared code in the repository and it was built so
> that no game depends on it: each game's standalone page shell polls the
> widget's `getState()` and records a finished run, and the hub reads the
> results back onto its cards. No widget knows it exists.

---

## Pixel Wave's Own Roadmap (for context)

Pixel Wave (the first title) has its own planned evolution that the later games
will inherit pieces of:

- **Near term:** sound effects/music, high-score persistence, pause support,
  power-ups, run-stats game-over screen. *Sound effects arrived in Pixel Wave
  last of all, once its engine gained event counters to play them from. Best
  scores are kept by the hub's `hiscores.js` for every title rather than by
  the game. Music arrived in [Pulse](pulse/), by a route this list did not
  anticipate: the engine sequences it. Pause arrived in the widget rather than
  the engine: [chapter 15](../docs/15-game-loop-architecture.md) had already
  argued the engine has no clock to stop.*
- **Medium term:** boss waves every 10 levels, distinct per-species enemy
  behaviour, screen shake/hit-stop, gamepad support, difficulty settings.
- **Long term:** local co-op and online versus multiplayer (lockstep WASM), a
  level editor, achievements/unlockable skins.

See
[`../docs/reference/Pixel_Wave_Project_Plan_and_Roadmap.docx`](../docs/reference/Pixel_Wave_Project_Plan_and_Roadmap.docx)
for full detail on both Pixel Wave's own roadmap and this future-games list, and
[`../docs/reference/README.md`](../docs/reference/README.md) for where those
documents now disagree with the code.
