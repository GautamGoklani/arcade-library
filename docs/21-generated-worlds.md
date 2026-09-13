# 21 · Case study: generating a world that is always winnable

← [Giving each entity its own intent](20-per-entity-intent.md) · [Contents](README.md) · next: [The engine that owns time](22-engine-owned-time.md)

---

Every engine so far has placed things at random and left it there. Pixel Wave
scatters a wave; Asteroid Miner drops boulders anywhere but the depot; Sector
Defense picks a lateral target per attacker. In all three, a bad roll produces a
harder moment and nothing worse, because the player can always move in two
dimensions and the threat eventually leaves.

[Circuit Runner](../games/circuit-runner/) cannot do that. It is a lane runner:
the board arrives in rows, the runner has one axis and limited speed on it, and
a row that cannot be threaded is not "hard", it is a wall. This chapter is about
generating a world under that constraint — and about the class of bug where
every individual decision is fair and the sequence of them is not.

Read it with
[`games/circuit-runner/game.wat`](../games/circuit-runner/game.wat) open.

---

## The bug: locally fair, globally impossible

The first generator built each row independently. Pick how many traces to
block, place components in traces that are still free, done. Every row left at
least two of six traces open, which sounds unimpossible-to-fail.

The bench took a hit every two seconds while playing correctly.

The reason is a constraint that lives *between* rows rather than in any of them.
At the speed cap the board moves 640 px/s and rows are 172px apart, so a row
arrives every 0.27 seconds. The runner slides at 900 px/s across 160px traces:
0.18 seconds each. That is time to cross **about one and a half traces between
rows**. Two consecutive rows whose only gaps are three traces apart are
individually generous and jointly impossible, and no amount of skill closes the
distance.

This is worth naming because it recurs everywhere procedural generation meets a
movement budget: **the reachability of a state is a property of the sequence,
not of the state.** A generator that validates each step in isolation cannot see
it.

---

## The fix: reserve a path, and make it wander slowly

```wat
(global $pathLane (mut i32) (i32.const 2))

(func $spawn_row
  ...
  (global.set $pathLane
    (call $clampi
      (i32.add (global.get $pathLane) (i32.sub (call $rand_below (i32.const 3)) (i32.const 1)))
      (i32.const 0) (i32.sub (global.get $LANES) (i32.const 1))))
  ...)
```

One lane, remembered across rows, moving by at most one per row. Then no
component may ever cover it:

```wat
;; Never cover the path lane, and never overlap a lane this row has
;; already taken — the second would spend the budget twice.
(br_if $lp (i32.ne (i32.and (call $span_mask (local.get $lane) (local.get $span))
                            (i32.shl (i32.const 1) (global.get $pathLane)))
                   (i32.const 0)))
```

The board is now passable **by construction**. Not "almost always", not "we
tested it" — there is a continuous path down the board, and the runner can
always follow it because it never moves further in one row than the runner can
travel in one row.

Three things worth noticing about this shape of fix:

**It is a guarantee, not a probability.** The alternative — generate, then
validate, then regenerate on failure — is tempting and much worse here. It needs
a reachability search per row, it can loop, and it has to answer "what if I
cannot generate a valid row?" at the exact moment the player is watching. A
constructive invariant has no failure branch.

**It costs one global and one bit test.** The whole guarantee is a lane index
and a mask check inside a loop that was already running. Difficulty did not have
to be lowered to buy it — `$max_blocked` still climbs, components still get
faster and denser.

**It moves the difficulty rather than removing it.** The player now always
*can* follow the path; what is hard is reading which trace it is, and deciding
what it costs to leave it. Which is the second half of the design.

---

## Making the reward compete with the safe answer

A guaranteed path with a guaranteed reward on it would be a corridor. The
charges are what make it a game, and where they are placed turned out to matter
more than how much they give.

The first build put each charge in a **uniformly random open trace**. The bench
collected two out of ten. That is not a difficult economy — the charge was
usually four traces away, which is not a decision, it is a lottery ticket the
player watches expire.

