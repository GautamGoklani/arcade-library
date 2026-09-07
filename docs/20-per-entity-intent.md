# 20 · Case study: giving each entity its own intent

← [Pools that grow their own contents](19-pools-that-grow.md) · [Contents](README.md) · [Glossary](glossary.md)

---

Pixel Wave's swarm moves as a body. Every bot shares one patrol, and the
formation is the behaviour — which is why [chapter 16](16-entity-pools.md)
could describe its bot record as mostly *position*, with a `wanderTimer` and a
`cooldown` bolted on.

[Sector Defense](../games/sector-defense/) puts the behaviour in the record
instead. Each attacker holds a target column it is walking toward and a clock
saying when it next shoots, and the wave has no state of its own at all. This
chapter is about what that costs in memory, why it makes a formation
unpredictable without making any single attacker unfair, and one design
decision it enabled: an engine with no lives in it.

Read it with
[`games/sector-defense/game.wat`](../games/sector-defense/game.wat) open.

---

## Intent is two fields

The whole of an attacker's mind:

```wat
;; enemies  @16   : stride 40, MAX_ENEMIES = 24
;;                  x, y, vx, vy, hp, kind, active, phase, cd, targetX
```

`targetX` is where it is going. `cd` is how long until it fires. Everything
else is the same position-and-liveness a bullet has.

Per frame, the entire decision is:

```wat
;; arrived? pick somewhere new
(if (f32.lt (f32.abs (f32.sub (local.get $x) (local.get $tx))) (f32.const 10.0))
  (then
    (f32.store offset=36 (local.get $a)
      (call $frand (global.get $MARGIN) (f32.sub (global.get $WORLD_W) (global.get $MARGIN))))
    ...))
;; then walk toward it
(if (f32.gt (local.get $tx) (local.get $x))
  (then (local.set $x (f32.add (local.get $x) (f32.mul (local.get $lat) (local.get $dt)))))
  (else (local.set $x (f32.sub (local.get $x) (f32.mul (local.get $lat) (local.get $dt))))))
```

Eight bytes of state and a comparison, and the wave stops being a formation.

**The cost is honest and small.** Stride went from 32 to 40 bytes — 24
attackers is 960 bytes rather than 768, on a 65,536-byte page. That is the
trade this pattern always offers: per-entity behaviour costs per-entity memory,
and in a fixed pool you pay it for every slot whether or not it is occupied.
With 24 slots that is 192 bytes for a wave that is never fully populated. With
24,000 it would be the design's central problem, and the answer would be a
different one — behaviour indices into a shared table, or a separate array only
for the entities that need it.

---

## Unpredictable is not random

The interesting property is not that attackers move randomly. It is that they
move **in straight lines you can see, and change their minds at moments you
cannot predict.** Those are different things, and only one of them is fair.

Compare two ways to get an "unpredictable" attacker:

```wat
;; (a) a new velocity every frame — genuinely random, and unplayable
(f32.store offset=8 (local.get $a) (call $frand (f32.const -120.0) (f32.const 120.0)))

;; (b) a target, walked toward at a fixed speed, re-rolled on arrival
(if (f32.lt (f32.abs (f32.sub (local.get $x) (local.get $tx))) (f32.const 10.0)) ... )
```

(a) produces jitter. Nothing about it can be anticipated, so nothing about it
can be played against — the player's only strategy is to be lucky. (b) produces
motion that is locally *completely* predictable: at any instant, an attacker is
travelling at a known speed toward a point you can infer from its heading. What
you cannot predict is when it arrives and re-rolls.

The variations between kinds are all variations on *when the mind changes*,
not on how the body moves:

```wat
;; a weaver also re-rolls at random, ~0.9 times a second
(if (f32.lt (call $rand_f32) (f32.mul (f32.const 0.9) (local.get $dt)))
  (then (f32.store offset=36 ... )))
```

> **A note on that test.** `rand() < rate * dt` is the standard way to express
> "about `rate` times a second" in a per-frame loop, and it is *frame-rate
> independent* to first order — halve `dt` and you halve the chance per frame,
> so the expected number of events per second is unchanged. It is not exact
> (the true form is `1 - exp(-rate*dt)`), but at the frame times a browser
> produces the difference is far below anything a player could perceive.

Only the diver reacts to the player at all, and it does so with a single
comparison:

```wat
(if (f32.lt (f32.abs (f32.sub (local.get $x) (call $player_x))) (f32.const 52.0))
  (then (local.set $vy (f32.mul (call $descent_speed) (global.get $DIVE_MUL))))
  (else (local.set $vy (call $descent_speed))))
```

