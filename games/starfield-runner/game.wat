(module
  ;; ============================================================
  ;; STARFIELD RUNNER — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as the other six (globals block
  ;; at the top, entity pools at fixed offsets in linear memory, xorshift RNG,
  ;; an init/set_input/step/get_* export surface, monotonic event counters) and
  ;; nothing else. Every constant and every routine below is its own.
  ;;
  ;; ---- why this exists next to Circuit Runner ----
  ;;
  ;; Both scroll toward the player, and that is the whole reason this title
  ;; nearly was not built. The plan said so in writing: build the tight-squeeze
  ;; scoring first or do not build it. So the squeeze *is* the game, and
  ;; everything else was chosen to get out of its way:
  ;;
  ;;   • Nothing to collect. Circuit Runner puts charge in the lane you did not
  ;;     take; here there are no pickups at all. The only thing on the board is
  ;;     debris, and the only currency is **how close you flew to it**.
  ;;   • Free lateral flight, not lanes. A lane is a decision you commit to;
  ;;     an analogue x with momentum is a decision you are making continuously,
  ;;     which is what a scoring rule about *clearance* needs in order to mean
  ;;     anything. Circuit Runner's slide could not express "two pixels closer".
  ;;   • A hull you can only repair with risk. Grazing banks charge, charge
  ;;     patches a plate, and there is no other way to get one back — so flying
  ;;     safe is not a slower strategy, it is a losing one. That is the entire
  ;;     economy, and it is the opposite of Circuit Runner's, where the safe
  ;;     lane is genuinely safe and the charge is a temptation off it.
  ;;
  ;; ---- graze, and squeeze ----
  ;;
  ;; Every rock remembers the closest its surface ever came to the ship's
  ;; (field `near`, index 5). When it drops behind the ship the engine settles
  ;; up: inside the graze band, that is a **graze**, worth more the tighter it
  ;; was. Two grazes settling within $SQUEEZE_WINDOW of each other means the
  ;; ship went *between* two rocks, which is a **squeeze** — worth much more,
  ;; and the only thing that raises the multiplier.
  ;;
  ;; Resolving on the way out rather than on the way in matters. Scoring the
  ;; moment the ship enters the band would pay for a near miss the player then
  ;; turned into a collision, and would pay repeatedly while the rock slid past.
  ;;
  ;; There are **no imports**, as in worm-chase, sector-defense and
  ;; circuit-runner. Clearance is a distance, distance is f32.sqrt, and
  ;; f32.sqrt is an instruction. Nothing here turns through an angle.
  ;;
  ;; JavaScript owns no game state. It forwards input, calls step(dt), and
  ;; reads entity records straight out of the memory below to draw them —
  ;; including `near`, which is what lets the renderer light a rock up as the
  ;; ship closes on it without deciding anything itself.
  ;; ============================================================

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; ship   @0    : x, vx, alive, invuln              (4 f32 = 16)
  ;; rocks  @16   : stride 40, MAX_ROCKS = 26
  ;;                x, y, vx, r, active, near, spin, kind, resolved, path
  ;;                ends at 16 + 26*40 = 1056
  ;;
  ;; rock kinds: 0 = shard, 1 = boulder, 2 = slab (the one that drifts)
  ;;
  ;; `near` is the smallest *surface* clearance this rock has ever had to the
  ;; ship — not centre distance. It starts at $NEAR_NONE, falls as the ship
  ;; closes, and is never raised again, so it is a record of the whole pass
  ;; rather than of this frame. Below zero means contact. `resolved` is 1 once
  ;; the rock has been settled up, so a rock cannot be scored twice.
  ;;
  ;; `path` is the centre of the guaranteed corridor of the field this rock was
  ;; placed in. Every rock in a field carries the same value, which is
  ;; redundant and deliberate: fields are not objects here, they are a moment
  ;; in $spawn_field, and putting the number on the rocks means the renderer
  ;; can draw the safe channel for whichever field is arriving without the
  ;; engine keeping a second list of fields for it to read.
  ;;
  ;; Scalars — score, hull, charge, mult, distance — live in globals rather
  ;; than memory, as in the other recent titles: the get_* readers are the only
  ;; consumer, and a global is one instruction to read.
  ;; ===================================================

  (global $SHIP_OFF i32 (i32.const 0))
  (global $ROCKS_OFF i32 (i32.const 16))
  (global $ROCK_STRIDE i32 (i32.const 40))
  (global $MAX_ROCKS i32 (i32.const 26))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))

  ;; ---- the ship ----
  (global $SHIP_Y f32 (f32.const 618.0))
  (global $SHIP_R f32 (f32.const 17.0))
  ;; Momentum, not a slide. The ship accelerates and coasts, so committing to a
  ;; direction costs something to undo — which is what makes a gap you aimed at
  ;; and missed feel like your mistake rather than the board's. It is also the
  ;; reason the corridor has to be as wide as it is; see $corridor.
  (global $THRUST f32 (f32.const 2700.0))
  ;; Drag is what sets the *feel*. At 2.0 the ship glided like a puck and every
  ;; tight gap became a two-second commitment made blind. At 8.0 it stopped
  ;; dead the frame a key came up, which is a lane game with extra steps. 4.6
  ;; leaves about a third of a second of coast: long enough to be momentum,
  ;; short enough to correct inside one field.
  (global $DRAG f32 (f32.const 4.6))
  (global $MAX_VX f32 (f32.const 540.0))
  (global $SHIP_MARGIN f32 (f32.const 26.0))
  ;; A hit costs a plate and then leaves you alone for a moment. Without the
  ;; window a field that lands one hit lands three, because the ship is still
  ;; inside the rock it just struck and the next two are half a second behind.
  (global $INVULN_TIME f32 (f32.const 1.15))

  ;; ---- scrolling ----
  ;; Speed is a function of distance, not of a level counter — the same choice
  ;; Circuit Runner makes, for the same reason: it is the only difficulty curve
  ;; an endless runner needs, and it cannot be gamed by playing slowly.
  (global $SPEED_BASE f32 (f32.const 250.0))
  (global $SPEED_PER_KM f32 (f32.const 11.0))
  (global $SPEED_CAP f32 (f32.const 620.0))

  ;; ---- the fields ----
  ;; Fields arrive on a distance clock, so a faster board is a *denser* one. On
  ;; a wall clock it would be the reverse, which is exactly backwards.
  (global $FIELD_GAP f32 (f32.const 400.0))
  (global $FIELD_GAP_MIN f32 (f32.const 268.0))
  (global $FIELD_GAP_STEP f32 (f32.const 2.6))   ;; closer per 1000px
  (global $MAX_IN_FIELD i32 (i32.const 6))

  ;; The guaranteed corridor. No rock may intrude on it, and its centre moves
  ;; between fields by at most what the ship can actually fly in the time it
  ;; has — see $path_step. This is the same construction Circuit Runner uses
  ;; for $pathLane, generalised from six lanes to an analogue x.
  ;;
  ;; How far that is cannot be a constant, and the first build's flat 210px
  ;; proved it. A pilot that flies nothing but the corridor was hit three times
  ;; in two minutes, and every hit was at the speed cap with the ship 106-170px
  ;; outside a corridor 160px wide — it was not dodging badly, it was still on
  ;; its way. At 620px/s a field is 268px behind the last, which is 0.43s, and
  ;; 0.43s of thrust against this much drag is 142px from rest. A 210px step
  ;; was simply not reachable, and no amount of skill closes that.
  ;;
  ;; $REACH_RATE is that budget as a rate: 300px per second of flight time, a
  ;; shade under the 330 the drag equation gives, because the ship is rarely at
  ;; rest facing the right way. The cap keeps early fields from throwing the
  ;; corridor across the whole board just because there is time to follow it.
  (global $REACH_RATE f32 (f32.const 300.0))
  (global $PATH_STEP_MAX f32 (f32.const 300.0))
  (global $PATH_STEP_MIN f32 (f32.const 80.0))
  (global $CORRIDOR f32 (f32.const 250.0))
  (global $CORRIDOR_MIN f32 (f32.const 148.0))
  (global $CORRIDOR_STEP f32 (f32.const 1.6))     ;; narrower per 1000px

  ;; ---- graze ----
  ;; How close counts. 30px against a 17px ship reads, on screen, as "you could
  ;; see daylight and it was thin" — wider and clean flying scores by accident,
  ;; narrower and the band is inside the sprite's own outline, so the player
  ;; cannot tell a graze from a miss and stops believing the score.
  (global $GRAZE_BAND f32 (f32.const 30.0))
  ;; Two grazes this close together mean one gap, not two rocks.
  (global $SQUEEZE_WINDOW f32 (f32.const 0.34))
  (global $NEAR_NONE f32 (f32.const 9999.0))

  ;; ---- hull and charge ----
  (global $HULL_MAX f32 (f32.const 3.0))
  (global $CHARGE_MAX f32 (f32.const 100.0))
  (global $CHARGE_GRAZE f32 (f32.const 9.0))      ;; at maximum tightness
  (global $CHARGE_SQUEEZE f32 (f32.const 22.0))
  (global $MULT_MAX f32 (f32.const 9.0))
  ;; The multiplier bleeds off with *distance flown clean*, not with time. Tied
  ;; to a clock it would punish nothing in particular; tied to the board, it
  ;; says plainly that a stretch of safe flying costs you, which is the one
  ;; thing this game needs the player to believe.
  (global $MULT_DECAY_PX f32 (f32.const 1100.0))

  ;; ---- scoring ----
  (global $SCORE_PER_PX f32 (f32.const 0.04))
  (global $SCORE_GRAZE f32 (f32.const 30.0))      ;; at maximum tightness
  (global $SCORE_SQUEEZE f32 (f32.const 140.0))
  (global $SCORE_OVERCHARGE f32 (f32.const 250.0))

  (global $rng (mut i32) (i32.const 987654323))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $dist (mut f32) (f32.const 0.0))
  (global $hull (mut f32) (f32.const 3.0))
  (global $charge (mut f32) (f32.const 0.0))
  (global $mult (mut f32) (f32.const 1.0))
  (global $cleanPx (mut f32) (f32.const 0.0))
  (global $squeezeT (mut f32) (f32.const 0.0))
  (global $nextField (mut f32) (f32.const 520.0))
  (global $pathX (mut f32) (f32.const 480.0))

  ;; input, as reported by set_input each frame: -1..1, analogue
  (global $moveIn (mut f32) (f32.const 0.0))

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $grazes (mut i32) (i32.const 0))
  (global $squeezes (mut i32) (i32.const 0))
  (global $hits (mut i32) (i32.const 0))
  (global $patches (mut i32) (i32.const 0))
  (global $fields (mut i32) (i32.const 0))

  ;; ---------------- helpers ----------------

  (func $rock_addr (param $i i32) (result i32)
    (i32.add (global.get $ROCKS_OFF) (i32.mul (local.get $i) (global.get $ROCK_STRIDE))))

  (func $rand_f32 (result f32)
    (local $x i32)
    (local.set $x (global.get $rng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng (local.get $x))
    (f32.div (f32.convert_i32_u (local.get $x)) (f32.const 4294967296.0)))

  (func $frand (param $lo f32) (param $hi f32) (result f32)
    (f32.add (local.get $lo) (f32.mul (call $rand_f32) (f32.sub (local.get $hi) (local.get $lo)))))

  ;; Clamped, because $rand_f32 can return exactly 1.0: it divides a u32 by
  ;; 2^32 in f32, and f32 has 24 bits of mantissa, so the top 128 states round
  ;; up. One call in ~33 million, and every one of them would be an index one
  ;; past the end of whatever it was choosing from.
  (func $rand_below (param $n i32) (result i32)
    (call $clampi
      (i32.trunc_f32_s (call $frand (f32.const 0.0) (f32.convert_i32_s (local.get $n))))
      (i32.const 0) (i32.sub (local.get $n) (i32.const 1))))

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

  (func $ship_x (result f32) (f32.load (global.get $SHIP_OFF)))

  (func $km (result f32) (f32.div (global.get $dist) (f32.const 1000.0)))

  (func $speed (result f32)
    (call $clampf
      (f32.add (global.get $SPEED_BASE) (f32.mul (call $km) (global.get $SPEED_PER_KM)))
      (global.get $SPEED_BASE) (global.get $SPEED_CAP)))

  (func $field_gap (result f32)
    (call $clampf
      (f32.sub (global.get $FIELD_GAP) (f32.mul (call $km) (global.get $FIELD_GAP_STEP)))
      (global.get $FIELD_GAP_MIN) (global.get $FIELD_GAP)))

  ;; How far the corridor is allowed to move for the next field.
  (func $path_step (export "get_path_step") (result f32)
    (call $clampf
      (f32.mul (global.get $REACH_RATE) (f32.div (call $field_gap) (call $speed)))
      (global.get $PATH_STEP_MIN) (global.get $PATH_STEP_MAX)))

  (func $corridor (export "get_corridor") (result f32)
    (call $clampf
      (f32.sub (global.get $CORRIDOR) (f32.mul (call $km) (global.get $CORRIDOR_STEP)))
      (global.get $CORRIDOR_MIN) (global.get $CORRIDOR)))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  ;; Surface clearance between the ship and a rock: centre distance less both
  ;; radii. Negative is overlap. This is the only geometry in the file.
  (func $clearance (param $rx f32) (param $ry f32) (param $rr f32) (result f32)
    (local $dx f32) (local $dy f32)
    (local.set $dx (f32.sub (local.get $rx) (call $ship_x)))
    (local.set $dy (f32.sub (local.get $ry) (global.get $SHIP_Y)))
    (f32.sub
      (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx))
                         (f32.mul (local.get $dy) (local.get $dy))))
      (f32.add (local.get $rr) (global.get $SHIP_R))))

  ;; ---------------- spawning ----------------

  ;; Radius for a kind. Shards are the ones worth threading; boulders are there
  ;; to make the corridor matter.
  (func $kind_radius (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
      (then (call $frand (f32.const 30.0) (f32.const 41.0)))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (call $frand (f32.const 24.0) (f32.const 33.0)))
        (else (call $frand (f32.const 15.0) (f32.const 23.0)))))))

  (func $spawn_rock (param $x f32) (param $r f32) (param $kind i32) (result i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (f32.eq (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (f32.sub (f32.const -50.0) (local.get $r)))
            ;; Only a slab drifts, and only gently: a rock that crosses the
            ;; corridor after it was placed would undo the guarantee.
            (f32.store offset=8 (local.get $a)
              (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
                (then (call $frand (f32.const -34.0) (f32.const 34.0)))
                (else (f32.const 0.0))))
            (f32.store offset=12 (local.get $a) (local.get $r))
            (f32.store offset=16 (local.get $a) (f32.const 1.0))
            (f32.store offset=20 (local.get $a) (global.get $NEAR_NONE))
            (f32.store offset=24 (local.get $a) (call $frand (f32.const -1.6) (f32.const 1.6)))
            (f32.store offset=28 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=32 (local.get $a) (f32.const 0.0))
            (f32.store offset=36 (local.get $a) (global.get $pathX))
            (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const -1))

  ;; Does a rock of this size at this x collide with one already placed in the
  ;; field being built?
  ;;
  ;; "The field being built" is not tracked anywhere — it is simply every
  ;; active rock still above the top of the screen, because the fields are far
  ;; enough apart that no two are ever up there at once. At the speed cap a
  ;; field is 268px behind the last, which is 0.43s, and a rock clears the
  ;; spawn line in about 0.14s. Deriving it beats keeping a list in step with
  ;; the pool, which is one more thing that can silently drift.
  (func $field_overlaps (param $x f32) (param $r f32) (result i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
                     (f32.lt (f32.load offset=4 (local.get $a)) (f32.const 0.0)))
          (then
            (if (f32.lt (f32.abs (f32.sub (local.get $x) (f32.load offset=0 (local.get $a))))
                        (f32.add (f32.add (local.get $r) (f32.load offset=12 (local.get $a)))
                                 (f32.const 8.0)))
              (then (return (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))

  ;; How many rocks a field may hold. Three at the start, six by 4km — the ramp
  ;; is slow on purpose, because the corridor is narrowing underneath it and
  ;; the two curves multiply.
  (func $field_size (result i32)
    (call $clampi
      (i32.add (i32.const 3) (i32.trunc_f32_s (f32.div (call $km) (f32.const 15.0))))
      (i32.const 3) (global.get $MAX_IN_FIELD)))

  ;; One field of debris.
  ;;
  ;; **Every field leaves a corridor, and the corridor moves by at most
  ;; $PATH_STEP.** This is Circuit Runner's guarantee, ported from six discrete
  ;; lanes to an analogue x, and it exists for the same reason: fields
  ;; generated independently can each be fair and collectively impossible, and
  ;; the bench finds that in about ninety seconds. What it buys here is more
  ;; than fairness, though — a guaranteed *safe* line is what makes every other
  ;; gap on the board a genuine choice. The player is never dodging; they are
  ;; deciding how much of the corridor to give up for a squeeze.
  (func $spawn_field
    (local $n i32) (local $placed i32) (local $tries i32)
    (local $x f32) (local $r f32) (local $kind i32) (local $half f32) (local $idx i32)

    (global.set $pathX
      (call $clampf
        (f32.add (global.get $pathX)
                 (call $frand (f32.neg (call $path_step)) (call $path_step)))
        (f32.add (global.get $SHIP_MARGIN) (f32.mul (call $corridor) (f32.const 0.5)))
        (f32.sub (f32.sub (global.get $WORLD_W) (global.get $SHIP_MARGIN))
                 (f32.mul (call $corridor) (f32.const 0.5)))))

    (local.set $half (f32.mul (call $corridor) (f32.const 0.5)))
    (local.set $n (call $field_size))
    (local.set $placed (i32.const 0))
    (local.set $tries (i32.const 0))

    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $placed) (local.get $n)))
        (br_if $done (i32.gt_s (local.get $tries) (i32.const 40)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))

        (local.set $kind (call $rand_below (i32.const 3)))
        (local.set $r (call $kind_radius (local.get $kind)))
        (local.set $x (call $frand
          (f32.add (f32.const 6.0) (local.get $r))
          (f32.sub (global.get $WORLD_W) (f32.add (f32.const 6.0) (local.get $r)))))

        ;; Never intrude on the corridor. A slab may drift, so it is held a
        ;; further 40px clear — the width it can wander in the ~1.5s it takes
        ;; to reach the ship.
        (br_if $lp (f32.lt (f32.abs (f32.sub (local.get $x) (global.get $pathX)))
                           (f32.add (f32.add (local.get $half) (local.get $r))
                                    (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
                                      (then (f32.const 40.0)) (else (f32.const 0.0))))))
        (br_if $lp (call $field_overlaps (local.get $x) (local.get $r)))

        ;; A full pool means the board is already saturated; stop rather than
        ;; spinning out the try budget placing nothing.
        (local.set $idx (call $spawn_rock (local.get $x) (local.get $r) (local.get $kind)))
        (br_if $done (i32.lt_s (local.get $idx) (i32.const 0)))
        (local.set $placed (i32.add (local.get $placed) (i32.const 1)))
        (br $lp)))

    (global.set $fields (i32.add (global.get $fields) (i32.const 1))))

  ;; ---------------- the ship ----------------

  (func $set_input (export "set_input") (param $move f32)
    (global.set $moveIn (call $clampf (local.get $move) (f32.const -1.0) (f32.const 1.0))))

  (func $step_ship (param $dt f32)
    (local $x f32) (local $vx f32)
    (if (f32.gt (f32.load offset=12 (global.get $SHIP_OFF)) (f32.const 0.0))
      (then (f32.store offset=12 (global.get $SHIP_OFF)
              (f32.sub (f32.load offset=12 (global.get $SHIP_OFF)) (local.get $dt)))))

    (local.set $x (call $ship_x))
    (local.set $vx (f32.load offset=4 (global.get $SHIP_OFF)))
    (local.set $vx (f32.add (local.get $vx)
      (f32.mul (f32.mul (global.get $moveIn) (global.get $THRUST)) (local.get $dt))))
    (local.set $vx (f32.mul (local.get $vx)
      (call $clampf (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))
                    (f32.const 0.0) (f32.const 1.0))))
    (local.set $vx (call $clampf (local.get $vx)
      (f32.neg (global.get $MAX_VX)) (global.get $MAX_VX)))
    (local.set $x (f32.add (local.get $x) (f32.mul (local.get $vx) (local.get $dt))))

    ;; The walls stop the ship rather than bouncing it. A bounce off the edge
    ;; would hand back momentum the player did not ask for, at the exact moment
    ;; they are least able to spend it.
    (if (f32.lt (local.get $x) (global.get $SHIP_MARGIN))
      (then (local.set $x (global.get $SHIP_MARGIN)) (local.set $vx (f32.const 0.0))))
    (if (f32.gt (local.get $x) (f32.sub (global.get $WORLD_W) (global.get $SHIP_MARGIN)))
      (then
        (local.set $x (f32.sub (global.get $WORLD_W) (global.get $SHIP_MARGIN)))
        (local.set $vx (f32.const 0.0))))

    (f32.store offset=0 (global.get $SHIP_OFF) (local.get $x))
    (f32.store offset=4 (global.get $SHIP_OFF) (local.get $vx)))

  ;; ---------------- graze, squeeze, hull ----------------

  ;; Banked charge patches a plate. With the hull already full it becomes
  ;; score instead, so a clean run through a dense field is never wasted —
  ;; without that, a player at full hull has no reason to graze at all, which
  ;; would switch the game off exactly when it is going well.
  (func $spend_charge
    (block $done
      (loop $lp
        (br_if $done (f32.lt (global.get $charge) (global.get $CHARGE_MAX)))
        (global.set $charge (f32.sub (global.get $charge) (global.get $CHARGE_MAX)))
        (if (f32.lt (global.get $hull) (global.get $HULL_MAX))
          (then
            (global.set $hull (f32.add (global.get $hull) (f32.const 1.0)))
            (global.set $patches (i32.add (global.get $patches) (i32.const 1))))
          (else (call $add_score (f32.mul (global.get $SCORE_OVERCHARGE) (global.get $mult)))))
        (br $lp))))

  ;; Settle up for one rock that has finished its pass. `near` is its tightest
  ;; clearance; `tight` is that as a 0..1 fraction of the band, so a pass at
  ;; the very edge is worth almost nothing and one at two pixels is worth all
  ;; of it.
  (func $resolve_graze (param $near f32)
    (local $tight f32)
    (local.set $tight (call $clampf
      (f32.div (f32.sub (global.get $GRAZE_BAND) (local.get $near)) (global.get $GRAZE_BAND))
      (f32.const 0.0) (f32.const 1.0)))

    (call $add_score (f32.mul (f32.mul (global.get $SCORE_GRAZE) (local.get $tight))
                              (global.get $mult)))
    (global.set $charge (f32.add (global.get $charge)
      (f32.mul (global.get $CHARGE_GRAZE) (local.get $tight))))
    (global.set $grazes (i32.add (global.get $grazes) (i32.const 1)))
    (global.set $cleanPx (f32.const 0.0))

    ;; A second graze inside the window means one gap was threaded, not two
    ;; rocks passed. Only that raises the multiplier — flying close to a single
    ;; rock is worth points, but going *between* two is the game.
    (if (f32.gt (global.get $squeezeT) (f32.const 0.0))
      (then
        (global.set $squeezes (i32.add (global.get $squeezes) (i32.const 1)))
        (call $add_score (f32.mul (global.get $SCORE_SQUEEZE) (global.get $mult)))
        (global.set $charge (f32.add (global.get $charge) (global.get $CHARGE_SQUEEZE)))
        (global.set $mult (f32.min (f32.add (global.get $mult) (f32.const 1.0))
                                   (global.get $MULT_MAX)))))
    ;; Re-armed either way: four rocks the ship threaded is three gaps, not
    ;; one, and the player who managed it should be paid for all three.
    (global.set $squeezeT (global.get $SQUEEZE_WINDOW))

    (call $spend_charge))

  (func $take_hit (param $a i32)
    (global.set $hits (i32.add (global.get $hits) (i32.const 1)))
    (global.set $hull (f32.sub (global.get $hull) (f32.const 1.0)))
    (f32.store offset=12 (global.get $SHIP_OFF) (global.get $INVULN_TIME))
    ;; The rock is consumed, as in circuit-runner: leaving it live would
    ;; re-trigger every frame the ship overlapped it.
    (f32.store offset=16 (local.get $a) (f32.const 0.0))
    ;; A hit is paid for in the currency the player was building, not just in
    ;; hull. Halving rather than clearing the charge was the tuning that made
    ;; a first hit recoverable — see the README.
    (global.set $mult (f32.const 1.0))
    (global.set $charge (f32.mul (global.get $charge) (f32.const 0.5)))
    (global.set $squeezeT (f32.const 0.0))
    (if (f32.le (global.get $hull) (f32.const 0.0))
      (then
        (global.set $hull (f32.const 0.0))
        (global.set $gameOver (i32.const 1)))))

  ;; ---------------- the board ----------------

  (func $step_rocks (param $dt f32)
    (local $i i32) (local $a i32) (local $y f32) (local $x f32) (local $sp f32)
    (local $cl f32) (local $near f32) (local $r f32)
    (local.set $sp (call $speed))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $r (f32.load offset=12 (local.get $a)))
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
                                   (f32.mul (local.get $sp) (local.get $dt))))
            (local.set $x (f32.add (f32.load offset=0 (local.get $a))
                                   (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt))))
            ;; A drifting slab turns round at the walls rather than leaving.
            (if (i32.or (f32.lt (local.get $x) (local.get $r))
                        (f32.gt (local.get $x) (f32.sub (global.get $WORLD_W) (local.get $r))))
              (then
                (local.set $x (call $clampf (local.get $x) (local.get $r)
                                    (f32.sub (global.get $WORLD_W) (local.get $r))))
                (f32.store offset=8 (local.get $a)
                  (f32.neg (f32.load offset=8 (local.get $a))))))
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))

            (if (f32.gt (local.get $y) (f32.add (global.get $WORLD_H) (f32.const 60.0)))
              (then (f32.store offset=16 (local.get $a) (f32.const 0.0)))
              (else
                ;; Only track a rock while it is anywhere near the ship's row.
                ;; Outside that window the clearance is dominated by the y
                ;; term and says nothing about how the pass went.
                (if (f32.lt (f32.abs (f32.sub (local.get $y) (global.get $SHIP_Y)))
                            (f32.const 240.0))
                  (then
                    (local.set $cl (call $clearance (local.get $x) (local.get $y) (local.get $r)))
                    (if (f32.lt (local.get $cl) (f32.load offset=20 (local.get $a)))
                      (then (f32.store offset=20 (local.get $a) (local.get $cl))))
                    (if (i32.and
                          (f32.le (local.get $cl) (f32.const 0.0))
                          (i32.and
                            (f32.le (f32.load offset=12 (global.get $SHIP_OFF)) (f32.const 0.0))
                            (f32.eq (f32.load offset=32 (local.get $a)) (f32.const 0.0))))
                      (then
                        (f32.store offset=32 (local.get $a) (f32.const 1.0))
                        (call $take_hit (local.get $a))))))

                ;; Past the ship and never settled: settle now.
                (if (i32.and
                      (f32.eq (f32.load offset=32 (local.get $a)) (f32.const 0.0))
                      (f32.gt (f32.sub (local.get $y) (local.get $r))
                              (f32.add (global.get $SHIP_Y) (global.get $SHIP_R))))
                  (then
                    (f32.store offset=32 (local.get $a) (f32.const 1.0))
                    (local.set $near (f32.load offset=20 (local.get $a)))
                    (if (i32.and (f32.gt (local.get $near) (f32.const 0.0))
                                 (f32.le (local.get $near) (global.get $GRAZE_BAND)))
                      (then (call $resolve_graze (local.get $near))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- state machine ----------------

  (func $clear_pool
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (f32.store offset=16 (call $rock_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $init (export "init")
    (global.set $rng (i32.const 987654323))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $dist (f32.const 0.0))
    (global.set $hull (global.get $HULL_MAX))
    (global.set $charge (f32.const 0.0))
    (global.set $mult (f32.const 1.0))
    (global.set $cleanPx (f32.const 0.0))
    (global.set $squeezeT (f32.const 0.0))
    (global.set $moveIn (f32.const 0.0))
    (global.set $pathX (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
    (global.set $grazes (i32.const 0))
    (global.set $squeezes (i32.const 0))
    (global.set $hits (i32.const 0))
    (global.set $patches (i32.const 0))
    (global.set $fields (i32.const 0))
    (call $clear_pool)
    ;; The first field is a long way off. An endless runner that opens with
    ;; debris on screen is asking for a reaction before the player has found
    ;; the controls.
    (global.set $nextField (f32.const 520.0))
    (f32.store offset=0 (global.get $SHIP_OFF) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
    (f32.store offset=4 (global.get $SHIP_OFF) (f32.const 0.0))
    (f32.store offset=8 (global.get $SHIP_OFF) (f32.const 1.0))
    (f32.store offset=12 (global.get $SHIP_OFF) (f32.const 0.0)))

  (func $step (export "step") (param $dt f32)
    (local $d f32) (local $sp f32) (local $travel f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))
    (local.set $sp (call $speed))
    (local.set $travel (f32.mul (local.get $sp) (local.get $d)))

    (call $step_ship (local.get $d))

    (global.set $dist (f32.add (global.get $dist) (local.get $travel)))
    ;; Distance scores flat, without the multiplier. The multiplier is what
    ;; risk buys; letting it apply to the metre count as well would mean the
    ;; best move after a squeeze is to stop taking any.
    (call $add_score (f32.mul (local.get $travel) (global.get $SCORE_PER_PX)))

    (if (f32.gt (global.get $squeezeT) (f32.const 0.0))
      (then (global.set $squeezeT (f32.sub (global.get $squeezeT) (local.get $d)))))

    ;; The multiplier bleeds off per 1100px flown without a graze.
    (global.set $cleanPx (f32.add (global.get $cleanPx) (local.get $travel)))
    (if (i32.and (f32.ge (global.get $cleanPx) (global.get $MULT_DECAY_PX))
                 (f32.gt (global.get $mult) (f32.const 1.0)))
      (then
        (global.set $mult (f32.sub (global.get $mult) (f32.const 1.0)))
        (global.set $cleanPx (f32.sub (global.get $cleanPx) (global.get $MULT_DECAY_PX)))))
    (if (f32.gt (global.get $cleanPx) (f32.mul (global.get $MULT_DECAY_PX) (f32.const 2.0)))
      (then (global.set $cleanPx (global.get $MULT_DECAY_PX))))

    (if (f32.ge (global.get $dist) (global.get $nextField))
      (then
        (global.set $nextField (f32.add (global.get $nextField) (call $field_gap)))
        (call $spawn_field)))

    (call $step_rocks (local.get $d)))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_dist (export "get_dist") (result f32) (global.get $dist))
  (func $get_speed (export "get_speed") (result f32) (call $speed))
  (func $get_speed_base (export "get_speed_base") (result f32) (global.get $SPEED_BASE))
  (func $get_hull (export "get_hull") (result f32) (global.get $hull))
  (func $get_hull_max (export "get_hull_max") (result f32) (global.get $HULL_MAX))
  (func $get_charge (export "get_charge") (result f32) (global.get $charge))
  (func $get_charge_max (export "get_charge_max") (result f32) (global.get $CHARGE_MAX))
  (func $get_mult (export "get_mult") (result f32) (global.get $mult))
  (func $get_mult_frac (export "get_mult_frac") (result f32)
    ;; How much of the current multiplier step is left before it bleeds — the
    ;; HUD draws this as a draining underline, which is the only warning the
    ;; player gets that flying clean is costing them.
    (f32.sub (f32.const 1.0)
      (call $clampf (f32.div (global.get $cleanPx) (global.get $MULT_DECAY_PX))
                    (f32.const 0.0) (f32.const 1.0))))
  (func $get_ship_x (export "get_ship_x") (result f32) (call $ship_x))
  (func $get_ship_y (export "get_ship_y") (result f32) (global.get $SHIP_Y))
  (func $get_ship_vx (export "get_ship_vx") (result f32)
    (f32.load offset=4 (global.get $SHIP_OFF)))
  (func $get_ship_r (export "get_ship_r") (result f32) (global.get $SHIP_R))
  (func $get_invuln (export "get_invuln") (result f32)
    (f32.load offset=12 (global.get $SHIP_OFF)))
  (func $get_graze_band (export "get_graze_band") (result f32) (global.get $GRAZE_BAND))
  (func $get_path_x (export "get_path_x") (result f32) (global.get $pathX))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_grazes (export "get_grazes") (result i32) (global.get $grazes))
  (func $get_squeezes (export "get_squeezes") (result i32) (global.get $squeezes))
  (func $get_hits (export "get_hits") (result i32) (global.get $hits))
  (func $get_patches (export "get_patches") (result i32) (global.get $patches))
  (func $get_fields (export "get_fields") (result i32) (global.get $fields))
)
