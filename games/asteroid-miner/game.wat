(module
  ;; ============================================================
  ;; ASTEROID MINER — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as pixel-wave/game.wat,
  ;; grid-breaker/game.wat and worm-chase/game.wat (globals block at the top,
  ;; entity pools at fixed offsets in linear memory, xorshift RNG, an
  ;; init/set_input/step/get_* export surface) and nothing else. Every constant
  ;; and every routine below is its own.
  ;;
  ;; What is new here, and what the rest of the library did not need:
  ;;
  ;;   • Entities that spawn entities. A shot rock becomes two smaller rocks,
  ;;     and the smallest becomes cargo. Nothing recurses — a split writes into
  ;;     the same pool the loop is already walking.
  ;;   • Resource state. Fuel and cargo are the game: thrust burns one, mining
  ;;     fills the other, and only the depot converts either into progress.
  ;;   • A second currency. Every gem the depot takes is also banked as
  ;;     credit, and credit buys the ship a bigger hold, a bigger tank or a
  ;;     replacement hull — see "the depot's refit" below.
  ;;
  ;; JavaScript owns no game state. It forwards input, calls step(dt), and
  ;; reads entity records straight out of the memory below to draw them.
  ;; ============================================================
  ;; sin/cos are imported because wasm has no instruction for them. sqrt is
  ;; not imported — f32.sqrt is native, so reaching out to JS for it would be
  ;; slower and pointless.
  (import "env" "sinf" (func $sinf (param f32) (result f32)))
  (import "env" "cosf" (func $cosf (param f32) (result f32)))

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; ship     @0    : x, y, vx, vy, heading, alive            (6 f32 = 24 B)
  ;; rocks    @24   : stride 32, MAX_ROCKS = 28
  ;;                  x, y, vx, vy, radius, size, active, spin
  ;;                  ends at 24 + 28*32 = 920
  ;; bullets  @920  : stride 24, MAX_BULLETS = 24
  ;;                  x, y, vx, vy, life, active
  ;;                  ends at 920 + 24*24 = 1496
  ;; pickups  @1496 : stride 32, MAX_PICKUPS = 40
  ;;                  x, y, vx, vy, life, kind, active, phase
  ;;                  ends at 1496 + 40*32 = 2776
  ;; depot    @2776 : x, y                                    (2 f32 = 8 B)
  ;;                  ends at 2784
  ;; rival    @2784 : x, y, vx, vy, active, cargo, stun, drill, tx, ty
  ;;                  (10 f32 = 40 B) ends at 2824
  ;;                  active is 1 working, 2 warping out; `drill` is seconds
  ;;                  into cutting the rock at (tx, ty), so the widget can
  ;;                  draw the beam and how far along it is
  ;;
  ;; rock sizes: 3 = boulder, 2 = chunk, 1 = pebble (a pebble does not split)
  ;; pickup kinds: 0 = gem (cargo), 1 = fuel cell, 2 = magnet, 3 = drill
  ;;
  ;; Scalars — score, lives, fuel, cargo — live in globals rather than memory,
  ;; as in worm-chase/game.wat: the get_* readers are the only consumer, and a
  ;; global is one instruction to read.
  ;;
  ;; The field lists above, once more, in the form scripts/check-layout.mjs
  ;; reads. It fails if any line here disagrees with the prose, overflows
  ;; its stride, or disagrees with the FIELD table at the top of the widget
  ;; — so a field that moves has to move in all three places at once.
  ;; @fields ship   f32 -: x y vx vy heading alive
  ;; @fields rock   f32 ROCK_STRIDE: x y vx vy radius size active spin
  ;; @fields bullet f32 BULLET_STRIDE: x y vx vy life active
  ;; @fields pickup f32 PICKUP_STRIDE: x y vx vy life kind active phase
  ;; @fields depot  f32 -: x y
  ;; @fields rival  f32 -: x y vx vy active cargo stun drill tx ty
  ;; ===================================================

  (global $SHIP_OFF i32 (i32.const 0))
  (global $ROCKS_OFF i32 (i32.const 24))
  (global $ROCK_STRIDE i32 (i32.const 32))
  (global $MAX_ROCKS i32 (i32.const 28))
  (global $BULLETS_OFF i32 (i32.const 920))
  (global $BULLET_STRIDE i32 (i32.const 24))
  (global $MAX_BULLETS i32 (i32.const 24))
  (global $PICKUPS_OFF i32 (i32.const 1496))
  (global $PICKUP_STRIDE i32 (i32.const 32))
  (global $MAX_PICKUPS i32 (i32.const 40))
  (global $DEPOT_OFF i32 (i32.const 2776))
  (global $RIVAL_OFF i32 (i32.const 2784))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))
  (global $PI f32 (f32.const 3.14159265))
  (global $TAU f32 (f32.const 6.28318531))

  ;; ---- ship ----
  (global $SHIP_R f32 (f32.const 12.0))
  ;; Applied directly as a rate: heading += rot * ROT_SPEED * dt. Radians per
  ;; second, not an acceleration — the Pixel Wave reference document got this
  ;; wrong about its own engine and the mistake is worth not repeating.
  (global $ROT_SPEED f32 (f32.const 3.4))
  (global $THRUST_ACC f32 (f32.const 270.0))
  (global $MAX_SPEED f32 (f32.const 300.0))
  ;; There is no drag in space. There is drag here, because a Newtonian ship
  ;; with cargo to protect turns every trip home into a braking puzzle, and the
  ;; fuel budget is meant to be the thing the player is managing.
  (global $DRAG f32 (f32.const 0.42))
  (global $FIRE_CD f32 (f32.const 0.22))
  (global $BULLET_SPEED f32 (f32.const 470.0))
  (global $BULLET_LIFE f32 (f32.const 1.15))
  (global $INVULN_TIME f32 (f32.const 2.2))

  ;; ---- resources ----
  ;; Mutable because the refit raises it; init puts it back.
  (global $FUEL_MAX (mut f32) (f32.const 100.0))
  ;; Mutable because the difficulty table writes them — see $apply_difficulty.
  ;; The initialisers are Normal's values, which is what makes a Normal run
  ;; identical to the engine that had no settings at all.
  (global $FUEL_BURN (mut f32) (f32.const 8.5))       ;; per second of thrust
  (global $REFUEL_RATE f32 (f32.const 38.0))          ;; per second, docked
  (global $FUEL_CELL (mut f32) (f32.const 22.0))      ;; per cell picked up
  ;; The emergency reserve. A dry tank far from the depot used to be 75 seconds
  ;; of drifting with nothing to do but wait for a rock to hit you — the
  ;; headless bench measured exactly that. This trickles the tank back up to a
  ;; sliver: about 1.6 seconds of thrust, then a five-second wait for the next
  ;; sip. Running dry is meant to be a crawl home, not a dead run.
  (global $RESERVE_RATE f32 (f32.const 3.0))
  (global $RESERVE_CAP f32 (f32.const 14.0))
  (global $CARGO_MAX (mut f32) (f32.const 12.0))     ;; the refit raises this too
  (global $DELIVER_EVERY f32 (f32.const 0.11))  ;; seconds per gem unloaded
  (global $DEPOT_R f32 (f32.const 52.0))

  ;; ---- field ----
  (global $ROCK_R3 f32 (f32.const 42.0))
  (global $ROCK_R2 f32 (f32.const 25.0))
  (global $ROCK_R1 f32 (f32.const 14.0))
  (global $ROCK_SPEED (mut f32) (f32.const 26.0))
  (global $ROCK_SPEED_STEP (mut f32) (f32.const 4.0))
  (global $SPLIT_KICK f32 (f32.const 46.0))
  (global $PICKUP_LIFE f32 (f32.const 17.0))
  (global $PICKUP_R f32 (f32.const 9.0))
  (global $GRAB_R f32 (f32.const 26.0))
  (global $RESPAWN_EVERY f32 (f32.const 3.5))   ;; seconds between field top-ups

  ;; ---- power-ups ----
  ;; Two, and both are about the trip rather than the fight, because the
  ;; trip is what this game is made of.
  ;;
  ;;   MAGNET  pulls every gem and fuel cell within reach toward the ship.
  ;;           Chasing loot across a drifting field is where fuel goes, and
  ;;           where a ship with a full-ish hold meets the rock it did not see.
  ;;   DRILL   the "bigger drill": a shot mines a rock out whole. It pays every
  ;;           pebble the rock would have become — four for a boulder, two for
  ;;           a chunk — and leaves no fragments behind to ram you. Same yield
  ;;           as shooting it down the long way, a quarter of the shots, and a
  ;;           field that empties instead of filling up.
  ;;
  ;; They drop from mined pebbles, the moment the game already pays out at,
  ;; and the roll is on a random stream of its own ($rng2) as Pixel Wave's,
  ;; Worm Chase's and Sector Defense's are: a power-up that is never picked up
  ;; changes nothing about the field.
  (global $POWER_CHANCE f32 (f32.const 0.06))   ;; per pebble mined
  (global $MAGNET_TIME f32 (f32.const 12.0))
  (global $DRILL_TIME f32 (f32.const 10.0))
  (global $MAGNET_R f32 (f32.const 190.0))
  (global $MAGNET_PULL f32 (f32.const 240.0))   ;; px/s toward the ship
  (global $SCORE_POWER f32 (f32.const 50.0))

  ;; ---- the depot's refit ----
  ;; Every gem the depot takes counts toward the quota *and* is banked as one
  ;; credit, and credit is spent while docked, on three things:
  ;;
  ;;   HOLD   12 -> 16 -> 20 gems. Fewer trips home for the same quota.
  ;;   TANK   100 -> 135 -> 170 fuel. Longer trips, and a wider margin on the
  ;;          way back.
  ;;   HULL   one ship back — only when one has been lost, so it restores
  ;;          the starting count and never banks beyond it.
  ;;
  ;; What makes it a decision is that the three draw on one balance, and the
  ;; balance is small next to the menu: the hold and the tank fill the ship's
  ;; working life, a hull buys back a mistake, and there is not credit for all
  ;; of it early. The prices are below and the bench that settled them is in
  ;; the README.
  ;;
  ;; Credit is not the score and does not cost score. An earlier version paid
  ;; for a refit out of the level's quota instead, which read well on paper —
  ;; an upgrade cost you trips — and did not survive the drip at the depot: a
  ;; ship docking with a hold bigger than what the quota still wanted finished
  ;; the level in under a second, before anyone could press a key. A separate
  ;; balance can be spent on any visit, including the one a respawn starts at.
  ;;
  ;; The hold's surplus is banked too. When a level's last gem goes in, what is
  ;; still in the hold used to be wiped by the next level's reset; it now goes
  ;; to the bank, so the gems a player carried past the quota are not wasted.
  (global $HOLD_STEP f32 (f32.const 4.0))
  (global $TANK_STEP f32 (f32.const 35.0))
  (global $TIER_MAX i32 (i32.const 2))
  (global $PRICE_T1 i32 (i32.const 8))       ;; hold or tank, first tier
  (global $PRICE_T2 i32 (i32.const 16))      ;; ... second
  (global $PRICE_HULL i32 (i32.const 12))
  (global $PRICE_HULL_STEP i32 (i32.const 8))   ;; dearer by this for each one bought

  ;; ---- the rival ----
  ;; The boss column of the per-game menu said this title's boss was a maybe,
  ;; and that *a rival miner working the same rocks* fitted it better than
  ;; anything with a health bar. This is that, and it is deliberately not a
  ;; threat to the ship: it cannot ram you and it never shoots at you. It is
  ;; a competitor for the one thing the level asks for.
  ;;
  ;; On every $RIVAL_EVERY-th level it warps in $RIVAL_DELAY seconds after
  ;; the start, on the far side of the field from the depot, and goes to work:
  ;; the nearest loose gem if there is one in sight, otherwise the nearest
  ;; rock, which it holds station beside and cuts apart in $RIVAL_DRILL
  ;; seconds. A rock it cuts splits exactly as a shot one does — the same
  ;; function — except that nothing it mines scores for the player. It keeps
  ;; what it collects, and when its hold holds $RIVAL_CAP it warps out with
  ;; them.
  ;;
  ;; So it is a race, and it is also a lode. Shoot it and **its whole hold
  ;; spills** where it is, as loose gems, and it is stunned for $RIVAL_STUN
  ;; seconds, drifting. Three hits drive it off for good ($SCORE_RIVAL). The
  ;; decision it asks is *when*: early, and it has little to spill; late, and
  ;; it has done the mining for you — if it has not warped out first.
  ;;
  ;; It is slower than the ship (a steering rate, not a thruster: it has no
  ;; fuel to manage), passes through rocks, and draws nothing from $rng: where
  ;; it arrives is the depot's opposite, and everything after is steering. The
  ;; rocks it cuts do draw, as any split does, so levels before the first
  ;; rival replay the engine without one exactly and levels after do not.
  (global $RIVAL_EVERY i32 (i32.const 3))
  (global $RIVAL_DELAY f32 (f32.const 5.0))
  (global $RIVAL_SPEED f32 (f32.const 150.0))    ;; the ship's cap is 300
  (global $RIVAL_ACC f32 (f32.const 260.0))
  (global $RIVAL_SIGHT f32 (f32.const 360.0))    ;; how far it will go for a gem
  (global $RIVAL_REACH f32 (f32.const 120.0))    ;; drilling range, centre to centre
  (global $RIVAL_DRILL f32 (f32.const 1.1))      ;; seconds to cut one rock
  (global $RIVAL_CAP f32 (f32.const 10.0))
  (global $RIVAL_R f32 (f32.const 16.0))
  (global $RIVAL_STUN f32 (f32.const 2.5))
  (global $RIVAL_WARP f32 (f32.const 1.2))       ;; seconds to warp out
  (global $RIVAL_HP i32 (i32.const 3))
  (global $SCORE_RIVAL f32 (f32.const 150.0))
  (global $RIVAL_CLAIM i32 (i32.const 5))       ;; quota added if it gets away full

  ;; ---- scoring ----
  (global $SCORE_SPLIT f32 (f32.const 5.0))
  (global $SCORE_PEBBLE f32 (f32.const 15.0))
  (global $SCORE_GEM f32 (f32.const 25.0))
  (global $SCORE_LEVEL f32 (f32.const 200.0))
  (global $START_LIVES (mut f32) (f32.const 4.0))

  ;; ---- difficulty ---------------------------------------------------------
  ;; Easy / Normal / Hard. The widget calls set_difficulty(d) and then init();
  ;; init() copies one column of this table into the globals below, and the rest
  ;; of the engine reads only those.
  ;;
  ;;                             easy       normal      hard
  ;;   starting lives              5          4           3
  ;;   fuel burn (per s thrust)   6.5        8.5        10.5
  ;;   a fuel cell is worth        28         22          18
  ;;   boulders in the field     1+lvl      2+lvl       3+lvl
  ;;   ... floor / cap            2 / 8      3 / 10      4 / 12
  ;;   gems the level asks for   2 + 2/lvl  3 + 3/lvl   4 + 4/lvl
  ;;   rock speed               22 + 3/lvl  26 + 4/lvl  31 + 5/lvl
  ;;
  ;; The three knobs TASKS.md named are fuel burn, rock density and the quota.
  ;; Rock speed came with density because the two together are what "a busier
  ;; field" means here — more rocks moving at the same crawl reads as clutter
  ;; rather than as pressure. A fuel cell's worth is in the table with the burn
  ;; rate for the same reason: the burn rate alone changes how long a tank
  ;; lasts, and the cell is what decides whether the field can pay for it.
  ;;
  ;; Three things are deliberately *not* in the table. $DRAG and $ROT_SPEED are
  ;; the feel of the ship rather than the challenge, and a barge on Easy would
  ;; be a different game to learn on. And $RESERVE_RATE / $RESERVE_CAP stay put
  ;; on every setting: the reserve exists to stop a dry tank being 75 seconds of
  ;; nothing to do, which is a dead-time bug, not a difficulty.
  ;;
  ;; $difficulty is not reset by init: it is a choice about the next run, so a
  ;; restart has to carry it rather than wipe it — chapter 8's argument for $rng.
  (global $difficulty (mut i32) (i32.const 1))   ;; 0 easy, 1 normal, 2 hard
  (global $ROCK_BASE (mut i32) (i32.const 2))
  (global $ROCK_MIN (mut i32) (i32.const 3))
  (global $ROCK_CAP (mut i32) (i32.const 10))
  (global $QUOTA_BASE (mut i32) (i32.const 3))
  (global $QUOTA_STEP (mut i32) (i32.const 3))

  (global $rng (mut i32) (i32.const 1103515245))
  (global $rng2 (mut i32) (i32.const 521288629))   ;; power-ups only
  (global $magnetT (mut f32) (f32.const 0.0))
  (global $drillT (mut f32) (f32.const 0.0))
  (global $level (mut i32) (i32.const 1))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $lives (mut f32) (f32.const 4.0))
  (global $fuel (mut f32) (f32.const 100.0))
  (global $cargo (mut f32) (f32.const 0.0))
  (global $delivered (mut i32) (i32.const 0))
  (global $quota (mut i32) (i32.const 8))
  (global $credit (mut i32) (i32.const 0))      ;; banked gems, spent at the depot
  (global $holdTier (mut i32) (i32.const 0))
  (global $tankTier (mut i32) (i32.const 0))
  (global $hullsBought (mut i32) (i32.const 0))
  (global $docked (mut i32) (i32.const 0))
  (global $rivalT (mut f32) (f32.const -1.0))   ;; seconds to its arrival; <0 none due
  (global $rivalHp (mut i32) (i32.const 0))
  (global $byRival (mut i32) (i32.const 0))     ;; a split in progress is the rival's

  ;; input, as reported by set_input each frame
  (global $rotIn (mut f32) (f32.const 0.0))
  (global $thrustIn (mut i32) (i32.const 0))
  (global $fireIn (mut i32) (i32.const 0))
  (global $aimOn (mut i32) (i32.const 0))
  (global $aimAng (mut f32) (f32.const 0.0))
  ;; 0 nothing, 1 hold, 2 tank, 3 hull. The widget sends a press for exactly
  ;; one frame, the way Tower Defense's widget sends its verbs, so a held key
  ;; buys once rather than draining the bank at sixty purchases a second.
  (global $buyIn (mut i32) (i32.const 0))

  ;; timers
  (global $fireCd (mut f32) (f32.const 0.0))
  (global $invuln (mut f32) (f32.const 0.0))
  (global $deliverAcc (mut f32) (f32.const 0.0))
  (global $respawnAcc (mut f32) (f32.const 0.0))
  (global $thrusting (mut i32) (i32.const 0))   ;; for the renderer's flame

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $shots (mut i32) (i32.const 0))
  (global $hits (mut i32) (i32.const 0))
  (global $grabs (mut i32) (i32.const 0))
  (global $fuels (mut i32) (i32.const 0))
  (global $drops (mut i32) (i32.const 0))       ;; gems unloaded at the depot
  (global $deaths (mut i32) (i32.const 0))
  (global $powerDrops (mut i32) (i32.const 0))  ;; a power-up fell out of a pebble
  (global $powers (mut i32) (i32.const 0))      ;; a power-up picked up
  (global $refits (mut i32) (i32.const 0))      ;; anything bought at the depot
  (global $rivals (mut i32) (i32.const 0))      ;; a rival warped in
  (global $rivalHits (mut i32) (i32.const 0))   ;; a round struck it (and it spilled)
  (global $rivalTakes (mut i32) (i32.const 0))  ;; it picked up a gem
  (global $rivalRouts (mut i32) (i32.const 0))  ;; driven off by the third hit
  (global $rivalEscapes (mut i32) (i32.const 0)) ;; warped out with a full hold

  ;; ---------------- helpers ----------------

  (func $rock_addr (param $i i32) (result i32)
    (i32.add (global.get $ROCKS_OFF) (i32.mul (local.get $i) (global.get $ROCK_STRIDE))))
  (func $bullet_addr (param $i i32) (result i32)
    (i32.add (global.get $BULLETS_OFF) (i32.mul (local.get $i) (global.get $BULLET_STRIDE))))
  (func $pickup_addr (param $i i32) (result i32)
    (i32.add (global.get $PICKUPS_OFF) (i32.mul (local.get $i) (global.get $PICKUP_STRIDE))))

  (func $rand_f32 (result f32)
    (local $x i32)
    (local.set $x (global.get $rng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng (local.get $x))
    (f32.div (f32.convert_i32_u (local.get $x)) (f32.const 4294967296.0)))

  ;; The same xorshift on the power-up's own state; a draw here never moves $rng.
  (func $rand2 (result f32)
    (local $x i32)
    (local.set $x (global.get $rng2))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng2 (local.get $x))
    (f32.div (f32.convert_i32_u (local.get $x)) (f32.const 4294967296.0)))

  (func $frand (param $lo f32) (param $hi f32) (result f32)
    (f32.add (local.get $lo) (f32.mul (call $rand_f32) (f32.sub (local.get $hi) (local.get $lo)))))

  (func $clampf (param $v f32) (param $lo f32) (param $hi f32) (result f32)
    (local $r f32)
    (local.set $r (local.get $v))
    (if (f32.lt (local.get $r) (local.get $lo)) (then (local.set $r (local.get $lo))))
    (if (f32.gt (local.get $r) (local.get $hi)) (then (local.set $r (local.get $hi))))
    (local.get $r))

  (func $clampi (param $v i32) (param $lo i32) (param $hi i32) (result i32)
    (local $r i32)
    (local.set $r (local.get $v))
    (if (i32.lt_s (local.get $r) (local.get $lo)) (then (local.set $r (local.get $lo))))
    (if (i32.gt_s (local.get $r) (local.get $hi)) (then (local.set $r (local.get $hi))))
    (local.get $r))

  ;; The arena wraps. `v - W * floor(v / W)` lands anywhere in one expression,
  ;; including for the large overshoots a paused tab can produce, where the
  ;; usual pair of `if (v < 0) v += W` tests would only fix one lap of it.
  (func $wrapf (param $v f32) (param $w f32) (result f32)
    (f32.sub (local.get $v)
      (f32.mul (local.get $w) (f32.floor (f32.div (local.get $v) (local.get $w))))))

  ;; Normalise an angle into [-PI, PI], by the same trick.
  (func $wrap_ang (param $a f32) (result f32)
    (f32.sub (local.get $a)
      (f32.mul (global.get $TAU)
        (f32.floor (f32.div (f32.add (local.get $a) (global.get $PI)) (global.get $TAU))))))

  ;; Shortest wrapped distance on one axis. Without this a rock at x=950 and a
  ;; ship at x=10 are 940 apart, and nothing at the seam ever collides.
  (func $ddist (param $a f32) (param $b f32) (param $w f32) (result f32)
    (local $d f32)
    (local.set $d (f32.abs (f32.sub (local.get $a) (local.get $b))))
    (if (f32.gt (local.get $d) (f32.mul (local.get $w) (f32.const 0.5)))
      (then (local.set $d (f32.sub (local.get $w) (local.get $d)))))
    (local.get $d))

  ;; Squared wrapped distance between two points. Squared, because comparing
  ;; against a squared radius avoids a sqrt in the hot loops.
  (func $dist2 (param $ax f32) (param $ay f32) (param $bx f32) (param $by f32) (result f32)
    (local $dx f32) (local $dy f32)
    (local.set $dx (call $ddist (local.get $ax) (local.get $bx) (global.get $WORLD_W)))
    (local.set $dy (call $ddist (local.get $ay) (local.get $by) (global.get $WORLD_H)))
    (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy))))

  (func $radius_for (param $size i32) (result f32)
    (if (result f32) (i32.eq (local.get $size) (i32.const 3))
      (then (global.get $ROCK_R3))
      (else (if (result f32) (i32.eq (local.get $size) (i32.const 2))
        (then (global.get $ROCK_R2))
        (else (global.get $ROCK_R1))))))

  (func $rock_speed (result f32)
    (f32.add (global.get $ROCK_SPEED)
      (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
               (global.get $ROCK_SPEED_STEP))))

  ;; Nothing the rival mines is the player's to score.
  (func $add_score (param $n f32)
    (if (global.get $byRival) (then (return)))
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  (func $depot_x (result f32) (f32.load (global.get $DEPOT_OFF)))
  (func $depot_y (result f32) (f32.load offset=4 (global.get $DEPOT_OFF)))

  ;; ---------------- spawning ----------------

  (func $spawn_rock (param $x f32) (param $y f32) (param $size i32)
                    (param $vx f32) (param $vy f32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (local.get $vx))
            (f32.store offset=12 (local.get $a) (local.get $vy))
            (f32.store offset=16 (local.get $a) (call $radius_for (local.get $size)))
            (f32.store offset=20 (local.get $a) (f32.convert_i32_s (local.get $size)))
            (f32.store offset=24 (local.get $a) (f32.const 1.0))
            (f32.store offset=28 (local.get $a) (call $frand (f32.const -1.6) (f32.const 1.6)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; A boulder somewhere on the field, never on top of the depot — a rock that
  ;; materialised inside the one safe place would kill a docked ship that had
  ;; done nothing wrong.
  ;; How many boulders this level wants. $build_level seeds the field with it
  ;; and $step tops the field back up to it, so it lives in one function — two
  ;; copies of the same arithmetic is exactly the pair that drifts apart when
  ;; the difficulty table moves one of them.
  (func $field_rocks (result i32)
    (call $clampi (i32.add (global.get $ROCK_BASE) (global.get $level))
                  (global.get $ROCK_MIN) (global.get $ROCK_CAP)))

  (func $spawn_drifter
    (local $x f32) (local $y f32) (local $ang f32) (local $sp f32) (local $tries i32)
    (local.set $tries (i32.const 0))
    (block $placed
      (loop $lp
        (br_if $placed (i32.gt_s (local.get $tries) (i32.const 40)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        (local.set $x (call $frand (f32.const 0.0) (global.get $WORLD_W)))
        (local.set $y (call $frand (f32.const 0.0) (global.get $WORLD_H)))
        (br_if $lp (f32.lt (call $dist2 (local.get $x) (local.get $y)
                                        (call $depot_x) (call $depot_y))
                           (f32.const 48400.0)))     ;; 220px, squared
        ;; ... and never on top of the ship, for the same reason. This check
        ;; arrived late: the field is topped up every 3.5 s wherever there is
        ;; room, and on Hard 4 of 36 deaths in a bench came within 0.6 s of a
        ;; boulder appearing within 150 px of a ship that had not moved into
        ;; it. The drill, which removes rocks whole and so calls for more
        ;; top-ups, made it worse, and that is how it was found. 140 rather
        ;; than the depot's 220: at 220 the competent pilot mined fewer gems,
        ;; because top-ups near the ship were also the rocks it mined next.
        ;; 140 is about a second of a boulder's travel, and moved nothing else.
        (br_if $lp (f32.lt (call $dist2 (local.get $x) (local.get $y)
                                        (f32.load offset=0 (global.get $SHIP_OFF))
                                        (f32.load offset=4 (global.get $SHIP_OFF)))
                           (f32.const 19600.0)))     ;; 140px, squared
        (br $placed)))
    (local.set $ang (call $frand (f32.const 0.0) (global.get $TAU)))
    (local.set $sp (call $frand (f32.mul (call $rock_speed) (f32.const 0.6)) (call $rock_speed)))
    (call $spawn_rock (local.get $x) (local.get $y) (i32.const 3)
      (f32.mul (call $sinf (local.get $ang)) (local.get $sp))
      (f32.mul (call $cosf (local.get $ang)) (local.get $sp))))

  (func $spawn_pickup (param $x f32) (param $y f32) (param $kind i32)
    (local $i i32) (local $a i32) (local $ang f32) (local $sp f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
        (local.set $a (call $pickup_addr (local.get $i)))
        (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $ang (call $frand (f32.const 0.0) (global.get $TAU)))
            (local.set $sp (call $frand (f32.const 14.0) (f32.const 52.0)))
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
            (f32.store offset=12 (local.get $a) (f32.mul (call $cosf (local.get $ang)) (local.get $sp)))
            (f32.store offset=16 (local.get $a) (global.get $PICKUP_LIFE))
            (f32.store offset=20 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=24 (local.get $a) (f32.const 1.0))
            (f32.store offset=28 (local.get $a) (call $frand (f32.const 0.0) (global.get $TAU)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; A power-up capsule, placed and set drifting entirely from $rng2, so that
  ;; spawning one leaves the main stream exactly where it was.
  (func $spawn_power (param $x f32) (param $y f32)
    (local $i i32) (local $a i32) (local $ang f32) (local $sp f32)
    (global.set $powerDrops (i32.add (global.get $powerDrops) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
        (local.set $a (call $pickup_addr (local.get $i)))
        (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $ang (f32.mul (call $rand2) (global.get $TAU)))
            (local.set $sp (f32.add (f32.const 14.0) (f32.mul (call $rand2) (f32.const 30.0))))
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
            (f32.store offset=12 (local.get $a) (f32.mul (call $cosf (local.get $ang)) (local.get $sp)))
            (f32.store offset=16 (local.get $a) (global.get $PICKUP_LIFE))
            (f32.store offset=20 (local.get $a)
              (if (result f32) (f32.lt (call $rand2) (f32.const 0.5))
                (then (f32.const 2.0)) (else (f32.const 3.0))))
            (f32.store offset=24 (local.get $a) (f32.const 1.0))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- the ship ----------------

  (func $place_ship_at_depot
    (f32.store offset=0 (global.get $SHIP_OFF) (call $depot_x))
    (f32.store offset=4 (global.get $SHIP_OFF) (call $depot_y))
    (f32.store offset=8 (global.get $SHIP_OFF) (f32.const 0.0))
    (f32.store offset=12 (global.get $SHIP_OFF) (f32.const 0.0))
    (f32.store offset=16 (global.get $SHIP_OFF) (f32.const 0.0))
    (f32.store offset=20 (global.get $SHIP_OFF) (f32.const 1.0))
    (global.set $invuln (global.get $INVULN_TIME))
    (global.set $fireCd (f32.const 0.0)))

  (func $fire
    (local $i i32) (local $a i32) (local $h f32)
    (if (f32.gt (global.get $fireCd) (f32.const 0.0)) (then (return)))
    (local.set $h (f32.load offset=16 (global.get $SHIP_OFF)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
        (local.set $a (call $bullet_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a)
              (f32.add (f32.load offset=0 (global.get $SHIP_OFF))
                       (f32.mul (call $sinf (local.get $h)) (global.get $SHIP_R))))
            (f32.store offset=4 (local.get $a)
              (f32.sub (f32.load offset=4 (global.get $SHIP_OFF))
                       (f32.mul (call $cosf (local.get $h)) (global.get $SHIP_R))))
            ;; The ship's own velocity is added to the shot. A miner that
            ;; sprints past a boulder and fires would otherwise watch its own
            ;; bullets fall behind it.
            (f32.store offset=8 (local.get $a)
              (f32.add (f32.mul (call $sinf (local.get $h)) (global.get $BULLET_SPEED))
                       (f32.load offset=8 (global.get $SHIP_OFF))))
            (f32.store offset=12 (local.get $a)
              (f32.add (f32.mul (call $cosf (local.get $h)) (f32.neg (global.get $BULLET_SPEED)))
                       (f32.load offset=12 (global.get $SHIP_OFF))))
            (f32.store offset=16 (local.get $a) (global.get $BULLET_LIFE))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (global.set $fireCd (global.get $FIRE_CD))
            (global.set $shots (i32.add (global.get $shots) (i32.const 1)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $step_ship (param $dt f32)
    (local $h f32) (local $d f32) (local $step f32)
    (local $vx f32) (local $vy f32) (local $sp f32) (local $k f32)

    (local.set $h (f32.load offset=16 (global.get $SHIP_OFF)))

    ;; Two steering schemes, arbitrated the way Grid Breaker arbitrates mouse
    ;; against keys: whichever spoke last wins, and they can never both apply.
    ;; The stick names an absolute heading; the keys name a rate. Even the
    ;; stick turns at ROT_SPEED rather than snapping, so a thumb flick and a
    ;; key press produce the same ship.
    (if (i32.ne (global.get $aimOn) (i32.const 0))
      (then
        (local.set $d (call $wrap_ang (f32.sub (global.get $aimAng) (local.get $h))))
        (local.set $step (f32.mul (global.get $ROT_SPEED) (local.get $dt)))
        (if (f32.le (f32.abs (local.get $d)) (local.get $step))
          (then (local.set $h (global.get $aimAng)))
          (else
            (if (f32.gt (local.get $d) (f32.const 0.0))
              (then (local.set $h (f32.add (local.get $h) (local.get $step))))
              (else (local.set $h (f32.sub (local.get $h) (local.get $step))))))))
      (else
        (local.set $h (f32.add (local.get $h)
          (f32.mul (f32.mul (global.get $rotIn) (global.get $ROT_SPEED)) (local.get $dt))))))
    (f32.store offset=16 (global.get $SHIP_OFF) (call $wrap_ang (local.get $h)))

    (local.set $vx (f32.load offset=8 (global.get $SHIP_OFF)))
    (local.set $vy (f32.load offset=12 (global.get $SHIP_OFF)))

    ;; Thrust costs fuel, and an empty tank is a dead engine. Getting home is
    ;; the player's problem — though a rock to the hull is always an exit.
    (global.set $thrusting (i32.const 0))
    (if (i32.and (i32.ne (global.get $thrustIn) (i32.const 0))
                 (f32.gt (global.get $fuel) (f32.const 0.0)))
      (then
        (global.set $thrusting (i32.const 1))
        (local.set $vx (f32.add (local.get $vx)
          (f32.mul (f32.mul (call $sinf (local.get $h)) (global.get $THRUST_ACC)) (local.get $dt))))
        (local.set $vy (f32.sub (local.get $vy)
          (f32.mul (f32.mul (call $cosf (local.get $h)) (global.get $THRUST_ACC)) (local.get $dt))))
        (global.set $fuel
          (call $clampf (f32.sub (global.get $fuel) (f32.mul (global.get $FUEL_BURN) (local.get $dt)))
                        (f32.const 0.0) (global.get $FUEL_MAX)))))

    (if (f32.lt (global.get $fuel) (global.get $RESERVE_CAP))
      (then (global.set $fuel (call $clampf
        (f32.add (global.get $fuel) (f32.mul (global.get $RESERVE_RATE) (local.get $dt)))
        (f32.const 0.0) (global.get $RESERVE_CAP)))))

    ;; Drag, then a hard speed cap. Drag alone cannot hold a ceiling that the
    ;; player can feel; the cap alone makes the ship handle like ice.
    (local.set $k (call $clampf
      (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))
      (f32.const 0.0) (f32.const 1.0)))
    (local.set $vx (f32.mul (local.get $vx) (local.get $k)))
    (local.set $vy (f32.mul (local.get $vy) (local.get $k)))
    (local.set $sp (f32.sqrt
      (f32.add (f32.mul (local.get $vx) (local.get $vx)) (f32.mul (local.get $vy) (local.get $vy)))))
    (if (f32.gt (local.get $sp) (global.get $MAX_SPEED))
      (then
        (local.set $k (f32.div (global.get $MAX_SPEED) (local.get $sp)))
        (local.set $vx (f32.mul (local.get $vx) (local.get $k)))
        (local.set $vy (f32.mul (local.get $vy) (local.get $k)))))

    (f32.store offset=8 (global.get $SHIP_OFF) (local.get $vx))
    (f32.store offset=12 (global.get $SHIP_OFF) (local.get $vy))
    (f32.store offset=0 (global.get $SHIP_OFF)
      (call $wrapf (f32.add (f32.load offset=0 (global.get $SHIP_OFF))
                            (f32.mul (local.get $vx) (local.get $dt))) (global.get $WORLD_W)))
    (f32.store offset=4 (global.get $SHIP_OFF)
      (call $wrapf (f32.add (f32.load offset=4 (global.get $SHIP_OFF))
                            (f32.mul (local.get $vy) (local.get $dt))) (global.get $WORLD_H)))

    (if (f32.gt (global.get $fireCd) (f32.const 0.0))
      (then (global.set $fireCd (f32.sub (global.get $fireCd) (local.get $dt)))))
    (if (f32.gt (global.get $invuln) (f32.const 0.0))
      (then (global.set $invuln (f32.sub (global.get $invuln) (local.get $dt)))))
    (if (i32.ne (global.get $fireIn) (i32.const 0)) (then (call $fire))))

  ;; ---------------- the field ----------------

  (func $step_rocks (param $dt f32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a)
              (call $wrapf (f32.add (f32.load offset=0 (local.get $a))
                (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt)))
                (global.get $WORLD_W)))
            (f32.store offset=4 (local.get $a)
              (call $wrapf (f32.add (f32.load offset=4 (local.get $a))
                (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt)))
                (global.get $WORLD_H)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $rocks_alive (export "rocks_alive") (result i32)
    (local $i i32) (local $n i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (if (f32.gt (f32.load offset=24 (call $rock_addr (local.get $i))) (f32.const 0.0))
          (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $n))

  ;; A boulder becomes two chunks, a chunk becomes two pebbles, and a pebble
  ;; becomes cargo. The split writes into the same pool this frame's loop is
  ;; walking, which is fine and is the reason nothing here recurses: the new
  ;; rocks are ordinary records that the next frame treats like any other.
  ;;
  ;; A full pool silently drops the children. That is the correct failure —
  ;; the alternative is refusing to destroy the parent, which would make a
  ;; crowded field unshootable.
  ;; A pebble pays out. One gem always, a second often, and a fuel cell on
  ;; roughly one pebble in five — which is what keeps a stranded ship from
  ;; being a dead run — and, now and then, a power-up.
  (func $pebble_payout (param $x f32) (param $y f32)
    (call $add_score (global.get $SCORE_PEBBLE))
    (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 0))
    (if (f32.lt (call $rand_f32) (f32.const 0.55))
      (then (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 0))))
    (if (f32.lt (call $rand_f32) (f32.const 0.2))
      (then (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 1))))
    (if (f32.lt (call $rand2) (global.get $POWER_CHANCE))
      (then (call $spawn_power (local.get $x) (local.get $y)))))

  (func $split_rock (param $a i32)
    (local $size i32) (local $x f32) (local $y f32) (local $ang f32) (local $sp f32)
    (local $vx f32) (local $vy f32) (local $n i32) (local $i i32)
    (local.set $size (i32.trunc_f32_s (f32.load offset=20 (local.get $a))))
    (local.set $x (f32.load offset=0 (local.get $a)))
    (local.set $y (f32.load offset=4 (local.get $a)))
    (local.set $vx (f32.load offset=8 (local.get $a)))
    (local.set $vy (f32.load offset=12 (local.get $a)))
    (f32.store offset=24 (local.get $a) (f32.const 0.0))
    (global.set $hits (i32.add (global.get $hits) (i32.const 1)))

    (if (i32.le_s (local.get $size) (i32.const 1))
      (then
        (if (global.get $byRival)
          (then (call $rival_haul))
          (else (call $pebble_payout (local.get $x) (local.get $y))))
        (return)))

    ;; The drill mines a rock out whole: every pebble it would have become,
    ;; paid here, and nothing left behind. 2^(size-1) is 4 for a boulder and 2
    ;; for a chunk — the count the long way round produces.
    (if (f32.gt (global.get $drillT) (f32.const 0.0))
      (then
        (local.set $n (i32.shl (i32.const 1) (i32.sub (local.get $size) (i32.const 1))))
        (block $mined
          (loop $mlp
            (br_if $mined (i32.le_s (local.get $n) (i32.const 0)))
            (call $pebble_payout (local.get $x) (local.get $y))
            (local.set $n (i32.sub (local.get $n) (i32.const 1)))
            (br $mlp)))
        (return)))

    (call $add_score (global.get $SCORE_SPLIT))
    (local.set $ang (call $frand (f32.const 0.0) (global.get $TAU)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (i32.const 2)))
        (local.set $sp (call $frand (f32.mul (global.get $SPLIT_KICK) (f32.const 0.6))
                                    (global.get $SPLIT_KICK)))
        (call $spawn_rock (local.get $x) (local.get $y) (i32.sub (local.get $size) (i32.const 1))
          (f32.add (local.get $vx) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
          (f32.add (local.get $vy) (f32.mul (call $cosf (local.get $ang)) (local.get $sp))))
        ;; The pair leaves back to back, so a split always opens a gap to fly
        ;; through instead of a wall to reverse away from.
        (local.set $ang (f32.add (local.get $ang) (global.get $PI)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $step_bullets (param $dt f32)
    (local $i i32) (local $j i32) (local $a i32) (local $r i32)
    (local $x f32) (local $y f32) (local $rad f32)
    (local.set $i (i32.const 0))
    (block $bdone
      (loop $blp
        (br_if $bdone (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
        (local.set $a (call $bullet_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=16 (local.get $a)
              (f32.sub (f32.load offset=16 (local.get $a)) (local.get $dt)))
            (if (f32.le (f32.load offset=16 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=20 (local.get $a) (f32.const 0.0)))
              (else
                (local.set $x (call $wrapf (f32.add (f32.load offset=0 (local.get $a))
                  (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt)))
                  (global.get $WORLD_W)))
                (local.set $y (call $wrapf (f32.add (f32.load offset=4 (local.get $a))
                  (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt)))
                  (global.get $WORLD_H)))
                (f32.store offset=0 (local.get $a) (local.get $x))
                (f32.store offset=4 (local.get $a) (local.get $y))

                (local.set $j (i32.const 0))
                (block $rdone
                  (loop $rlp
                    (br_if $rdone (i32.ge_s (local.get $j) (global.get $MAX_ROCKS)))
                    (local.set $r (call $rock_addr (local.get $j)))
                    (if (f32.gt (f32.load offset=24 (local.get $r)) (f32.const 0.0))
                      (then
                        (local.set $rad (f32.load offset=16 (local.get $r)))
                        (if (f32.lt
                              (call $dist2 (local.get $x) (local.get $y)
                                           (f32.load offset=0 (local.get $r))
                                           (f32.load offset=4 (local.get $r)))
                              (f32.mul (local.get $rad) (local.get $rad)))
                          (then
                            (f32.store offset=20 (local.get $a) (f32.const 0.0))
                            (call $split_rock (local.get $r))
                            (br $rdone)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $rlp)))
                ;; a round that struck no rock may still strike the rival
                (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                  (then
                    (if (call $hit_rival (local.get $x) (local.get $y))
                      (then (f32.store offset=20 (local.get $a) (f32.const 0.0))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $blp))))

  ;; Point a pickup at the ship if it is within reach. The pull replaces its
  ;; drift rather than adding to it, so it arrives, instead of orbiting.
  (func $magnet_pull (param $a i32)
    (local $dx f32) (local $dy f32) (local $d f32)
    (local.set $dx (f32.sub (f32.load offset=0 (global.get $SHIP_OFF)) (f32.load offset=0 (local.get $a))))
    (local.set $dy (f32.sub (f32.load offset=4 (global.get $SHIP_OFF)) (f32.load offset=4 (local.get $a))))
    ;; the short way round the wrap
    (if (f32.gt (local.get $dx) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
      (then (local.set $dx (f32.sub (local.get $dx) (global.get $WORLD_W)))))
    (if (f32.lt (local.get $dx) (f32.mul (global.get $WORLD_W) (f32.const -0.5)))
      (then (local.set $dx (f32.add (local.get $dx) (global.get $WORLD_W)))))
    (if (f32.gt (local.get $dy) (f32.mul (global.get $WORLD_H) (f32.const 0.5)))
      (then (local.set $dy (f32.sub (local.get $dy) (global.get $WORLD_H)))))
    (if (f32.lt (local.get $dy) (f32.mul (global.get $WORLD_H) (f32.const -0.5)))
      (then (local.set $dy (f32.add (local.get $dy) (global.get $WORLD_H)))))
    (local.set $d (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx))
                                     (f32.mul (local.get $dy) (local.get $dy)))))
    (if (i32.or (f32.gt (local.get $d) (global.get $MAGNET_R)) (f32.lt (local.get $d) (f32.const 1.0)))
      (then (return)))
    (f32.store offset=8 (local.get $a)
      (f32.mul (f32.div (local.get $dx) (local.get $d)) (global.get $MAGNET_PULL)))
    (f32.store offset=12 (local.get $a)
      (f32.mul (f32.div (local.get $dy) (local.get $d)) (global.get $MAGNET_PULL))))

  (func $step_pickups (param $dt f32)
    (local $i i32) (local $a i32) (local $kind i32) (local $reach f32)
    (local.set $reach (f32.add (global.get $GRAB_R) (global.get $SHIP_R)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
        (local.set $a (call $pickup_addr (local.get $i)))
        (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=16 (local.get $a)
              (f32.sub (f32.load offset=16 (local.get $a)) (local.get $dt)))
            (if (f32.le (f32.load offset=16 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=24 (local.get $a) (f32.const 0.0)))
              (else
                ;; The magnet steers loot, not power-ups: those stay where
                ;; they are, so picking one up is still a decision.
                (if (i32.and (f32.gt (global.get $magnetT) (f32.const 0.0))
                             (f32.lt (f32.load offset=20 (local.get $a)) (f32.const 2.0)))
                  (then (call $magnet_pull (local.get $a))))
                (f32.store offset=0 (local.get $a)
                  (call $wrapf (f32.add (f32.load offset=0 (local.get $a))
                    (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt)))
                    (global.get $WORLD_W)))
                (f32.store offset=4 (local.get $a)
                  (call $wrapf (f32.add (f32.load offset=4 (local.get $a))
                    (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt)))
                    (global.get $WORLD_H)))

                (if (f32.lt
                      (call $dist2 (f32.load offset=0 (local.get $a))
                                   (f32.load offset=4 (local.get $a))
                                   (f32.load offset=0 (global.get $SHIP_OFF))
                                   (f32.load offset=4 (global.get $SHIP_OFF)))
                      (f32.mul (local.get $reach) (local.get $reach)))
                  (then
                    (local.set $kind (i32.trunc_f32_s (f32.load offset=20 (local.get $a))))
                    (if (i32.ge_s (local.get $kind) (i32.const 2))
                      (then
                        (f32.store offset=24 (local.get $a) (f32.const 0.0))
                        (global.set $powers (i32.add (global.get $powers) (i32.const 1)))
                        (call $add_score (global.get $SCORE_POWER))
                        (if (i32.eq (local.get $kind) (i32.const 2))
                          (then (global.set $magnetT (global.get $MAGNET_TIME)))
                          (else (global.set $drillT (global.get $DRILL_TIME))))))
                    (if (i32.eq (local.get $kind) (i32.const 1))
                      (then
                        (f32.store offset=24 (local.get $a) (f32.const 0.0))
                        (global.set $fuel (call $clampf
                          (f32.add (global.get $fuel) (global.get $FUEL_CELL))
                          (f32.const 0.0) (global.get $FUEL_MAX)))
                        (global.set $fuels (i32.add (global.get $fuels) (i32.const 1))))
                      (else
                        ;; A full hold leaves the gem where it is, still
                        ;; ticking down. That is the whole reason cargo is a
                        ;; decision: the field does not wait for the trip home.
                        (if (f32.lt (global.get $cargo) (global.get $CARGO_MAX))
                          (then
                            (f32.store offset=24 (local.get $a) (f32.const 0.0))
                            (global.set $cargo (f32.add (global.get $cargo) (f32.const 1.0)))
                            (global.set $grabs (i32.add (global.get $grabs) (i32.const 1)))))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- the rival ----------------

  ;; Signed shortest offset from a to b on a wrapped axis.
  (func $wdelta (param $a f32) (param $b f32) (param $w f32) (result f32)
    (local $d f32)
    (local.set $d (f32.sub (local.get $b) (local.get $a)))
    (if (f32.gt (local.get $d) (f32.mul (local.get $w) (f32.const 0.5)))
      (then (local.set $d (f32.sub (local.get $d) (local.get $w)))))
    (if (f32.lt (local.get $d) (f32.mul (local.get $w) (f32.const -0.5)))
      (then (local.set $d (f32.add (local.get $d) (local.get $w)))))
    (local.get $d))

  (func $spawn_rival
    (local $b i32)
    (local.set $b (global.get $RIVAL_OFF))
    (f32.store offset=0 (local.get $b)
      (call $wrapf (f32.add (call $depot_x) (f32.mul (global.get $WORLD_W) (f32.const 0.5))) (global.get $WORLD_W)))
    (f32.store offset=4 (local.get $b)
      (call $wrapf (f32.add (call $depot_y) (f32.mul (global.get $WORLD_H) (f32.const 0.5))) (global.get $WORLD_H)))
    (f32.store offset=8 (local.get $b) (f32.const 0.0))
    (f32.store offset=12 (local.get $b) (f32.const 0.0))
    (f32.store offset=16 (local.get $b) (f32.const 1.0))
    (f32.store offset=20 (local.get $b) (f32.const 0.0))
    (f32.store offset=24 (local.get $b) (f32.const 0.0))
    (f32.store offset=28 (local.get $b) (f32.const 0.0))
    (global.set $rivalHp (global.get $RIVAL_HP))
    (global.set $rivals (i32.add (global.get $rivals) (i32.const 1))))

  ;; A pebble the rival cuts goes straight into its hold — the gems a pebble
  ;; pays, one and often a second, and nothing onto the field. The first
  ;; version dropped them as loose gems like any split, and the bench showed
  ;; what that made it: a rival level came out *faster* than one without,
  ;; because it was mining for the player. Its haul is still the player's to
  ;; take, but only by shooting it.
  (func $rival_haul
    (local $b i32) (local $n f32)
    (local.set $b (global.get $RIVAL_OFF))
    (local.set $n (if (result f32) (f32.lt (call $rand_f32) (f32.const 0.55))
                     (then (f32.const 2.0)) (else (f32.const 1.0))))
    (f32.store offset=20 (local.get $b) (f32.min (global.get $RIVAL_CAP)
      (f32.add (f32.load offset=20 (local.get $b)) (local.get $n))))
    (global.set $rivalTakes (i32.add (global.get $rivalTakes) (i32.trunc_f32_s (local.get $n))))
    (if (f32.ge (f32.load offset=20 (local.get $b)) (global.get $RIVAL_CAP))
      (then (call $rival_escape))))

  ;; Full: it gets away, and files its claim — the level asks for more.
  (func $rival_escape
    (global.set $rivalEscapes (i32.add (global.get $rivalEscapes) (i32.const 1)))
    (global.set $quota (i32.add (global.get $quota) (global.get $RIVAL_CLAIM)))
    (call $rival_leave))

  ;; Leave: warp out over $RIVAL_WARP seconds, taking whatever it holds.
  (func $rival_leave
    (f32.store offset=16 (global.get $RIVAL_OFF) (f32.const 2.0))
    (f32.store offset=24 (global.get $RIVAL_OFF) (global.get $RIVAL_WARP))
    (f32.store offset=28 (global.get $RIVAL_OFF) (f32.const 0.0)))

  (func $step_rival (param $dt f32)
    (local $b i32) (local $i i32) (local $a i32) (local $best i32)
    (local $x f32) (local $y f32) (local $vx f32) (local $vy f32)
    (local $dx f32) (local $dy f32) (local $d f32) (local $bd f32)
    (local $wx f32) (local $wy f32) (local $k f32) (local $step f32)
    (local.set $b (global.get $RIVAL_OFF))
    (if (f32.ge (global.get $rivalT) (f32.const 0.0))
      (then
        (global.set $rivalT (f32.sub (global.get $rivalT) (local.get $dt)))
        (if (f32.lt (global.get $rivalT) (f32.const 0.0)) (then (call $spawn_rival)))))
    (if (f32.le (f32.load offset=16 (local.get $b)) (f32.const 0.0)) (then (return)))

    ;; warping out
    (if (f32.gt (f32.load offset=16 (local.get $b)) (f32.const 1.5))
      (then
        (f32.store offset=24 (local.get $b) (f32.sub (f32.load offset=24 (local.get $b)) (local.get $dt)))
        (if (f32.le (f32.load offset=24 (local.get $b)) (f32.const 0.0))
          (then (f32.store offset=16 (local.get $b) (f32.const 0.0))))
        (return)))

    (local.set $x (f32.load offset=0 (local.get $b)))
    (local.set $y (f32.load offset=4 (local.get $b)))
    (local.set $vx (f32.load offset=8 (local.get $b)))
    (local.set $vy (f32.load offset=12 (local.get $b)))
    (local.set $wx (f32.const 0.0))
    (local.set $wy (f32.const 0.0))

    (if (f32.gt (f32.load offset=24 (local.get $b)) (f32.const 0.0))
      (then
        ;; stunned: it drifts, and does nothing else
        (f32.store offset=24 (local.get $b) (f32.sub (f32.load offset=24 (local.get $b)) (local.get $dt))))
      (else
        ;; 1. a loose gem in sight
        (local.set $best (i32.const -1))
        (local.set $bd (f32.mul (global.get $RIVAL_SIGHT) (global.get $RIVAL_SIGHT)))
        (local.set $i (i32.const 0))
        (block $gdone
          (loop $glp
            (br_if $gdone (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
            (local.set $a (call $pickup_addr (local.get $i)))
            (if (i32.and (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
                         (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0)))
              (then
                (local.set $d (call $dist2 (local.get $x) (local.get $y)
                                (f32.load offset=0 (local.get $a)) (f32.load offset=4 (local.get $a))))
                (if (f32.lt (local.get $d) (local.get $bd))
                  (then (local.set $bd (local.get $d)) (local.set $best (local.get $a))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $glp)))
        (if (i32.ge_s (local.get $best) (i32.const 0))
          (then
            (f32.store offset=28 (local.get $b) (f32.const 0.0))
            (if (f32.lt (local.get $bd) (f32.mul (f32.add (global.get $GRAB_R) (global.get $RIVAL_R))
                                                 (f32.add (global.get $GRAB_R) (global.get $RIVAL_R))))
              (then
                (f32.store offset=24 (local.get $best) (f32.const 0.0))
                (f32.store offset=20 (local.get $b) (f32.add (f32.load offset=20 (local.get $b)) (f32.const 1.0)))
                (global.set $rivalTakes (i32.add (global.get $rivalTakes) (i32.const 1)))
                (if (f32.ge (f32.load offset=20 (local.get $b)) (global.get $RIVAL_CAP))
                  (then
                    (call $rival_escape)
                    (return))))
              (else
                (local.set $wx (call $wdelta (local.get $x) (f32.load offset=0 (local.get $best)) (global.get $WORLD_W)))
                (local.set $wy (call $wdelta (local.get $y) (f32.load offset=4 (local.get $best)) (global.get $WORLD_H))))))
          (else
            ;; 2. otherwise the nearest rock: close in, hold station, cut
            (local.set $best (i32.const -1))
            (local.set $bd (f32.const 1.0e9))
            (local.set $i (i32.const 0))
            (block $rdone
              (loop $rlp
                (br_if $rdone (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
                (local.set $a (call $rock_addr (local.get $i)))
                (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
                  (then
                    (local.set $d (call $dist2 (local.get $x) (local.get $y)
                                    (f32.load offset=0 (local.get $a)) (f32.load offset=4 (local.get $a))))
                    (if (f32.lt (local.get $d) (local.get $bd))
                      (then (local.set $bd (local.get $d)) (local.set $best (local.get $a))))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $rlp)))
            (if (i32.ge_s (local.get $best) (i32.const 0))
              (then
                (f32.store offset=32 (local.get $b) (f32.load offset=0 (local.get $best)))
                (f32.store offset=36 (local.get $b) (f32.load offset=4 (local.get $best)))
                (if (f32.gt (local.get $bd) (f32.mul (global.get $RIVAL_REACH) (global.get $RIVAL_REACH)))
                  (then
                    (f32.store offset=28 (local.get $b) (f32.const 0.0))
                    ;; Arrive rather than charge: the wanted speed falls
                    ;; off inside the last stretch, so it stops in range
                    ;; instead of sailing through the rock and out again.
                    ;; Without this a cut took fifteen seconds to start.
                    (local.set $d (f32.sqrt (local.get $bd)))
                    (local.set $k (f32.div (f32.min (global.get $RIVAL_SPEED)
                                              (f32.mul (f32.sub (local.get $d) (f32.const 70.0)) (f32.const 1.6)))
                                            (local.get $d)))
                    (local.set $wx (f32.add (f32.load offset=8 (local.get $best)) (f32.mul (local.get $k)
                      (call $wdelta (local.get $x) (f32.load offset=0 (local.get $best)) (global.get $WORLD_W)))))
                    (local.set $wy (f32.add (f32.load offset=12 (local.get $best)) (f32.mul (local.get $k)
                      (call $wdelta (local.get $y) (f32.load offset=4 (local.get $best)) (global.get $WORLD_H))))))
                  (else
                    ;; Station-keeping: match the rock's drift, so the beam
                    ;; holds on it rather than the rival sliding past.
                    (local.set $wx (f32.load offset=8 (local.get $best)))
                    (local.set $wy (f32.load offset=12 (local.get $best)))
                    (f32.store offset=28 (local.get $b)
                      (f32.add (f32.load offset=28 (local.get $b)) (local.get $dt)))
                    (if (f32.ge (f32.load offset=28 (local.get $b)) (global.get $RIVAL_DRILL))
                      (then
                        (f32.store offset=28 (local.get $b) (f32.const 0.0))
                        (global.set $byRival (i32.const 1))
                        (call $split_rock (local.get $best))
                        (global.set $byRival (i32.const 0))))))))))

        ;; Steer: the wanted direction at RIVAL_SPEED (station-keeping asks
        ;; for the rock's own, slower velocity), reached at RIVAL_ACC.
        (local.set $d (f32.sqrt (f32.add (f32.mul (local.get $wx) (local.get $wx))
                                         (f32.mul (local.get $wy) (local.get $wy)))))
        (if (f32.gt (local.get $d) (global.get $RIVAL_SPEED))
          (then
            (local.set $wx (f32.mul (local.get $wx) (f32.div (global.get $RIVAL_SPEED) (local.get $d))))
            (local.set $wy (f32.mul (local.get $wy) (f32.div (global.get $RIVAL_SPEED) (local.get $d))))))
        (local.set $step (f32.mul (global.get $RIVAL_ACC) (local.get $dt)))
        (local.set $vx (f32.add (local.get $vx)
          (call $clampf (f32.sub (local.get $wx) (local.get $vx)) (f32.neg (local.get $step)) (local.get $step))))
        (local.set $vy (f32.add (local.get $vy)
          (call $clampf (f32.sub (local.get $wy) (local.get $vy)) (f32.neg (local.get $step)) (local.get $step))))))

    ;; stunned or working, it moves; drag bleeds a stunned drift away
    (local.set $k (call $clampf (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))
                                (f32.const 0.0) (f32.const 1.0)))
    (if (f32.gt (f32.load offset=24 (local.get $b)) (f32.const 0.0))
      (then
        (local.set $vx (f32.mul (local.get $vx) (local.get $k)))
        (local.set $vy (f32.mul (local.get $vy) (local.get $k)))))
    (f32.store offset=8 (local.get $b) (local.get $vx))
    (f32.store offset=12 (local.get $b) (local.get $vy))
    (f32.store offset=0 (local.get $b)
      (call $wrapf (f32.add (local.get $x) (f32.mul (local.get $vx) (local.get $dt))) (global.get $WORLD_W)))
    (f32.store offset=4 (local.get $b)
      (call $wrapf (f32.add (local.get $y) (f32.mul (local.get $vy) (local.get $dt))) (global.get $WORLD_H))))

  ;; A round against the rival: 1 if it struck. The hold spills as loose
  ;; gems, the rival is stunned, and the third hit drives it off. A stunned
  ;; rival cannot be struck again, so one burst of fire is one spill.
  (func $hit_rival (param $x f32) (param $y f32) (result i32)
    (local $b i32) (local $n i32)
    (local.set $b (global.get $RIVAL_OFF))
    (if (f32.ne (f32.load offset=16 (local.get $b)) (f32.const 1.0)) (then (return (i32.const 0))))
    (if (f32.gt (f32.load offset=24 (local.get $b)) (f32.const 0.0)) (then (return (i32.const 0))))
    (if (f32.ge (call $dist2 (local.get $x) (local.get $y)
                  (f32.load offset=0 (local.get $b)) (f32.load offset=4 (local.get $b)))
                (f32.mul (global.get $RIVAL_R) (global.get $RIVAL_R)))
      (then (return (i32.const 0))))
    (global.set $rivalHits (i32.add (global.get $rivalHits) (i32.const 1)))
    (local.set $n (i32.trunc_f32_s (f32.load offset=20 (local.get $b))))
    (block $done
      (loop $lp
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))
        (call $spawn_pickup (f32.load offset=0 (local.get $b)) (f32.load offset=4 (local.get $b)) (i32.const 0))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $lp)))
    (f32.store offset=20 (local.get $b) (f32.const 0.0))
    (f32.store offset=28 (local.get $b) (f32.const 0.0))
    (global.set $rivalHp (i32.sub (global.get $rivalHp) (i32.const 1)))
    (if (i32.le_s (global.get $rivalHp) (i32.const 0))
      (then
        (global.set $rivalRouts (i32.add (global.get $rivalRouts) (i32.const 1)))
        (call $add_score (global.get $SCORE_RIVAL))
        (call $rival_leave))
      (else (f32.store offset=24 (local.get $b) (global.get $RIVAL_STUN))))
    (i32.const 1))

  ;; ---------------- ship vs rocks, and the depot ----------------

  (func $collide_ship (param $dt f32)
    (local $i i32) (local $a i32) (local $rad f32)
    (if (f32.gt (global.get $invuln) (f32.const 0.0)) (then (return)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $rad (f32.add (f32.load offset=16 (local.get $a)) (global.get $SHIP_R)))
            (if (f32.lt
                  (call $dist2 (f32.load offset=0 (local.get $a))
                               (f32.load offset=4 (local.get $a))
                               (f32.load offset=0 (global.get $SHIP_OFF))
                               (f32.load offset=4 (global.get $SHIP_OFF)))
                  (f32.mul (local.get $rad) (local.get $rad)))
              (then (call $die) (return)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Docked: refuel continuously, and unload the hold one gem at a time. A hold
  ;; that emptied in a single frame would be one number changing; a drip is a
  ;; sequence the player can hear, and it costs the seconds that make choosing
  ;; when to come home a decision.
  (func $dock (param $dt f32)
    (local $r f32)
    (local.set $r (f32.add (global.get $DEPOT_R) (global.get $SHIP_R)))
    (if (f32.ge (call $dist2 (f32.load offset=0 (global.get $SHIP_OFF))
                             (f32.load offset=4 (global.get $SHIP_OFF))
                             (call $depot_x) (call $depot_y))
                (f32.mul (local.get $r) (local.get $r)))
      (then
        (global.set $docked (i32.const 0))
        (global.set $deliverAcc (f32.const 0.0))
        (return)))
    (global.set $docked (i32.const 1))

    (global.set $fuel (call $clampf
      (f32.add (global.get $fuel) (f32.mul (global.get $REFUEL_RATE) (local.get $dt)))
      (f32.const 0.0) (global.get $FUEL_MAX)))

    (if (f32.le (global.get $cargo) (f32.const 0.0)) (then (return)))
    (global.set $deliverAcc (f32.add (global.get $deliverAcc) (local.get $dt)))
    (block $done
      (loop $lp
        (br_if $done (f32.lt (global.get $deliverAcc) (global.get $DELIVER_EVERY)))
        (br_if $done (f32.le (global.get $cargo) (f32.const 0.0)))
        (global.set $deliverAcc (f32.sub (global.get $deliverAcc) (global.get $DELIVER_EVERY)))
        (global.set $cargo (f32.sub (global.get $cargo) (f32.const 1.0)))
        (global.set $delivered (i32.add (global.get $delivered) (i32.const 1)))
        (global.set $credit (i32.add (global.get $credit) (i32.const 1)))
        (global.set $drops (i32.add (global.get $drops) (i32.const 1)))
        (call $add_score (global.get $SCORE_GEM))
        (br $lp))))

  ;; What an item costs now, or -1 if it cannot be bought: a hold or tank at
  ;; its last tier, or a hull with no ship missing. The widget draws the menu
  ;; from this, so a price shown is always a price the engine will charge.
  (func $refit_cost (export "get_refit_cost") (param $item i32) (result i32)
    (local $tier i32)
    (if (i32.eq (local.get $item) (i32.const 3))
      (then
        (if (f32.ge (global.get $lives) (global.get $START_LIVES))
          (then (return (i32.const -1))))
        (return (i32.add (global.get $PRICE_HULL)
          (i32.mul (global.get $hullsBought) (global.get $PRICE_HULL_STEP))))))
    (if (i32.eq (local.get $item) (i32.const 1))
      (then (local.set $tier (global.get $holdTier)))
      (else
        (if (i32.eq (local.get $item) (i32.const 2))
          (then (local.set $tier (global.get $tankTier)))
          (else (return (i32.const -1))))))
    (if (i32.ge_s (local.get $tier) (global.get $TIER_MAX)) (then (return (i32.const -1))))
    (if (result i32) (i32.eqz (local.get $tier))
      (then (global.get $PRICE_T1))
      (else (global.get $PRICE_T2))))

  ;; What the hold (1) or tank (2) would become if bought now, so the menu can
  ;; say "HOLD 16" without knowing the step.
  (func $refit_next (export "get_refit_next") (param $item i32) (result f32)
    (if (result f32) (i32.eq (local.get $item) (i32.const 1))
      (then (f32.add (global.get $CARGO_MAX) (global.get $HOLD_STEP)))
      (else (f32.add (global.get $FUEL_MAX) (global.get $TANK_STEP)))))

  ;; Docked, with a press this frame and the credit for it: buy. Anything else
  ;; is silently nothing, and the menu the widget draws already says why.
  (func $refit
    (local $cost i32)
    (if (i32.eqz (global.get $docked)) (then (return)))
    (if (i32.eqz (global.get $buyIn)) (then (return)))
    (local.set $cost (call $refit_cost (global.get $buyIn)))
    (if (i32.lt_s (local.get $cost) (i32.const 0)) (then (return)))
    (if (i32.lt_s (global.get $credit) (local.get $cost)) (then (return)))
    (global.set $credit (i32.sub (global.get $credit) (local.get $cost)))
    (global.set $refits (i32.add (global.get $refits) (i32.const 1)))
    (if (i32.eq (global.get $buyIn) (i32.const 1))
      (then
        (global.set $holdTier (i32.add (global.get $holdTier) (i32.const 1)))
        (global.set $CARGO_MAX (f32.add (global.get $CARGO_MAX) (global.get $HOLD_STEP)))))
    (if (i32.eq (global.get $buyIn) (i32.const 2))
      (then
        (global.set $tankTier (i32.add (global.get $tankTier) (i32.const 1)))
        (global.set $FUEL_MAX (f32.add (global.get $FUEL_MAX) (global.get $TANK_STEP)))))
    (if (i32.eq (global.get $buyIn) (i32.const 3))
      (then
        (global.set $hullsBought (i32.add (global.get $hullsBought) (i32.const 1)))
        (global.set $lives (f32.add (global.get $lives) (f32.const 1.0))))))

  ;; ---------------- state machine ----------------

  ;; Cargo is spilled where the ship died rather than deleted. Losing the run's
  ;; takings outright reads as the game taking something; watching it scatter
  ;; across the rocks reads as a chance, and it is the same arithmetic.
  (func $die
    (local $n i32)
    (global.set $deaths (i32.add (global.get $deaths) (i32.const 1)))
    (local.set $n (i32.trunc_f32_s (global.get $cargo)))
    (block $done
      (loop $lp
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))
        (call $spawn_pickup (f32.load offset=0 (global.get $SHIP_OFF))
                            (f32.load offset=4 (global.get $SHIP_OFF)) (i32.const 0))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $lp)))
    (global.set $cargo (f32.const 0.0))
    ;; a power-up goes down with the ship that was carrying it
    (global.set $magnetT (f32.const 0.0))
    (global.set $drillT (f32.const 0.0))
    (global.set $lives (f32.sub (global.get $lives) (f32.const 1.0)))
    (if (f32.le (global.get $lives) (f32.const 0.0))
      (then
        (global.set $lives (f32.const 0.0))
        (global.set $gameOver (i32.const 1))
        (f32.store offset=20 (global.get $SHIP_OFF) (f32.const 0.0)))
      (else
        (call $place_ship_at_depot)
        ;; A full tank on respawn is what makes ramming a rock a deliberate,
        ;; expensive way out of a stranding rather than a soft-lock.
        (global.set $fuel (global.get $FUEL_MAX)))))

  (func $clear_pool (param $off i32) (param $stride i32) (param $count i32) (param $activeOff i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
        (f32.store
          (i32.add (i32.add (local.get $off) (i32.mul (local.get $i) (local.get $stride)))
                   (local.get $activeOff))
          (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $build_level
    (local $n i32) (local $i i32)
    (call $clear_pool (global.get $ROCKS_OFF) (global.get $ROCK_STRIDE)
                      (global.get $MAX_ROCKS) (i32.const 24))
    (call $clear_pool (global.get $BULLETS_OFF) (global.get $BULLET_STRIDE)
                      (global.get $MAX_BULLETS) (i32.const 20))
    (call $clear_pool (global.get $PICKUPS_OFF) (global.get $PICKUP_STRIDE)
                      (global.get $MAX_PICKUPS) (i32.const 24))

    ;; The depot moves every level. A fixed one would let a player learn one
    ;; route and stop reading the field.
    (f32.store (global.get $DEPOT_OFF)
      (call $frand (f32.const 150.0) (f32.sub (global.get $WORLD_W) (f32.const 150.0))))
    (f32.store offset=4 (global.get $DEPOT_OFF)
      (call $frand (f32.const 130.0) (f32.sub (global.get $WORLD_H) (f32.const 130.0))))

    ;; Three boulders on level 1, one more each level, capped at ten — beyond
    ;; that the splits alone fill the pool. Easy and Hard shift all three
    ;; numbers; see the difficulty table.
    (local.set $n (call $field_rocks))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (call $spawn_drifter)
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    ;; Six gems to deliver on level 1, three more each level. It is a delivery
    ;; count, not a mining count: what the level asks for is round trips.
    (global.set $quota
      (i32.add (global.get $QUOTA_BASE)
               (i32.mul (global.get $level) (global.get $QUOTA_STEP))))
    (global.set $delivered (i32.const 0))
    (global.set $cargo (f32.const 0.0))
    (global.set $fuel (global.get $FUEL_MAX))
    (global.set $deliverAcc (f32.const 0.0))
    (global.set $respawnAcc (f32.const 0.0))
    (global.set $magnetT (f32.const 0.0))
    (global.set $drillT (f32.const 0.0))
    ;; a rival still working when the level ends goes with it
    (f32.store offset=16 (global.get $RIVAL_OFF) (f32.const 0.0))
    (global.set $rivalT (f32.const -1.0))
    (if (i32.eqz (i32.rem_s (global.get $level) (global.get $RIVAL_EVERY)))
      (then (global.set $rivalT (global.get $RIVAL_DELAY))))
    (call $place_ship_at_depot))

  ;; Copy one column of the difficulty table into the globals the rest of the
  ;; engine reads. Called only from init, so a run never changes balance halfway
  ;; through. Normal restates the initialisers, because a restart after an Easy
  ;; or Hard run has to put them back.
  (func $apply_difficulty
    (if (i32.eqz (global.get $difficulty))
      (then   ;; easy
        (global.set $START_LIVES (f32.const 5.0))
        (global.set $FUEL_BURN (f32.const 6.5))
        (global.set $FUEL_CELL (f32.const 28.0))
        (global.set $ROCK_BASE (i32.const 1))
        (global.set $ROCK_MIN (i32.const 2))
        (global.set $ROCK_CAP (i32.const 8))
        (global.set $QUOTA_BASE (i32.const 2))
        (global.set $QUOTA_STEP (i32.const 2))
        (global.set $ROCK_SPEED (f32.const 22.0))
        (global.set $ROCK_SPEED_STEP (f32.const 3.0)))
      (else
        (if (i32.eq (global.get $difficulty) (i32.const 2))
          (then   ;; hard
            (global.set $START_LIVES (f32.const 3.0))
            (global.set $FUEL_BURN (f32.const 10.5))
            (global.set $FUEL_CELL (f32.const 18.0))
            (global.set $ROCK_BASE (i32.const 3))
            (global.set $ROCK_MIN (i32.const 4))
            (global.set $ROCK_CAP (i32.const 12))
            (global.set $QUOTA_BASE (i32.const 4))
            (global.set $QUOTA_STEP (i32.const 4))
            (global.set $ROCK_SPEED (f32.const 31.0))
            (global.set $ROCK_SPEED_STEP (f32.const 5.0)))
          (else   ;; normal
            (global.set $START_LIVES (f32.const 4.0))
            (global.set $FUEL_BURN (f32.const 8.5))
            (global.set $FUEL_CELL (f32.const 22.0))
            (global.set $ROCK_BASE (i32.const 2))
            (global.set $ROCK_MIN (i32.const 3))
            (global.set $ROCK_CAP (i32.const 10))
            (global.set $QUOTA_BASE (i32.const 3))
            (global.set $QUOTA_STEP (i32.const 3))
            (global.set $ROCK_SPEED (f32.const 26.0))
            (global.set $ROCK_SPEED_STEP (f32.const 4.0)))))))

  ;; 0 easy, 1 normal, 2 hard; anything else is clamped rather than trusted, and
  ;; a JavaScript call with no argument arrives as 0. Takes effect at the next
  ;; init().
  (func $set_difficulty (export "set_difficulty") (param $d i32)
    (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.const 0))))
    (if (i32.gt_s (local.get $d) (i32.const 2)) (then (local.set $d (i32.const 2))))
    (global.set $difficulty (local.get $d)))
  (func $get_difficulty (export "get_difficulty") (result i32) (global.get $difficulty))

  (func $init (export "init")
    ;; first, because the lives and the level built below all read it
    (call $apply_difficulty)
    (global.set $rng (i32.const 1103515245))
    (global.set $rng2 (i32.const 521288629))
    (global.set $powerDrops (i32.const 0))
    (global.set $powers (i32.const 0))
    ;; The refit is the run's, not the level's, so only init takes it back —
    ;; and before $build_level, which fills the tank to whatever FUEL_MAX is.
    (global.set $FUEL_MAX (f32.const 100.0))
    (global.set $CARGO_MAX (f32.const 12.0))
    (global.set $holdTier (i32.const 0))
    (global.set $tankTier (i32.const 0))
    (global.set $hullsBought (i32.const 0))
    (global.set $credit (i32.const 0))
    (global.set $refits (i32.const 0))
    (global.set $buyIn (i32.const 0))
    (global.set $docked (i32.const 0))
    (global.set $rivals (i32.const 0))
    (global.set $rivalHits (i32.const 0))
    (global.set $rivalTakes (i32.const 0))
    (global.set $rivalRouts (i32.const 0))
    (global.set $rivalEscapes (i32.const 0))
    (global.set $level (i32.const 1))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $lives (global.get $START_LIVES))
    (global.set $shots (i32.const 0))
    (global.set $hits (i32.const 0))
    (global.set $grabs (i32.const 0))
    (global.set $fuels (i32.const 0))
    (global.set $drops (i32.const 0))
    (global.set $deaths (i32.const 0))
    (global.set $rotIn (f32.const 0.0))
    (global.set $thrustIn (i32.const 0))
    (global.set $fireIn (i32.const 0))
    (global.set $aimOn (i32.const 0))
    (call $build_level))

  (func $next_level
    (global.set $level (i32.add (global.get $level) (i32.const 1)))
    (call $add_score (global.get $SCORE_LEVEL))
    ;; Fuel left in the tank is worth points. Without it the optimal play is to
    ;; burn the tank dry on the last run, which is the opposite of the habit
    ;; the fuel gauge is trying to teach.
    (call $add_score (global.get $fuel))
    ;; the hold's surplus past the quota goes to the bank, not overboard
    (global.set $credit (i32.add (global.get $credit)
      (i32.trunc_f32_s (global.get $cargo))))
    (call $build_level))

  (func $set_input (export "set_input")
      (param $rot f32) (param $thrust i32) (param $fire i32)
      (param $aimOn i32) (param $aimAng f32) (param $buy i32)
    (global.set $rotIn (call $clampf (local.get $rot) (f32.const -1.0) (f32.const 1.0)))
    (global.set $thrustIn (local.get $thrust))
    (global.set $fireIn (local.get $fire))
    (global.set $aimOn (local.get $aimOn))
    (global.set $aimAng (local.get $aimAng))
    (global.set $buyIn (local.get $buy)))

  (func $step (export "step") (param $dt f32)
    (local $d f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))

    (if (f32.gt (global.get $magnetT) (f32.const 0.0))
      (then (global.set $magnetT (f32.sub (global.get $magnetT) (local.get $d)))))
    (if (f32.gt (global.get $drillT) (f32.const 0.0))
      (then (global.set $drillT (f32.sub (global.get $drillT) (local.get $d)))))
    (call $step_ship (local.get $d))
    (call $step_rocks (local.get $d))
    (call $step_bullets (local.get $d))
    (call $step_pickups (local.get $d))
    (call $step_rival (local.get $d))
    (call $collide_ship (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (call $dock (local.get $d))
    (call $refit)

    ;; Top the field up on a timer rather than only at level start. A player
    ;; who has shot everything and still owes the depot gems would otherwise be
    ;; looking at an empty screen with nothing left to do — and the drifters
    ;; are also where fuel comes from.
    (global.set $respawnAcc (f32.add (global.get $respawnAcc) (local.get $d)))
    (if (f32.ge (global.get $respawnAcc) (global.get $RESPAWN_EVERY))
      (then
        (global.set $respawnAcc (f32.const 0.0))
        (if (i32.lt_s (call $rocks_alive) (call $field_rocks))
          (then (call $spawn_drifter)))))

    (if (i32.ge_s (global.get $delivered) (global.get $quota))
      (then (call $next_level))))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_lives (export "get_lives") (result f32) (global.get $lives))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_fuel (export "get_fuel") (result f32) (global.get $fuel))
  (func $get_fuel_max (export "get_fuel_max") (result f32) (global.get $FUEL_MAX))
  (func $get_cargo (export "get_cargo") (result f32) (global.get $cargo))
  (func $get_cargo_max (export "get_cargo_max") (result f32) (global.get $CARGO_MAX))
  (func $get_delivered (export "get_delivered") (result i32) (global.get $delivered))
  (func $get_quota (export "get_quota") (result i32) (global.get $quota))
  (func $get_heading (export "get_heading") (result f32)
    (f32.load offset=16 (global.get $SHIP_OFF)))
  (func $get_thrusting (export "get_thrusting") (result i32) (global.get $thrusting))
  (func $get_invuln (export "get_invuln") (result f32) (global.get $invuln))
  (func $get_depot_x (export "get_depot_x") (result f32) (call $depot_x))
  (func $get_depot_y (export "get_depot_y") (result f32) (call $depot_y))
  (func $get_depot_r (export "get_depot_r") (result f32) (global.get $DEPOT_R))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_shots (export "get_shots") (result i32) (global.get $shots))
  (func $get_hits (export "get_hits") (result i32) (global.get $hits))
  (func $get_grabs (export "get_grabs") (result i32) (global.get $grabs))
  (func $get_fuels (export "get_fuels") (result i32) (global.get $fuels))
  (func $get_drops (export "get_drops") (result i32) (global.get $drops))
  (func $get_deaths (export "get_deaths") (result i32) (global.get $deaths))
  (func $get_power_drops (export "get_power_drops") (result i32) (global.get $powerDrops))
  (func $get_powers (export "get_powers") (result i32) (global.get $powers))
  (func $get_magnet (export "get_magnet") (result f32) (global.get $magnetT))
  (func $get_drill (export "get_drill") (result f32) (global.get $drillT))
  (func $get_magnet_r (export "get_magnet_r") (result f32) (global.get $MAGNET_R))
  (func $get_credit (export "get_credit") (result i32) (global.get $credit))
  (func $get_hold_tier (export "get_hold_tier") (result i32) (global.get $holdTier))
  (func $get_tank_tier (export "get_tank_tier") (result i32) (global.get $tankTier))
  (func $get_docked (export "get_docked") (result i32) (global.get $docked))
  (func $get_refits (export "get_refits") (result i32) (global.get $refits))
  (func $get_rivals (export "get_rivals") (result i32) (global.get $rivals))
  (func $get_rival_hits (export "get_rival_hits") (result i32) (global.get $rivalHits))
  (func $get_rival_takes (export "get_rival_takes") (result i32) (global.get $rivalTakes))
  (func $get_rival_routs (export "get_rival_routs") (result i32) (global.get $rivalRouts))
  (func $get_rival_escapes (export "get_rival_escapes") (result i32) (global.get $rivalEscapes))
  (func $get_rival_hp (export "get_rival_hp") (result i32) (global.get $rivalHp))
  (func $get_rival_cap (export "get_rival_cap") (result f32) (global.get $RIVAL_CAP))
  (func $get_rival_drill (export "get_rival_drill") (result f32) (global.get $RIVAL_DRILL))
)
