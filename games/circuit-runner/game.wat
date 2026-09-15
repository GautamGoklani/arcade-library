(module
  ;; ============================================================
  ;; CIRCUIT RUNNER — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as the other five (globals block
  ;; at the top, entity pools at fixed offsets in linear memory, xorshift RNG,
  ;; an init/set_input/step/get_* export surface) and nothing else. Every
  ;; constant and every routine below is its own.
  ;;
  ;; What is new here, and what the rest of the library did not need:
  ;;
  ;;   • Nothing to shoot. Every other title here answers a threat by removing
  ;;     it. This one has no weapon at all: the only verb is which trace you
  ;;     are standing on, and the only answers are dodge, time it, or take it.
  ;;   • One meter, and it only goes down. Current drains continuously, drains
  ;;     faster the quicker you are going, and is refilled solely by what you
  ;;     collect. There is no regeneration and there are no lives — running out
  ;;     is the single failure state, so every hit is a withdrawal rather than
  ;;     a strike against you.
  ;;   • A hazard that is only dangerous half the time. Capacitors charge and
  ;;     discharge on their own clock, which turns a lane into a gate you read
  ;;     rather than a wall you avoid.
  ;;
  ;; There are **no imports**, as in worm-chase and sector-defense: the board
  ;; scrolls on one axis, the runner slides along another, and every collision
  ;; is an axis-aligned box test. No angle, no sqrt, nothing to ask JS for.
  ;;
  ;; JavaScript owns no game state. It forwards input, calls step(dt), and
  ;; reads entity records straight out of the memory below to draw them.
  ;; ============================================================

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; runner   @0    : x, lane, targetLane, stun, alive     (5 f32, padded to 24)
  ;; parts    @24   : stride 32, MAX_PARTS = 24
  ;;                  x, y, lane, kind, active, span, timer, charged
  ;;                  ends at 24 + 24*32 = 792
  ;; pickups  @792  : stride 24, MAX_PICKUPS = 20
  ;;                  x, y, lane, kind, active, phase
  ;;                  ends at 792 + 20*24 = 1272
  ;;
  ;; part kinds:   0 = resistor (one lane), 1 = capacitor (one lane, gated),
  ;;               2 = chip (two lanes), 3 = solder bridge (two lanes)
  ;; pickup kinds: 0 = charge, 1 = overclock
  ;;
  ;; `charged` is a capacitor's live state, 1 while it will kill you and 0
  ;; while it is discharged; `timer` counts down to the next flip. Both are
  ;; meaningless for the other kinds. `span` is how many lanes the part covers,
  ;; starting at `lane`.
  ;;
  ;; Scalars — score, current, speed, distance — live in globals rather than
  ;; memory, as in the other recent titles: the get_* readers are the only
  ;; consumer, and a global is one instruction to read.
  ;;
  ;; The field lists above, once more, in the form scripts/check-layout.mjs
  ;; reads. It fails if any line here disagrees with the prose, overflows
  ;; its stride, or disagrees with the FIELD table at the top of the widget
  ;; — so a field that moves has to move in all three places at once.
  ;; @fields runner f32 -: x lane targetLane stun alive
  ;; @fields part   f32 PART_STRIDE: x y lane kind active span timer charged
  ;; @fields pickup f32 PICKUP_STRIDE: x y lane kind active phase
  ;; ===================================================

  (global $RUNNER_OFF i32 (i32.const 0))
  (global $PARTS_OFF i32 (i32.const 24))
  (global $PART_STRIDE i32 (i32.const 32))
  (global $MAX_PARTS i32 (i32.const 24))
  (global $PICKUPS_OFF i32 (i32.const 792))
  (global $PICKUP_STRIDE i32 (i32.const 24))
  (global $MAX_PICKUPS i32 (i32.const 20))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))

  ;; ---- the board ----
  ;; Six traces across 960 gives a 160px lane: wide enough that a part reads as
  ;; sitting *on* a trace rather than between two, and few enough that the
  ;; whole board can be taken in without scanning.
  (global $LANES i32 (i32.const 6))
  (global $LANE_W f32 (f32.const 160.0))

  ;; ---- the runner ----
  (global $RUNNER_Y f32 (f32.const 588.0))
  (global $RUNNER_HALF_W f32 (f32.const 22.0))
  (global $RUNNER_HALF_H f32 (f32.const 26.0))
  ;; The slide between lanes is deliberately not instant. Collision tests the
  ;; runner's actual x, so a switch begun too late clips the part you were
  ;; trying to avoid — which is what makes committing to a lane a decision
  ;; rather than a reflex you can always take back.
  (global $SLIDE_SPEED f32 (f32.const 900.0))
  ;; A hit sparks the runner: it cannot steer for this long, and cannot be hit
  ;; again either. The immunity is the important half — without it a wide row
  ;; lands a second hit on a runner it has just frozen, and two hits is most of
  ;; the meter, which reads as the game cheating rather than as one mistake.
  (global $STUN_TIME f32 (f32.const 0.45))

  ;; ---- scrolling ----
  ;; Speed is a function of distance, not of a level counter: the board simply
  ;; gets faster the further you get, which is the only difficulty curve an
  ;; endless runner needs. 250 is a walk; 640 is as fast as the lane slide can
  ;; still answer.
  (global $SPEED_BASE f32 (f32.const 250.0))
  ;; 42 reached the cap in about twenty-five seconds, which is not a ramp, it
  ;; is a countdown to top speed. 18 puts the cap a little over a minute in, so
  ;; the opening is walkable and the board tightens under you rather than at you.
  (global $SPEED_PER_KM f32 (f32.const 18.0))   ;; added per 1000px travelled
  (global $SPEED_CAP f32 (f32.const 640.0))

  ;; ---- current ----
  (global $CURRENT_MAX f32 (f32.const 100.0))
  (global $CURRENT_START f32 (f32.const 85.0))
  ;; Drain is per second at SPEED_BASE and scales with how fast you are going,
  ;; so going faster costs more than it earns unless you are picking things up.
  ;;
  ;; It opened at 5.2, which made a run a countdown rather than an economy: the
  ;; bench could not survive fourteen rows whatever it did, because the meter
  ;; ran out before the board had asked it a hard question. At 3.4 a clean line
  ;; through the charges gains slowly and a sloppy one loses slowly, which is
  ;; the balance an endless runner wants.
  (global $DRAIN_BASE f32 (f32.const 3.4))
  (global $HIT_COST f32 (f32.const 20.0))
  (global $CHARGE_GAIN f32 (f32.const 17.0))
  (global $OVERCLOCK_TIME f32 (f32.const 6.0))

  ;; ---- spawning ----
  ;; Rows arrive on a distance clock rather than a wall clock. At a fixed time
  ;; interval a faster board would space parts further apart, which is exactly
  ;; backwards — the board would get *easier* as it sped up.
  (global $ROW_GAP f32 (f32.const 300.0))
  (global $ROW_GAP_MIN f32 (f32.const 172.0))
  (global $ROW_GAP_STEP f32 (f32.const 8.0))    ;; closer per 1000px
  (global $PART_HALF_H f32 (f32.const 30.0))
  (global $PICKUP_HALF f32 (f32.const 18.0))
  (global $CAP_PERIOD f32 (f32.const 1.35))     ;; seconds per capacitor flip

  ;; ---- scoring ----
  (global $SCORE_PER_PX f32 (f32.const 0.05))
  (global $SCORE_CHARGE f32 (f32.const 40.0))

  (global $rng (mut i32) (i32.const 1597334677))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $current (mut f32) (f32.const 85.0))
  (global $dist (mut f32) (f32.const 0.0))
  (global $nextRow (mut f32) (f32.const 240.0))  ;; distance at which the next row spawns
  (global $overclock (mut f32) (f32.const 0.0))
  (global $stun (mut f32) (f32.const 0.0))
  ;; Which lanes the row currently being built has already blocked, one bit
  ;; per lane. Lives across the calls $spawn_row makes rather than being
  ;; threaded through them, and is cleared when the row is finished.
  (global $rowMask (mut i32) (i32.const 0))
  ;; The lane the guaranteed path runs through. It wanders by at most one lane
  ;; per row and no part may ever cover it — see $spawn_row.
  (global $pathLane (mut i32) (i32.const 2))

  ;; input, as reported by set_input each frame
  (global $moveIn (mut i32) (i32.const 0))       ;; -1, 0 or 1, edge-triggered

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $switches (mut i32) (i32.const 0))
  (global $hits (mut i32) (i32.const 0))
  (global $charges (mut i32) (i32.const 0))
  (global $boosts (mut i32) (i32.const 0))
  (global $rows (mut i32) (i32.const 0))

  ;; ---------------- helpers ----------------

  (func $part_addr (param $i i32) (result i32)
    (i32.add (global.get $PARTS_OFF) (i32.mul (local.get $i) (global.get $PART_STRIDE))))
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

  (func $frand (param $lo f32) (param $hi f32) (result f32)
    (f32.add (local.get $lo) (f32.mul (call $rand_f32) (f32.sub (local.get $hi) (local.get $lo)))))

  ;; The clamp is not belt and braces. $rand_f32 divides a u32 by 2^32 in f32,
  ;; and f32 has 24 bits of mantissa: the top 128 states round *up* to exactly
  ;; 1.0, so one call in ~33 million returns n instead of n-1. Everything that
  ;; number reaches here is an index — a lane, a kind — and one of them is the
  ;; guarantee this whole engine is built on: $spawn_row walks $pathLane by
  ;; `rand_below(3) - 1`, and a 2 there moves the path two lanes in one row,
  ;; which is the sequence the board is specifically constructed never to
  ;; produce. Clamping here rather than in $rand_f32 leaves the RNG stream
  ;; untouched, so every tuning number measured against it still holds.
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

  ;; Centre of a lane. Lane 0 is the leftmost trace.
  (func $lane_x (param $lane i32) (result f32)
    (f32.mul (f32.add (f32.convert_i32_s (local.get $lane)) (f32.const 0.5))
             (global.get $LANE_W)))

  (func $overlap (param $ax f32) (param $ay f32) (param $ahw f32) (param $ahh f32)
                 (param $bx f32) (param $by f32) (param $bhw f32) (param $bhh f32) (result i32)
    (i32.and
      (f32.lt (f32.abs (f32.sub (local.get $ax) (local.get $bx)))
              (f32.add (local.get $ahw) (local.get $bhw)))
      (f32.lt (f32.abs (f32.sub (local.get $ay) (local.get $by)))
              (f32.add (local.get $ahh) (local.get $bhh)))))

  (func $runner_x (result f32) (f32.load (global.get $RUNNER_OFF)))

  ;; How many 1000px units have been travelled, as a float.
  (func $km (result f32)
    (f32.div (global.get $dist) (f32.const 1000.0)))

  (func $speed (result f32)
    (call $clampf
      (f32.add (global.get $SPEED_BASE) (f32.mul (call $km) (global.get $SPEED_PER_KM)))
      (global.get $SPEED_BASE) (global.get $SPEED_CAP)))

  (func $row_gap (result f32)
    (call $clampf
      (f32.sub (global.get $ROW_GAP) (f32.mul (call $km) (global.get $ROW_GAP_STEP)))
      (global.get $ROW_GAP_MIN) (global.get $ROW_GAP)))

  ;; Half-width of a part covering `span` lanes.
  ;;
  ;; The 26px inset is a geometry constraint, not a style choice. A runner
  ;; sliding between two lanes passes through the boundary, 80px from the
  ;; blocked lane's centre; for that crossing not to clip, the part's half-width
  ;; plus the runner's 22 must stay under 80. At the first build's 16px inset it
  ;; was 64 + 22 = 86, so *passing* a blocked lane hit it — which meant a free
  ;; lane two across with a blocked lane between was unreachable, and the bench
  ;; took a hit every two seconds while playing correctly. 26 gives 54 + 22 = 76
  ;; and four pixels of margin.
  (func $part_half_w (param $span i32) (result f32)
    (f32.sub (f32.mul (f32.convert_i32_s (local.get $span)) (f32.mul (global.get $LANE_W) (f32.const 0.5)))
             (f32.const 26.0)))

  (func $part_cx (param $lane i32) (param $span i32) (result f32)
    (f32.mul (f32.add (f32.convert_i32_s (local.get $lane))
                      (f32.mul (f32.convert_i32_s (local.get $span)) (f32.const 0.5)))
             (global.get $LANE_W)))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  ;; Is this part lethal right now? Only a capacitor is ever anything but yes.
  (func $part_live (param $a i32) (result i32)
    (if (result i32) (f32.eq (f32.load offset=12 (local.get $a)) (f32.const 1.0))
      (then (f32.ne (f32.load offset=28 (local.get $a)) (f32.const 0.0)))
      (else (i32.const 1))))

  ;; ---------------- spawning ----------------

  (func $spawn_part (param $lane i32) (param $kind i32) (param $span i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PARTS)))
        (local.set $a (call $part_addr (local.get $i)))
        (if (f32.eq (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (call $part_cx (local.get $lane) (local.get $span)))
            (f32.store offset=4 (local.get $a) (f32.const -60.0))
            (f32.store offset=8 (local.get $a) (f32.convert_i32_s (local.get $lane)))
            (f32.store offset=12 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=16 (local.get $a) (f32.const 1.0))
            (f32.store offset=20 (local.get $a) (f32.convert_i32_s (local.get $span)))
            ;; A capacitor arrives with a random phase so a row of them is a
            ;; pattern to read rather than a single wall blinking in unison.
            (f32.store offset=24 (local.get $a)
              (call $frand (f32.const 0.1) (global.get $CAP_PERIOD)))
            (f32.store offset=28 (local.get $a)
              (if (result f32) (i32.lt_s (call $rand_below (i32.const 2)) (i32.const 1))
                (then (f32.const 0.0)) (else (f32.const 1.0))))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $spawn_pickup (param $lane i32) (param $kind i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
        (local.set $a (call $pickup_addr (local.get $i)))
        (if (f32.eq (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (call $lane_x (local.get $lane)))
            (f32.store offset=4 (local.get $a) (f32.const -40.0))
            (f32.store offset=8 (local.get $a) (f32.convert_i32_s (local.get $lane)))
            (f32.store offset=12 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=16 (local.get $a) (f32.const 1.0))
            (f32.store offset=20 (local.get $a) (call $frand (f32.const 0.0) (f32.const 6.0)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; How many lanes a row is allowed to block. Two of six at the start, rising
  ;; to three — never four, because at 2200px of ramp per step a fourth blocked
  ;; lane arrives at a board speed where the two open lanes left are further
  ;; apart than the slide can cross between rows, and a gap that cannot be
  ;; reached is not a gap.
  (func $max_blocked (result i32)
    (call $clampi
      (i32.add (i32.const 2) (i32.trunc_f32_s (f32.div (call $km) (f32.const 2.2))))
      (i32.const 2) (i32.const 3)))

  ;; Which kinds are in play. Resistors from the start; capacitors once the
  ;; player has had a stretch to learn the lane slide; the two-lane parts after
  ;; that, because they are the ones that force a decision early.
  (func $kinds_in_play (result i32)
    (if (result i32) (f32.lt (call $km) (f32.const 0.9))
      (then (i32.const 1))
      (else (if (result i32) (f32.lt (call $km) (f32.const 2.0))
        (then (i32.const 2))
        (else (i32.const 4))))))

  ;; One row of board: some lanes blocked, and usually something to collect in
  ;; a lane that is not.
  ;;
  ;; **Every row leaves a path, and the path moves by at most one lane.** Rows
  ;; generated independently can be individually fair and collectively
  ;; impossible: at the speed cap there is time to cross about one and a half
  ;; lanes between rows, so two consecutive rows whose gaps are three lanes
  ;; apart cannot be threaded by anything. The first build did exactly that and
  ;; the bench took a hit every two seconds — not because any row was unfair,
  ;; but because the *sequence* was. Reserving a wandering lane that no part may
  ;; cover makes the board passable by construction, and leaves the difficulty
  ;; where it belongs: in reading which lane that is, and in what it costs to
  ;; leave it for a charge.
  (func $spawn_row
    (local $blocked i32) (local $n i32) (local $tries i32)
    (local $lane i32) (local $kind i32) (local $span i32) (local $free i32)
    (global.set $pathLane
      (call $clampi
        (i32.add (global.get $pathLane) (i32.sub (call $rand_below (i32.const 3)) (i32.const 1)))
        (i32.const 0) (i32.sub (global.get $LANES) (i32.const 1))))
    (local.set $n (i32.add (i32.const 1) (call $rand_below (call $max_blocked))))
    (local.set $blocked (i32.const 0))
    (local.set $tries (i32.const 0))

    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $blocked) (local.get $n)))
        (br_if $done (i32.gt_s (local.get $tries) (i32.const 24)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))

        (local.set $kind (call $rand_below (call $kinds_in_play)))
        (local.set $span
          (if (result i32) (i32.ge_s (local.get $kind) (i32.const 2))
            (then (i32.const 2)) (else (i32.const 1))))
        (local.set $lane (call $rand_below (i32.sub (global.get $LANES) (i32.sub (local.get $span) (i32.const 1)))))

        ;; Would this take the row past its budget? Skip it rather than
        ;; shrinking it — a two-lane part that became one-lane would make the
        ;; kinds unreadable.
        (br_if $lp (i32.gt_s (i32.add (local.get $blocked) (local.get $span)) (local.get $n)))
        ;; Never cover the path lane, and never overlap a lane this row has
        ;; already taken — the second would spend the budget twice.
        (br_if $lp (i32.ne (i32.and (call $span_mask (local.get $lane) (local.get $span))
                                    (i32.shl (i32.const 1) (global.get $pathLane)))
                           (i32.const 0)))
        (br_if $lp (i32.ne (i32.and (global.get $rowMask)
                                    (call $span_mask (local.get $lane) (local.get $span)))
                           (i32.const 0)))

        (global.set $rowMask
          (i32.or (global.get $rowMask) (call $span_mask (local.get $lane) (local.get $span))))
        (call $spawn_part (local.get $lane) (local.get $kind) (local.get $span))
        (local.set $blocked (i32.add (local.get $blocked) (local.get $span)))
        (br $lp)))

    ;; Something to collect, in a lane this row left open.
    (local.set $free (call $free_lane_near_runner))
    (if (i32.ge_s (local.get $free) (i32.const 0))
      (then
        (if (f32.lt (call $rand_f32) (f32.const 0.85))
          (then
            (call $spawn_pickup (local.get $free)
              (if (result i32) (f32.lt (call $rand_f32) (f32.const 0.12))
                (then (i32.const 1)) (else (i32.const 0))))))))

    (global.set $rowMask (i32.const 0))
    (global.set $rows (i32.add (global.get $rows) (i32.const 1))))

  ;; Bit per lane, `span` lanes wide starting at `lane`.
  (func $span_mask (param $lane i32) (param $span i32) (result i32)
    (i32.shl (i32.sub (i32.shl (i32.const 1) (local.get $span)) (i32.const 1)) (local.get $lane)))

  ;; An open lane for this row's pickup, searched outward from wherever the
  ;; runner is standing.
  ;;
  ;; Choosing uniformly at random — the first build — put most charges in lanes
  ;; the runner could not reach in time, and the bench collected two out of ten.
  ;; That is not a difficult economy, it is a lottery. Searching outward means
  ;; the charge is almost always one or two lanes away, so it *competes* with
  ;; the safe lane instead of being a gift: the interesting rows are the ones
  ;; where the charge is on the far side of a part.
  (func $free_lane_near_runner (result i32)
    (local $d i32) (local $home i32) (local $l i32)
    (local.set $home (i32.trunc_f32_s (f32.load offset=4 (global.get $RUNNER_OFF))))
    (local.set $d (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.gt_s (local.get $d) (global.get $LANES)))
        ;; left then right at each distance, so ties do not always resolve the
        ;; same way and a wall of rows does not drag the runner to one edge
        (local.set $l (i32.sub (local.get $home) (local.get $d)))
        (if (i32.and (i32.ge_s (local.get $l) (i32.const 0))
                     (i32.eqz (i32.and (global.get $rowMask)
                                       (i32.shl (i32.const 1) (local.get $l)))))
          (then (return (local.get $l))))
        (local.set $l (i32.add (local.get $home) (local.get $d)))
        (if (i32.and (i32.lt_s (local.get $l) (global.get $LANES))
                     (i32.eqz (i32.and (global.get $rowMask)
                                       (i32.shl (i32.const 1) (local.get $l)))))
          (then (return (local.get $l))))
        (local.set $d (i32.add (local.get $d) (i32.const 1)))
        (br $lp)))
    (i32.const -1))

  ;; ---------------- the runner ----------------

  (func $set_input (export "set_input") (param $move i32)
    (global.set $moveIn (call $clampi (local.get $move) (i32.const -1) (i32.const 1))))

  (func $step_runner (param $dt f32)
    (local $x f32) (local $target i32) (local $tx f32) (local $step f32)

    (if (f32.gt (global.get $stun) (f32.const 0.0))
      (then (global.set $stun (f32.sub (global.get $stun) (local.get $dt)))))

    ;; A lane change is refused while stunned and while one is already in
    ;; progress. Queueing them would let a player type ahead through a row they
    ;; have not seen yet, which is the whole skill being tested.
    (local.set $target (i32.trunc_f32_s (f32.load offset=8 (global.get $RUNNER_OFF))))
    (if (i32.and
          (i32.ne (global.get $moveIn) (i32.const 0))
          (i32.and (f32.le (global.get $stun) (f32.const 0.0))
                   (f32.lt (f32.abs (f32.sub (call $runner_x) (call $lane_x (local.get $target))))
                           (f32.const 6.0))))
      (then
        (local.set $target
          (call $clampi (i32.add (local.get $target) (global.get $moveIn))
                        (i32.const 0) (i32.sub (global.get $LANES) (i32.const 1))))
        (if (i32.ne (local.get $target)
                    (i32.trunc_f32_s (f32.load offset=8 (global.get $RUNNER_OFF))))
          (then
            (f32.store offset=8 (global.get $RUNNER_OFF) (f32.convert_i32_s (local.get $target)))
            (global.set $switches (i32.add (global.get $switches) (i32.const 1)))))))

    ;; Slide toward the target lane at a fixed rate.
    (local.set $x (call $runner_x))
    (local.set $tx (call $lane_x (local.get $target)))
    (local.set $step (f32.mul (global.get $SLIDE_SPEED) (local.get $dt)))
    (if (f32.le (f32.abs (f32.sub (local.get $tx) (local.get $x))) (local.get $step))
      (then (local.set $x (local.get $tx)))
      (else
        (if (f32.gt (local.get $tx) (local.get $x))
          (then (local.set $x (f32.add (local.get $x) (local.get $step))))
          (else (local.set $x (f32.sub (local.get $x) (local.get $step)))))))
    (f32.store offset=0 (global.get $RUNNER_OFF) (local.get $x))
    (f32.store offset=4 (global.get $RUNNER_OFF) (f32.convert_i32_s (local.get $target))))

  (func $take_hit (param $a i32)
    (global.set $hits (i32.add (global.get $hits) (i32.const 1)))
    (global.set $stun (global.get $STUN_TIME))
    (global.set $overclock (f32.const 0.0))
    ;; The part is consumed. Leaving it live would re-trigger every frame the
    ;; runner overlapped it, which at 26 current a hit is the whole meter in
    ;; under a second and reads as a bug rather than a mistake.
    (f32.store offset=16 (local.get $a) (f32.const 0.0))
    (global.set $current
      (call $clampf (f32.sub (global.get $current) (global.get $HIT_COST))
                    (f32.const 0.0) (global.get $CURRENT_MAX)))
    (if (f32.le (global.get $current) (f32.const 0.0))
      (then (global.set $gameOver (i32.const 1)))))

  ;; ---------------- the board ----------------

  (func $step_parts (param $dt f32)
    (local $i i32) (local $a i32) (local $y f32) (local $sp f32) (local $hw f32)
    (local.set $sp (call $speed))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PARTS)))
        (local.set $a (call $part_addr (local.get $i)))
        (if (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
                                   (f32.mul (local.get $sp) (local.get $dt))))
            (f32.store offset=4 (local.get $a) (local.get $y))

            ;; A capacitor flips between charged and discharged on its own
            ;; clock, independent of the board speed — so a faster board gives
            ;; you fewer flips to read, not slower ones.
            (if (f32.eq (f32.load offset=12 (local.get $a)) (f32.const 1.0))
              (then
                (f32.store offset=24 (local.get $a)
                  (f32.sub (f32.load offset=24 (local.get $a)) (local.get $dt)))
                (if (f32.le (f32.load offset=24 (local.get $a)) (f32.const 0.0))
                  (then
                    (f32.store offset=24 (local.get $a) (global.get $CAP_PERIOD))
                    (f32.store offset=28 (local.get $a)
                      (f32.sub (f32.const 1.0) (f32.load offset=28 (local.get $a))))))))

            (if (f32.gt (local.get $y) (f32.add (global.get $WORLD_H) (f32.const 60.0)))
              (then (f32.store offset=16 (local.get $a) (f32.const 0.0)))
              (else
                (if (i32.and (call $part_live (local.get $a))
                             (f32.le (global.get $stun) (f32.const 0.0)))
                  (then
                    (local.set $hw (call $part_half_w
                      (i32.trunc_f32_s (f32.load offset=20 (local.get $a)))))
                    (if (call $overlap
                          (call $runner_x) (global.get $RUNNER_Y)
                          (global.get $RUNNER_HALF_W) (global.get $RUNNER_HALF_H)
                          (f32.load offset=0 (local.get $a)) (local.get $y)
                          (local.get $hw) (global.get $PART_HALF_H))
                      (then (call $take_hit (local.get $a))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $step_pickups (param $dt f32)
    (local $i i32) (local $a i32) (local $y f32) (local $sp f32) (local $kind i32)
    (local.set $sp (call $speed))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PICKUPS)))
        (local.set $a (call $pickup_addr (local.get $i)))
        (if (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
                                   (f32.mul (local.get $sp) (local.get $dt))))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (if (f32.gt (local.get $y) (f32.add (global.get $WORLD_H) (f32.const 40.0)))
              (then (f32.store offset=16 (local.get $a) (f32.const 0.0)))
              (else
                (if (call $overlap
                      (call $runner_x) (global.get $RUNNER_Y)
                      (global.get $RUNNER_HALF_W) (global.get $RUNNER_HALF_H)
                      (f32.load offset=0 (local.get $a)) (local.get $y)
                      (global.get $PICKUP_HALF) (global.get $PICKUP_HALF))
                  (then
                    (local.set $kind (i32.trunc_f32_s (f32.load offset=12 (local.get $a))))
                    (f32.store offset=16 (local.get $a) (f32.const 0.0))
                    (if (i32.eq (local.get $kind) (i32.const 1))
                      (then
                        (global.set $overclock (global.get $OVERCLOCK_TIME))
                        (global.set $boosts (i32.add (global.get $boosts) (i32.const 1))))
                      (else
                        (global.set $current (call $clampf
                          (f32.add (global.get $current) (global.get $CHARGE_GAIN))
                          (f32.const 0.0) (global.get $CURRENT_MAX)))
                        (call $add_score (global.get $SCORE_CHARGE))
                        (global.set $charges
                          (i32.add (global.get $charges) (i32.const 1)))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- state machine ----------------

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

  (func $init (export "init")
    (global.set $rng (i32.const 1597334677))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $current (global.get $CURRENT_START))
    (global.set $dist (f32.const 0.0))
    (global.set $overclock (f32.const 0.0))
    (global.set $stun (f32.const 0.0))
    (global.set $moveIn (i32.const 0))
    (global.set $rowMask (i32.const 0))
    (global.set $pathLane (i32.const 2))
    (global.set $switches (i32.const 0))
    (global.set $hits (i32.const 0))
    (global.set $charges (i32.const 0))
    (global.set $boosts (i32.const 0))
    (global.set $rows (i32.const 0))
    (call $clear_pool (global.get $PARTS_OFF) (global.get $PART_STRIDE)
                      (global.get $MAX_PARTS) (i32.const 16))
    (call $clear_pool (global.get $PICKUPS_OFF) (global.get $PICKUP_STRIDE)
                      (global.get $MAX_PICKUPS) (i32.const 16))
    ;; The first row is a long way off. An endless runner that starts with an
    ;; obstacle on screen is asking for a reaction before the player has found
    ;; the controls.
    (global.set $nextRow (f32.const 420.0))
    (f32.store offset=0 (global.get $RUNNER_OFF) (call $lane_x (i32.const 2)))
    (f32.store offset=4 (global.get $RUNNER_OFF) (f32.const 2.0))
    (f32.store offset=8 (global.get $RUNNER_OFF) (f32.const 2.0))
    (f32.store offset=12 (global.get $RUNNER_OFF) (f32.const 0.0))
    (f32.store offset=16 (global.get $RUNNER_OFF) (f32.const 1.0)))

  (func $step (export "step") (param $dt f32)
    (local $d f32) (local $sp f32) (local $mult f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))
    (local.set $sp (call $speed))

    (call $step_runner (local.get $d))

    (global.set $dist (f32.add (global.get $dist) (f32.mul (local.get $sp) (local.get $d))))

    ;; Distance is the score, doubled while overclocked.
    (local.set $mult (if (result f32) (f32.gt (global.get $overclock) (f32.const 0.0))
      (then (f32.const 2.0)) (else (f32.const 1.0))))
    (call $add_score (f32.mul (f32.mul (f32.mul (local.get $sp) (local.get $d))
                                       (global.get $SCORE_PER_PX))
                              (local.get $mult)))
    (if (f32.gt (global.get $overclock) (f32.const 0.0))
      (then (global.set $overclock (f32.sub (global.get $overclock) (local.get $d)))))

    ;; Current drains with speed. This is the whole economy: the board gets
    ;; faster whether you like it or not, so the same route costs more the
    ;; further you get and you have to keep collecting to stand still.
    (global.set $current
      (call $clampf
        (f32.sub (global.get $current)
          (f32.mul (f32.mul (global.get $DRAIN_BASE)
                            (f32.div (local.get $sp) (global.get $SPEED_BASE)))
                   (local.get $d)))
        (f32.const 0.0) (global.get $CURRENT_MAX)))
    (if (f32.le (global.get $current) (f32.const 0.0))
      (then (global.set $gameOver (i32.const 1)) (return)))

    (if (f32.ge (global.get $dist) (global.get $nextRow))
      (then
        (global.set $nextRow (f32.add (global.get $nextRow) (call $row_gap)))
        (call $spawn_row)))

    (call $step_parts (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (call $step_pickups (local.get $d)))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_current (export "get_current") (result f32) (global.get $current))
  (func $get_current_max (export "get_current_max") (result f32) (global.get $CURRENT_MAX))
  (func $get_dist (export "get_dist") (result f32) (global.get $dist))
  (func $get_speed (export "get_speed") (result f32) (call $speed))
  (func $get_speed_base (export "get_speed_base") (result f32) (global.get $SPEED_BASE))
  (func $get_runner_x (export "get_runner_x") (result f32) (call $runner_x))
  (func $get_runner_y (export "get_runner_y") (result f32) (global.get $RUNNER_Y))
  (func $get_lane (export "get_lane") (result i32)
    (i32.trunc_f32_s (f32.load offset=4 (global.get $RUNNER_OFF))))
  (func $get_lanes (export "get_lanes") (result i32) (global.get $LANES))
  (func $get_lane_w (export "get_lane_w") (result f32) (global.get $LANE_W))
  (func $get_stun (export "get_stun") (result f32) (global.get $stun))
  (func $get_overclock (export "get_overclock") (result f32) (global.get $overclock))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_switches (export "get_switches") (result i32) (global.get $switches))
  (func $get_hits (export "get_hits") (result i32) (global.get $hits))
  (func $get_charges (export "get_charges") (result i32) (global.get $charges))
  (func $get_boosts (export "get_boosts") (result i32) (global.get $boosts))
  (func $get_rows (export "get_rows") (result i32) (global.get $rows))
)
