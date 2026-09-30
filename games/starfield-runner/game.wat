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
  ;; Every fourth field also carries a **gate**: two marked posts set exactly
  ;; far enough apart for the ship with $GATE_CLEAR to spare on each side, out
  ;; past the corridor. Thread it and both posts settle as a graze in the same
  ;; frame, and that squeeze pays double. It is the squeeze every other gap
  ;; on the board is an improvised version of, offered on purpose and priced
  ;; for the detour — see "the gate" below.
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
  ;; rocks  @16   : stride 40, MAX_ROCKS = 48
  ;;                x, y, vx, r, active, near, spin, kind, resolved, path
  ;;                ends at 16 + 48*40 = 1936
  ;;
  ;; rock kinds: 0 = shard, 1 = boulder, 2 = slab (the one that drifts),
  ;;             3 = leviathan body, 4 = leviathan head, 5 = gate post
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
  ;;
  ;; The field lists above, once more, in the form scripts/check-layout.mjs
  ;; reads. It fails if any line here disagrees with the prose, overflows
  ;; its stride, or disagrees with the FIELD table at the top of the widget
  ;; — so a field that moves has to move in all three places at once.
  ;; @fields ship f32 -: x vx alive invuln
  ;; @fields rock f32 ROCK_STRIDE: x y vx r active near spin kind resolved path
  ;; ===================================================

  (global $SHIP_OFF i32 (i32.const 0))
  (global $ROCKS_OFF i32 (i32.const 16))
  (global $ROCK_STRIDE i32 (i32.const 40))
  ;; 48, up from 26, for the leviathan: its three walls are about thirty
  ;; segments on screen at once, on top of whatever fields are still leaving.
  ;; Nothing lives after the rocks, so growing the pool moves no other offset.
  (global $MAX_ROCKS i32 (i32.const 48))

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
  ;; Mutable because the difficulty table writes them — see $apply_difficulty.
  ;; The initialisers are Normal's values, which is what makes a Normal run
  ;; identical to the engine that had no settings at all.
  (global $SPEED_BASE f32 (f32.const 250.0))
  (global $SPEED_PER_KM (mut f32) (f32.const 11.0))
  (global $SPEED_CAP (mut f32) (f32.const 620.0))

  ;; ---- the fields ----
  ;; Fields arrive on a distance clock, so a faster board is a *denser* one. On
  ;; a wall clock it would be the reverse, which is exactly backwards.
  (global $FIELD_GAP f32 (f32.const 400.0))
  (global $FIELD_GAP_MIN (mut f32) (f32.const 268.0))
  (global $FIELD_GAP_STEP (mut f32) (f32.const 2.6))   ;; closer per 1000px
  (global $MAX_IN_FIELD (mut i32) (i32.const 6))

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
  (global $CORRIDOR (mut f32) (f32.const 250.0))
  (global $CORRIDOR_MIN (mut f32) (f32.const 148.0))
  (global $CORRIDOR_STEP (mut f32) (f32.const 1.6))   ;; narrower per 1000px

  ;; ---- graze ----
  ;; How close counts. 30px against a 17px ship reads, on screen, as "you could
  ;; see daylight and it was thin" — wider and clean flying scores by accident,
  ;; narrower and the band is inside the sprite's own outline, so the player
  ;; cannot tell a graze from a miss and stops believing the score.
  (global $GRAZE_BAND (mut f32) (f32.const 30.0))
  ;; Two grazes this close together mean one gap, not two rocks.
  (global $SQUEEZE_WINDOW f32 (f32.const 0.34))
  (global $NEAR_NONE f32 (f32.const 9999.0))

  ;; ---- hull and charge ----
  (global $HULL_MAX (mut f32) (f32.const 3.0))
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

  ;; ---- the leviathan ----
  ;; The boss, and it is not shot, because nothing here is: it is threaded.
  ;; Every $LEV_EVERY_KM, starting at $LEV_FIRST_KM, the next three fields are
  ;; replaced by the leviathan — three walls of body segments across the whole
  ;; board, laid in a slow wave, head first. Each wall keeps the corridor
  ;; every field keeps, placed and moved by the same rule, so it is never
  ;; impassable. And each has one **rib gap**: a slot between two segments
  ;; exactly wide enough for the ship with $RIB_CLEAR to spare on each side,
  ;; which is inside the graze band on every setting — thread it and the two
  ;; segments settle as a squeeze.
  ;;
  ;; Get through all three walls without a hit and it banks $LEV_CHARGE: half a
  ;; plate. That makes the boss a repair, which is this game's scarce thing —
  ;; and a hit anywhere in it costs the bonus as well as the plate.
  (global $LEV_FIRST_KM f32 (f32.const 8.0))
  (global $LEV_EVERY_KM f32 (f32.const 16.0))
  (global $LEV_WALLS i32 (i32.const 3))
  (global $SEG_R f32 (f32.const 28.0))
  (global $SEG_STEP f32 (f32.const 60.0))       ;; centre to centre: 4px apart
  (global $RIB_CLEAR f32 (f32.const 12.0))      ;; each side of the ship
  (global $WAVE_AMP f32 (f32.const 36.0))       ;; how far the body bends, in y
  (global $LEV_CHARGE f32 (f32.const 50.0))
  (global $SCORE_LEVIATHAN f32 (f32.const 500.0))

  ;; ---- the gate ----
  ;; The title's own idea from the per-game menu: *a squeeze that scores
  ;; double*. Every $GATE_EVERY-th field places a pair of posts beside the
  ;; corridor, on whichever side has more room and at least 110px clear of it —
  ;; the rib gap's rule, so a gate is a second way through a field, never a
  ;; wider first one. The posts are $GATE_R and the gap between their surfaces
  ;; is the ship plus $GATE_CLEAR a side, which is inside the graze band on
  ;; every setting, so flying through it is always a squeeze. Only a squeeze
  ;; whose *both* grazes were posts is a gate; that one pays $SCORE_SQUEEZE a
  ;; second time.
  ;;
  ;; Score only. The charge a squeeze banks is the hull's repair, and the
  ;; repair is what the difficulty table is tuned around; a gate that also
  ;; healed would be a second leviathan every four fields. What the double
  ;; buys is the multiplier's worth twice, and the multiplier is only ever
  ;; high when the player has been taking risks — so a gate is worth most to
  ;; the player already flying close, which is the right person to tempt.
  ;;
  ;; No other rock may sit in the gap, or a gate could arrive plugged; the
  ;; posts themselves never drift.
  (global $GATE_EVERY i32 (i32.const 4))
  (global $GATE_R f32 (f32.const 20.0))
  (global $GATE_CLEAR f32 (f32.const 12.0))    ;; each side of the ship

  ;; ---- difficulty ---------------------------------------------------------
  ;; Easy / Normal / Hard. The widget calls set_difficulty(d) and then init();
  ;; init() copies one column of this table into the globals below, and the rest
  ;; of the engine reads only those.
  ;;
  ;;                            easy       normal      hard
  ;;   hull plates                4          3           2
  ;;   graze band                38px       30px        24px
  ;;   corridor                 290px      250px       220px
  ;;   ... narrower per km      1.3px      1.6px       2.0px
  ;;   ... floor                178px      148px       128px
  ;;   speed per km               8          11          14
  ;;   ... capped at            540px/s    620px/s     700px/s
  ;;   rocks in a field, cap      5          6           6
  ;;   ... one more every        20km       15km        11km
  ;;   fields, gap floor        300px      268px       240px
  ;;   ... closer per km        2.0px      2.6px       3.2px
  ;;
  ;; The two knobs TASKS.md named are the **graze band** and **rock density**,
  ;; and the band is the one that matters most here, for the reason TASKS.md
  ;; gives: the band *is* the scoring rule. Widening it on Easy is not a
  ;; discount, it is a bigger target — and since a graze is also the only way to
  ;; repair a plate, the band is simultaneously this game's score, its healing
  ;; and its difficulty. There is no separate "more forgiving" knob to reach for,
  ;; and inventing one (a pickup, a slower drift) is the thing TASKS.md already
  ;; ruled out for this title.
  ;;
  ;; The corridor and the speed ramp are in the table because they are this
  ;; game's actual difficulty curve — the engine has no level counter, so
  ;; everything is keyed on distance, and the corridor narrowing under a
  ;; quickening board is the whole of it. Sector Defense's table shipped without
  ;; its governing curve and the three columns only separated in the last minute
  ;; of a six-minute run; that is not a mistake worth making twice.
  ;;
  ;; A note on $PATH_STEP, which is *not* in the table and does not need to be.
  ;; It is REACH_RATE * field_gap / speed — how far the corridor may move
  ;; between fields, derived from how far the ship can actually fly in the time
  ;; it has. Hard both quickens the board and brings the fields closer, and both
  ;; of those *shrink* the step on their own. The guarantee that the corridor
  ;; stays reachable therefore holds on every column without the table touching
  ;; it, which is what deriving it rather than picking it bought.
  ;;
  ;; Three things are deliberately *not* in the table. $THRUST and $DRAG are the
  ;; feel of the ship — the comment above $DRAG records what 2.0 and 8.0 each
  ;; did to it, and neither is an easier game, they are different ones.
  ;; $SQUEEZE_WINDOW stays at 0.34s because it is a *definition* — it is how the
  ;; engine decides that two grazes were one gap — and a setting where the same
  ;; flying counts as a different manoeuvre would make the scores incomparable.
  ;;
  ;; $difficulty is not reset by init: it is a choice about the next run, so a
  ;; restart has to carry it rather than wipe it — chapter 8's argument for $rng.
  (global $difficulty (mut i32) (i32.const 1))   ;; 0 easy, 1 normal, 2 hard
  (global $FIELD_EVERY (mut f32) (f32.const 15.0))   ;; km per extra rock

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
  (global $nextLev (mut f32) (f32.const 8000.0))   ;; distance of the next leviathan
  (global $levWalls (mut i32) (i32.const 0))       ;; walls still to spawn
  (global $levOn (mut i32) (i32.const 0))          ;; one is passing
  (global $levHit (mut i32) (i32.const 0))         ;; the ship was hit during it
  (global $wavePhase (mut f32) (f32.const 0.0))
  (global $prevGate (mut i32) (i32.const 0))       ;; the last graze was a post

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
  (global $leviathans (mut i32) (i32.const 0))  ;; one arrived
  (global $threads (mut i32) (i32.const 0))     ;; one passed without a hit
  (global $gates (mut i32) (i32.const 0))       ;; a gate threaded

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

  ;; How many rocks a field may hold. Three at the start, and one more every
  ;; $FIELD_EVERY km — so on Normal the cap of six is reached at 45km, which at
  ;; this speed curve is a run of about two and a half minutes. The ramp is that
  ;; slow on purpose, because the corridor is narrowing underneath it and the two
  ;; curves multiply. (An earlier version of this comment said "six by 4km",
  ;; which was never what the arithmetic did.)
  (func $field_size (result i32)
    (call $clampi
      (i32.add (i32.const 3) (i32.trunc_f32_s (f32.div (call $km) (global.get $FIELD_EVERY))))
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
  ;; Move the corridor for the next field, by at most $path_step. Every field
  ;; and every leviathan wall goes through here, which is what makes the
  ;; reachability guarantee one rule rather than two.
  (func $move_path
    (global.set $pathX
      (call $clampf
        (f32.add (global.get $pathX)
                 (call $frand (f32.neg (call $path_step)) (call $path_step)))
        (f32.add (global.get $SHIP_MARGIN) (f32.mul (call $corridor) (f32.const 0.5)))
        (f32.sub (f32.sub (global.get $WORLD_W) (global.get $SHIP_MARGIN))
                 (f32.mul (call $corridor) (f32.const 0.5))))))

  (func $spawn_field
    (local $n i32) (local $placed i32) (local $tries i32)
    (local $x f32) (local $r f32) (local $kind i32) (local $half f32) (local $idx i32)
    (local $gx f32) (local $gHalf f32) (local $lo f32) (local $hi f32)

    (call $move_path)

    (local.set $half (f32.mul (call $corridor) (f32.const 0.5)))

    (local.set $n (call $field_size))

    ;; The gate, first, so the field's own rocks are placed around it. $gx
    ;; stays far off the board on the fields without one.
    (local.set $gx (f32.const -1000.0))
    (local.set $gHalf (f32.add (global.get $SHIP_R) (global.get $GATE_CLEAR)))
    (if (i32.eq (i32.rem_u (global.get $fields) (global.get $GATE_EVERY))
                (i32.sub (global.get $GATE_EVERY) (i32.const 1)))
      (then
        (if (f32.gt (global.get $pathX) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
          (then
            (local.set $lo (f32.const 80.0))
            (local.set $hi (f32.sub (f32.sub (global.get $pathX) (local.get $half)) (f32.const 110.0))))
          (else
            (local.set $lo (f32.add (f32.add (global.get $pathX) (local.get $half)) (f32.const 110.0)))
            (local.set $hi (f32.sub (global.get $WORLD_W) (f32.const 80.0)))))
        ;; A corridor near the middle can leave neither side room for a
        ;; gate; then this field simply has none.
        (if (f32.ge (local.get $hi) (local.get $lo))
          (then
            (local.set $gx (call $frand (local.get $lo) (local.get $hi)))
            (drop (call $spawn_rock
              (f32.sub (local.get $gx) (f32.add (local.get $gHalf) (global.get $GATE_R)))
              (global.get $GATE_R) (i32.const 5)))
            (drop (call $spawn_rock
              (f32.add (local.get $gx) (f32.add (local.get $gHalf) (global.get $GATE_R)))
              (global.get $GATE_R) (i32.const 5)))
            ;; The posts stand in for two of the field's rocks rather than
            ;; joining them. Added on top, they made every fourth field
            ;; denser, and a pilot that never went near a gate lost 30s of
            ;; its Easy runs to rocks it was only avoiding.
            (local.set $n (call $clampi (i32.sub (local.get $n) (i32.const 2))
                                        (i32.const 1) (local.get $n)))))))
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
        ;; ... and never in a gate's gap
        (br_if $lp (f32.lt (f32.abs (f32.sub (local.get $x) (local.get $gx)))
                           (f32.add (f32.add (local.get $gHalf) (local.get $r)) (f32.const 8.0))))

        ;; A full pool means the board is already saturated; stop rather than
        ;; spinning out the try budget placing nothing.
        (local.set $idx (call $spawn_rock (local.get $x) (local.get $r) (local.get $kind)))
        (br_if $done (i32.lt_s (local.get $idx) (i32.const 0)))
        (local.set $placed (i32.add (local.get $placed) (i32.const 1)))
        (br $lp)))

    (global.set $fields (i32.add (global.get $fields) (i32.const 1))))

  ;; One wall of the leviathan: body everywhere except the corridor and one
  ;; rib gap, each segment a little higher or lower on a sine wave so the wall
  ;; reads as a body rather than a fence. The rib gap is placed well clear of
  ;; the corridor, so it is a second way through, not a wider first one.
  ;;
  ;; The first version laid segments on a $SEG_STEP grid and skipped any that
  ;; touched a gap, and a screenshot showed the rib gap coming out nearly 190px
  ;; wide — the width of the grid slots around it, not the 58 it claimed. The
  ;; body is now three runs packed from both ends (see $body_run), so the
  ;; segments beside each gap sit exactly on its edges.
  (func $spawn_wall (param $head i32)
    (local $half f32) (local $rib f32) (local $ribHalf f32)
    (local $lo f32) (local $hi f32) (local $first i32)
    (local $g0 f32) (local $g1 f32) (local $h0 f32) (local $h1 f32) (local $t f32)
    (call $move_path)
    (local.set $half (f32.mul (call $corridor) (f32.const 0.5)))
    (local.set $ribHalf (f32.add (global.get $SHIP_R) (global.get $RIB_CLEAR)))
    ;; The rib gap goes on whichever side of the corridor has more room, a
    ;; random distance into it.
    (if (f32.gt (global.get $pathX) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
      (then
        (local.set $lo (f32.const 70.0))
        (local.set $hi (f32.sub (f32.sub (global.get $pathX) (local.get $half)) (f32.const 110.0))))
      (else
        (local.set $lo (f32.add (f32.add (global.get $pathX) (local.get $half)) (f32.const 110.0)))
        (local.set $hi (f32.sub (global.get $WORLD_W) (f32.const 70.0)))))
    (local.set $rib (call $frand (local.get $lo) (f32.max (local.get $lo) (local.get $hi))))

    ;; Two gaps, as surface intervals: [g0,g1] the nearer the left edge.
    (local.set $g0 (f32.sub (global.get $pathX) (local.get $half)))
    (local.set $g1 (f32.add (global.get $pathX) (local.get $half)))
    (local.set $h0 (f32.sub (local.get $rib) (local.get $ribHalf)))
    (local.set $h1 (f32.add (local.get $rib) (local.get $ribHalf)))
    (if (f32.lt (local.get $h0) (local.get $g0))
      (then
        (local.set $t (local.get $g0)) (local.set $g0 (local.get $h0)) (local.set $h0 (local.get $t))
        (local.set $t (local.get $g1)) (local.set $g1 (local.get $h1)) (local.set $h1 (local.get $t))))
    ;; Three runs of body between the edges and the gaps. Each run is packed
    ;; from both ends toward its middle, so the segments either side of a gap
    ;; sit exactly on its edge — a rib gap is the width it claims to be, not
    ;; that plus whatever the grid left over.
    (local.set $first (i32.const 1))
    (local.set $first (call $body_run (f32.const 0.0) (local.get $g0) (local.get $head) (local.get $first)))
    (local.set $first (call $body_run (local.get $g1) (local.get $h0) (local.get $head) (local.get $first)))
    (local.set $first (call $body_run (local.get $h1) (global.get $WORLD_W) (local.get $head) (local.get $first)))
    (global.set $wavePhase (f32.add (global.get $wavePhase) (f32.const 1.3))))

  ;; Fill the surface interval [a,b] with body segments, touching its ends,
  ;; evenly spaced no wider apart than $SEG_STEP. Returns whether the head is
  ;; still to be placed. A run too short for one segment is left empty — an
  ;; edge gap wider than a segment is just more corridor.
  (func $body_run (param $a f32) (param $b f32) (param $head i32) (param $first i32) (result i32)
    (local $n i32) (local $k i32) (local $x0 f32) (local $x1 f32) (local $step f32)
    (local $x f32) (local $idx i32) (local $p i32) (local $r f32)
    (local.set $r (global.get $SEG_R))
    (local.set $x0 (f32.add (local.get $a) (local.get $r)))
    (local.set $x1 (f32.sub (local.get $b) (local.get $r)))
    (if (f32.lt (local.get $x1) (local.get $x0)) (then (return (local.get $first))))
    (local.set $n (i32.add (i32.trunc_f32_s
      (f32.ceil (f32.div (f32.sub (local.get $x1) (local.get $x0)) (global.get $SEG_STEP)))) (i32.const 1)))
    (local.set $step (if (result f32) (i32.gt_s (local.get $n) (i32.const 1))
      (then (f32.div (f32.sub (local.get $x1) (local.get $x0)) (f32.convert_i32_s (i32.sub (local.get $n) (i32.const 1)))))
      (else (f32.const 0.0))))
    (local.set $k (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $k) (local.get $n)))
        (local.set $x (f32.add (local.get $x0) (f32.mul (f32.convert_i32_s (local.get $k)) (local.get $step))))
        (local.set $idx (call $spawn_rock (local.get $x) (local.get $r) (i32.const 3)))
        (br_if $done (i32.lt_s (local.get $idx) (i32.const 0)))
        (local.set $p (call $rock_addr (local.get $idx)))
        ;; the body bends: each segment is lifted by a slice of the wave
        (f32.store offset=4 (local.get $p)
          (f32.sub (f32.load offset=4 (local.get $p))
            (f32.mul (global.get $WAVE_AMP)
              (f32.add (f32.const 1.0)
                (call $sin_approx (f32.add (global.get $wavePhase)
                                           (f32.mul (local.get $x) (f32.const 0.011))))))))
        (if (i32.and (local.get $head) (local.get $first))
          (then
            (f32.store offset=28 (local.get $p) (f32.const 4.0))
            (local.set $first (i32.const 0))))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $lp)))
    (local.get $first))

  ;; A sine good enough to bend a body by, from the Bhaskara approximation.
  ;; The engine has no imports and needs no accuracy here: the wave is a
  ;; drawing of a spine, and the collision uses where the segment *is*.
  (func $sin_approx (param $t f32) (result f32)
    (local $x f32) (local $s f32)
    ;; wrap to [0, 2pi)
    (local.set $x (f32.sub (local.get $t)
      (f32.mul (f32.const 6.2831853) (f32.floor (f32.div (local.get $t) (f32.const 6.2831853))))))
    (local.set $s (f32.const 1.0))
    (if (f32.gt (local.get $x) (f32.const 3.1415927))
      (then (local.set $x (f32.sub (local.get $x) (f32.const 3.1415927)))
            (local.set $s (f32.const -1.0))))
    (f32.mul (local.get $s)
      (f32.div (f32.mul (f32.const 16.0) (f32.mul (local.get $x) (f32.sub (f32.const 3.1415927) (local.get $x))))
               (f32.sub (f32.const 49.348022)
                        (f32.mul (f32.const 4.0) (f32.mul (local.get $x) (f32.sub (f32.const 3.1415927) (local.get $x))))))))

  ;; Is any part of the leviathan still to be settled up?
  (func $lev_pending (result i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ROCKS)))
        (local.set $a (call $rock_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
              (i32.and (i32.and (f32.ge (f32.load offset=28 (local.get $a)) (f32.const 3.0))
                                (f32.lt (f32.load offset=28 (local.get $a)) (f32.const 5.0)))
                       (f32.eq (f32.load offset=32 (local.get $a)) (f32.const 0.0))))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))

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
  (func $resolve_graze (param $near f32) (param $gate i32)
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
        ;; Both grazes of this squeeze were posts: a gate. Paid at the
        ;; multiplier as it stood before this squeeze raised it, the same as
        ;; the first payment, so a gate is exactly double and not a shade more.
        (if (i32.and (local.get $gate) (global.get $prevGate))
          (then
            (global.set $gates (i32.add (global.get $gates) (i32.const 1)))
            (call $add_score (f32.mul (global.get $SCORE_SQUEEZE) (global.get $mult)))))
        (global.set $mult (f32.min (f32.add (global.get $mult) (f32.const 1.0))
                                   (global.get $MULT_MAX)))))
    (global.set $prevGate (local.get $gate))
    ;; Re-armed either way: four rocks the ship threaded is three gaps, not
    ;; one, and the player who managed it should be paid for all three.
    (global.set $squeezeT (global.get $SQUEEZE_WINDOW))

    (call $spend_charge))

  (func $take_hit (param $a i32)
    (global.set $hits (i32.add (global.get $hits) (i32.const 1)))
    (if (global.get $levOn) (then (global.set $levHit (i32.const 1))))
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
    (global.set $prevGate (i32.const 0))
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
                      (then (call $resolve_graze (local.get $near)
                              (f32.eq (f32.load offset=28 (local.get $a)) (f32.const 5.0)))))))))))
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

  ;; Copy one column of the difficulty table into the globals the rest of the
  ;; engine reads. Called only from init, so a run never changes balance halfway
  ;; through. Normal restates the initialisers, because a restart after an Easy
  ;; or Hard run has to put them back.
  (func $apply_difficulty
    (if (i32.eqz (global.get $difficulty))
      (then   ;; easy
        (global.set $HULL_MAX (f32.const 4.0))
        (global.set $GRAZE_BAND (f32.const 38.0))
        (global.set $CORRIDOR (f32.const 290.0))
        (global.set $CORRIDOR_STEP (f32.const 1.3))
        (global.set $CORRIDOR_MIN (f32.const 178.0))
        (global.set $SPEED_PER_KM (f32.const 8.0))
        (global.set $SPEED_CAP (f32.const 540.0))
        (global.set $MAX_IN_FIELD (i32.const 5))
        (global.set $FIELD_EVERY (f32.const 20.0))
        (global.set $FIELD_GAP_MIN (f32.const 300.0))
        (global.set $FIELD_GAP_STEP (f32.const 2.0)))
      (else
        (if (i32.eq (global.get $difficulty) (i32.const 2))
          (then   ;; hard
            (global.set $HULL_MAX (f32.const 2.0))
            (global.set $GRAZE_BAND (f32.const 24.0))
            (global.set $CORRIDOR (f32.const 220.0))
            (global.set $CORRIDOR_STEP (f32.const 2.0))
            (global.set $CORRIDOR_MIN (f32.const 128.0))
            (global.set $SPEED_PER_KM (f32.const 14.0))
            (global.set $SPEED_CAP (f32.const 700.0))
            (global.set $MAX_IN_FIELD (i32.const 6))
            (global.set $FIELD_EVERY (f32.const 11.0))
            (global.set $FIELD_GAP_MIN (f32.const 240.0))
            (global.set $FIELD_GAP_STEP (f32.const 3.2)))
          (else   ;; normal
            (global.set $HULL_MAX (f32.const 3.0))
            (global.set $GRAZE_BAND (f32.const 30.0))
            (global.set $CORRIDOR (f32.const 250.0))
            (global.set $CORRIDOR_STEP (f32.const 1.6))
            (global.set $CORRIDOR_MIN (f32.const 148.0))
            (global.set $SPEED_PER_KM (f32.const 11.0))
            (global.set $SPEED_CAP (f32.const 620.0))
            (global.set $MAX_IN_FIELD (i32.const 6))
            (global.set $FIELD_EVERY (f32.const 15.0))
            (global.set $FIELD_GAP_MIN (f32.const 268.0))
            (global.set $FIELD_GAP_STEP (f32.const 2.6)))))))

  ;; 0 easy, 1 normal, 2 hard; anything else is clamped rather than trusted, and
  ;; a JavaScript call with no argument arrives as 0. Takes effect at the next
  ;; init().
  (func $set_difficulty (export "set_difficulty") (param $d i32)
    (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.const 0))))
    (if (i32.gt_s (local.get $d) (i32.const 2)) (then (local.set $d (i32.const 2))))
    (global.set $difficulty (local.get $d)))
  (func $get_difficulty (export "get_difficulty") (result i32) (global.get $difficulty))

  (func $init (export "init")
    ;; first, because the hull and the first field below both read it
    (call $apply_difficulty)
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
    (global.set $leviathans (i32.const 0))
    (global.set $threads (i32.const 0))
    (global.set $gates (i32.const 0))
    (global.set $prevGate (i32.const 0))
    (global.set $nextLev (f32.mul (global.get $LEV_FIRST_KM) (f32.const 1000.0)))
    (global.set $levWalls (i32.const 0))
    (global.set $levOn (i32.const 0))
    (global.set $levHit (i32.const 0))
    (global.set $wavePhase (f32.const 0.0))
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

    ;; A leviathan is due: the next three fields are its walls instead.
    (if (i32.and (f32.ge (global.get $dist) (global.get $nextLev))
                 (i32.eqz (global.get $levOn)))
      (then
        (global.set $nextLev (f32.add (global.get $nextLev)
                                      (f32.mul (global.get $LEV_EVERY_KM) (f32.const 1000.0))))
        (global.set $levWalls (global.get $LEV_WALLS))
        (global.set $levOn (i32.const 1))
        (global.set $levHit (i32.const 0))
        (global.set $leviathans (i32.add (global.get $leviathans) (i32.const 1)))))

    (if (f32.ge (global.get $dist) (global.get $nextField))
      (then
        (global.set $nextField (f32.add (global.get $nextField) (call $field_gap)))
        (if (i32.gt_s (global.get $levWalls) (i32.const 0))
          (then
            (call $spawn_wall (i32.eq (global.get $levWalls) (global.get $LEV_WALLS)))
            (global.set $levWalls (i32.sub (global.get $levWalls) (i32.const 1))))
          (else (call $spawn_field)))))

    (call $step_rocks (local.get $d))

    ;; All three walls are down and every segment has passed the ship: the
    ;; leviathan is behind you. Untouched, it pays half a plate.
    (if (i32.and (global.get $levOn)
                 (i32.and (i32.eqz (global.get $levWalls)) (i32.eqz (call $lev_pending))))
      (then
        (global.set $levOn (i32.const 0))
        (if (i32.eqz (global.get $levHit))
          (then
            (global.set $threads (i32.add (global.get $threads) (i32.const 1)))
            (call $add_score (f32.mul (global.get $SCORE_LEVIATHAN) (global.get $mult)))
            (global.set $charge (f32.add (global.get $charge) (global.get $LEV_CHARGE)))
            (call $spend_charge))))))

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
  (func $get_leviathans (export "get_leviathans") (result i32) (global.get $leviathans))
  (func $get_threads (export "get_threads") (result i32) (global.get $threads))
  (func $get_gates (export "get_gates") (result i32) (global.get $gates))
  ;; 1 while a leviathan is arriving or passing, for the banner and the HUD.
  (func $get_lev_on (export "get_lev_on") (result i32) (global.get $levOn))
)