One attacker in four that responds to where you are is enough to make the whole
field feel attentive. Four kinds that all did it would feel like being hunted
by one mind with four bodies, which is the thing per-entity intent was supposed
to avoid.

---

## Two meters instead of lives

Every other engine in this repository has a life counter and a respawn. This
one has neither, and the defender cannot be destroyed:

```wat
(global $shield (mut f32) (f32.const 100.0))
(global $sector (mut f32) (f32.const 100.0))
```

A hit lands on the shield if there is any left, and on the sector if there is
not:

```wat
(func $take_hit
  (global.set $calm (f32.const 0.0))
  (global.set $combo (f32.const 0.0))
  ...
  (if (f32.gt (global.get $shield) (f32.const 0.0))
    (then (global.set $shield (... subtract SHIELD_HIT ...)))
    (else (call $damage_sector (global.get $LEAK_DAMAGE)))))
```

Three things follow, and they are worth noticing because they are all
*absences*:

- **No respawn.** No invulnerability window, no re-placement, no "where does
  the player go back to" question. Compare `$die` in
  [asteroid-miner](../games/asteroid-miner/game.wat), which has to spill cargo,
  reposition the ship, refill the tank and start a blink timer.
- **No death frame.** Nothing in the renderer has to handle "the player is
  currently not there", which in a lives-based game is a surprising amount of
  the presentation code.
- **Damage is continuous rather than discrete.** A partial shield still absorbs
  a whole hit — deliberately, because a shield that let some through would make
  the player track two numbers to predict one outcome — but the *sector* takes
  real numbers, so "how close am I to losing" is a proportion rather than a
  count of three.

The regeneration delay is where the design actually lives:

```wat
(func $step_shield (param $dt f32)
  (global.set $calm (f32.add (global.get $calm) (local.get $dt)))
  (if (f32.gt (global.get $calm) (global.get $SHIELD_DELAY))
    (then (global.set $shield (... add SHIELD_REGEN * dt ...)))))
```

`$calm` is reset by every hit, so pressure suppresses recovery for exactly as
long as the pressure lasts. That single line converts "do not get hit" — a
reflex — into "break contact and recover" — a decision. It is the same shape as
Asteroid Miner's fuel: a resource whose *rate of change* is the thing the
player is really managing.

---

## The combo is a resource with a decay, not a counter

The obvious implementation of a combo is an integer that increments on a kill
and resets on a miss. This one is a value with a clock:

```wat
(if (f32.gt (global.get $comboTimer) (f32.const 0.0))
  (then
    (global.set $comboTimer (f32.sub (global.get $comboTimer) (local.get $d)))
    (if (f32.le (global.get $comboTimer) (f32.const 0.0))
      (then (global.set $combo (f32.const 0.0))))))
```

Letting the window lapse costs the streak exactly as surely as being hit does,
which means the multiplier measures *pressure maintained* rather than accuracy.
It is a small change with a large effect on how the game is played: the
scoreboard now rewards moving toward the fight.

One detail worth copying: the score for a kill is paid at the multiplier the
streak had **before** that kill extended it.

```wat
(call $add_score (f32.mul (global.get $SCORE_KILL) (call $multiplier)))
(global.set $combo (... combo + 1 ...))
```

Pay first, then increment. The first kill of a streak is worth 1×, so the bonus
is unambiguously for *keeping one going* rather than for starting one — and the
number the HUD showed a moment before the kill is the number the player was
paid.

---

## Summary

| Question | Answer here |
|---|---|
| Where does behaviour live? | In the entity record — a target and a clock, 8 bytes |
| What does that cost? | Stride 32 → 40; you pay it for every slot, occupied or not |
| When is that the wrong trade? | At tens of thousands of entities — then share a behaviour table instead |
| How do you make motion unpredictable but fair? | Straight lines the player can read, changing at moments they cannot predict |
| "About N times a second" in a frame loop? | `rand() < N * dt` — frame-rate independent to first order |
| How many kinds should react to the player? | Here, one in four. All four would read as a single mind with four bodies |
| What replaces lives? | Two meters, and a regeneration delay that turns a reflex into a decision |
| How should a combo end? | On a clock, so the multiplier measures pressure rather than accuracy |

---

← [Pools that grow their own contents](19-pools-that-grow.md) · [Contents](README.md) · [Glossary](glossary.md) · [Further reading](further-reading.md)