```wat
;; An open lane for this row's pickup, searched outward from wherever the
;; runner is standing.
(func $free_lane_near_runner (result i32)
  (local $d i32) (local $home i32) (local $l i32)
  (local.set $home (i32.trunc_f32_s (f32.load offset=4 (global.get $RUNNER_OFF))))
  ...
  ;; left then right at each distance, so ties do not always resolve the
  ;; same way and a wall of rows does not drag the runner to one edge
```

Searching outward from the runner puts the charge one or two traces away almost
always — close enough to be a real option, so it *competes* with the safe trace
instead of being a gift or a tease. The interesting rows are now the ones where
the charge is on the far side of a component.

The bench confirms the tension is real rather than decorative: the pilot that
detours for charges takes **roughly twice as many hits** and **survives longer**.
If those two had not both moved, the reward would be either free or pointless.

---

## Geometry is a rule, not a look

One more failure from the same build, and it is the one most likely to catch you
somewhere else: components were drawn — and collided — 16px inset into a 160px
trace. Half-width 64. The runner's half-width is 22.

A runner sliding between two traces passes through the boundary, **80px from the
blocked trace's centre**. And 64 + 22 = 86 > 80, so *passing* a component hit it.

The consequence was invisible in any single frame and structural in play: a free
trace two across with a blocked one between was unreachable, so the path
guarantee above was necessary but not sufficient. The inset is now 26 — 54 + 22
= 76, four pixels of margin — and it is documented in the code as an arithmetic
constraint rather than a styling choice:

```wat
;; The 26px inset is a geometry constraint, not a style choice. A runner
;; sliding between two lanes passes through the boundary, 80px from the
;; blocked lane's centre; for that crossing not to clip, the part's half-width
;; plus the runner's 22 must stay under 80.
```

The general lesson: **in a game with discrete positions and a continuous slide
between them, the hitbox width and the lane width are one equation.** Choosing
them independently, which is what "make the sprite look right" amounts to, will
eventually produce a move the rules permit and the geometry forbids.

---

## Difficulty as a function of distance

Circuit Runner has no levels. Everything scales off one number:

```wat
(func $km (result f32)
  (f32.div (global.get $dist) (f32.const 1000.0)))

(func $speed (result f32)
  (call $clampf
    (f32.add (global.get $SPEED_BASE) (f32.mul (call $km) (global.get $SPEED_PER_KM)))
    (global.get $SPEED_BASE) (global.get $SPEED_CAP)))
```

Speed, row spacing, how many traces a row may block, and which component kinds
are in play are all `f(distance)`, each clamped. Compare Sector Defense, where
the same job is done by a wave counter. Neither is better; they answer different
questions. A wave counter gives you *discrete* steps you can balance one at a
time and announce to the player. A continuous function gives you a curve with no
seams, which is what an endless runner wants — there is no moment to announce.

Two details that only show up once the curve is continuous:

- **Rows arrive on a distance clock, not a wall clock.** `$nextRow` is a
  distance, not a timer. On a time interval a faster board would space
  components *further apart* — the game would get easier as it sped up.
- **The capacitor flips on a wall clock, deliberately breaking that rule.** Its
  1.35s period is real seconds, so a faster board gives you *fewer* flips to
  read on approach rather than the same number compressed. One clock in the
  engine is in the other unit, and that is the point of it.

---

## Summary

| Question | Answer here |
|---|---|
| Row generated fairly, still unplayable? | Reachability is a property of the *sequence*. Validate across rows, or make it impossible by construction |
| Generate-and-validate, or generate-correct? | Correct by construction: no retry loop, no failure branch, one global and a bit test |
| Where does a reward go? | Near enough to compete with the safe option. Uniformly random is a lottery, not a decision |
| Is the tension real? | Measure it. The greedy pilot should take more hits *and* last longer — if only one moves, the reward is broken |
| Hitbox width? | One equation with the lane width and the slide. Not a styling choice |
| Levels or a curve? | A counter gives balanceable steps to announce; `f(distance)` gives a seamless ramp. An endless runner has nothing to announce |

---

← [Giving each entity its own intent](20-per-entity-intent.md) · [Contents](README.md) · next: [The engine that owns time](22-engine-owned-time.md) · [Glossary](glossary.md)
