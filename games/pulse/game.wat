(module
  ;; ============================================================
  ;; PULSE — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as the other eight (globals
  ;; block at the top, entity pools at fixed offsets in linear memory, xorshift
  ;; RNG, monotonic event counters, an init/set_input/step/get_* export
  ;; surface) and nothing else. Every constant and every routine below is its
  ;; own.
  ;;
  ;; ---- the thing this title was waiting for ----
  ;;
  ;; Pulse sat on the roadmap for as long as it did because it "needs an audio
  ;; system that does not exist yet". That was the wrong way round, and it is
  ;; why it stayed blocked: the missing piece was never a synthesiser. Every
  ;; title here since Grid Breaker has had one of those, in about eighty lines
  ;; of Web Audio in the widget. What was missing was an answer to a question
  ;; the third invariant asks —
  ;;
  ;;     if the music decides when enemies arrive, and the music lives in
  ;;     JavaScript, then JavaScript owns game state.
  ;;
  ;; So it does not live in JavaScript. **This engine is the sequencer.** It
  ;; owns the tempo, the sixteen-step bar, the step counter and the pattern; it
  ;; decides what spawns and when. The widget reads the step counter, diffs it
  ;; like any other event counter, and plays a note. The synthesiser is an
  ;; *instrument*, not a clock.
  ;;
  ;; What that buys is not tidiness. It is that the music and the game cannot
  ;; drift. There is no scheduling to reconcile, no audio-clock-versus-frame-
  ;; clock problem, no "the beat and the spawn were 40ms apart". The spawn and
  ;; the note are the same event, read off the same counter, and a player who
  ;; times their shot to what they hear is timing it to what the engine did.
  ;;
  ;; ---- and rhythm is the mechanic, not the decoration ----
  ;;
  ;; A shot fired within $BEAT_WINDOW of an eighth-note boundary is **on the
  ;; beat**: it flies fast, hits hard, and builds groove. Off the beat it is
  ;; slow, weak, and breaks the chain. One enemy — the mirror — cannot be hurt
  ;; by an off-beat shot at all. Groove raises the multiplier *and the tempo*,
  ;; so playing well makes the track faster, which is both the difficulty curve
  ;; and the payoff.
  ;;
  ;; There are **no imports**, as in worm-chase, sector-defense,
  ;; circuit-runner, starfield-runner and tower-defense. The tube is twelve
  ;; discrete segments and a depth, so nothing here turns through an angle —
  ;; the widget works out where a segment is on screen with Math.cos, because
  ;; that is a drawing question.
  ;;
  ;; JavaScript owns no game state. It forwards input, calls step(dt), reads
  ;; entity records out of the memory below to draw them, and reads the bar
  ;; plan to play it.
  ;; ============================================================

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; bar      @0    : stride 4, 16 steps
  ;;                  byte 0  seg + 1, or 0 for no spawn on this step
  ;;                  byte 1  kind
  ;;                  byte 2  spent  (1 once this step has been played)
  ;;                  ends at 64
  ;; enemies  @64   : stride 32, MAX_ENEMIES = 32
  ;;                  seg, depth, hp, maxHp, kind, active, flash, hopT
  ;;                  ends at 64 + 32*32 = 1088
  ;; bolts    @1088 : stride 24, MAX_BOLTS = 24
  ;;                  seg, depth, dmg, active, onBeat, speed
  ;;                  ends at 1088 + 24*24 = 1664
  ;;
  ;; enemy kinds: 0 = drone, 1 = skipper, 2 = hulk, 3 = mirror
  ;;
  ;; `depth` runs 0 at the centre of the tube to 1 at the rim, which is where
  ;; the player is. Everything is in that unit rather than in pixels, because
  ;; the tube's size on screen is a rendering decision and the engine should
  ;; not have an opinion about it.
  ;;
  ;; The **bar plan is in memory rather than in globals on purpose.** It is the
  ;; one piece of state the widget reads *ahead* of the simulation: the HUD
  ;; draws the sixteen steps of the coming bar as a ring of ticks, so the
  ;; player can see the pattern as well as hear it. A global would have needed
  ;; sixteen readers.
  ;;
  ;; Scalars — shield, groove, score, the song clock — live in globals, as in
  ;; the other recent titles: the get_* readers are the only consumer.
  ;; ===================================================

  (global $BAR_OFF i32 (i32.const 0))
  (global $BAR_STRIDE i32 (i32.const 4))
  (global $STEPS_PER_BAR i32 (i32.const 16))
  (global $ENEMIES_OFF i32 (i32.const 64))
  (global $ENEMY_STRIDE i32 (i32.const 32))
  (global $MAX_ENEMIES i32 (i32.const 32))
  (global $BOLTS_OFF i32 (i32.const 1088))
  (global $BOLT_STRIDE i32 (i32.const 24))
  (global $MAX_BOLTS i32 (i32.const 24))

  ;; Twelve segments. Not sixteen: the player has to be able to cross the tube
  ;; inside a bar, and at the move rate below twelve is about three quarters of
  ;; a bar the long way round. Not eight: with eight, a bar of four spawns can
  ;; cover half the ring and there is no reading to do.
  (global $SEGMENTS i32 (i32.const 12))

  ;; ---- the song ----
  ;; Tempo. It rises with groove rather than with the level, which is the whole
  ;; reward loop in one line: play in time and the track speeds up.
  (global $BPM_BASE f32 (f32.const 96.0))
  (global $BPM_GROOVE f32 (f32.const 54.0))    ;; added at full groove
  (global $BPM_PER_LEVEL f32 (f32.const 2.2))
  (global $BPM_CAP f32 (f32.const 168.0))
  ;; How close to an eighth-note boundary a shot has to be. The window is a
  ;; fixed number of *seconds*, not a fraction of a beat, so it is the same in
  ;; feel at every tempo and strictly harder as the track speeds up — which is
  ;; what a player expects from a rhythm game and not what a fixed fraction
  ;; would have given them.
  ;;
  ;; 0.058 rather than the first draft's 0.075 because of what the bench found
  ;; about mashing. Two windows per eighth note at 96bpm is 2*0.075/0.3125,
  ;; which is 48% of the bar spent inside one, and a pilot that simply fired as
  ;; fast as it was allowed to landed 70% of its shots on the beat by accident.
  ;; A rhythm mechanic that pays out to a button-masher is a decoration. At
  ;; 0.058 the accidental rate is 37% and the metronome still clears it easily.
  (global $BEAT_WINDOW f32 (f32.const 0.058))

  ;; ---- the player ----
  (global $MOVE_CD f32 (f32.const 0.085))      ;; hold to sweep the ring
  (global $FIRE_CD f32 (f32.const 0.16))
  (global $FIRE_CD_GROOVE f32 (f32.const 0.07))  ;; reload at full groove

  (global $BOLT_SPEED f32 (f32.const 2.6))     ;; depth units per second
  (global $BOLT_SPEED_BEAT f32 (f32.const 4.4))
  (global $BOLT_DMG f32 (f32.const 1.0))
  (global $BOLT_DMG_BEAT f32 (f32.const 3.0))

  ;; ---- groove ----
  (global $GROOVE_MAX f32 (f32.const 1.0))
  (global $GROOVE_GAIN f32 (f32.const 0.085))  ;; per on-beat hit
  (global $GROOVE_DECAY f32 (f32.const 0.055)) ;; per second
  (global $GROOVE_MISS f32 (f32.const 0.12))   ;; lost to an off-beat shot
  (global $MULT_MAX f32 (f32.const 5.0))

  ;; ---- the tube ----
  (global $SHIELD_MAX f32 (f32.const 100.0))
  (global $LEAK_COST f32 (f32.const 20.0))
  ;; A bar in which nothing reached the rim pays shield back. It is the only
  ;; repair there is, and it is deliberately a *bar* rather than a kill: the
  ;; unit of play here is the pattern, so the unit of reward is too.
  (global $PERFECT_BAR_HEAL f32 (f32.const 12.0))

  ;; ---- scoring ----
  (global $SCORE_KILL f32 (f32.const 25.0))
  (global $SCORE_BEAT_KILL f32 (f32.const 60.0))
  (global $SCORE_PERFECT_BAR f32 (f32.const 200.0))

  (global $rng (mut i32) (i32.const 707406378))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $shield (mut f32) (f32.const 100.0))
  (global $groove (mut f32) (f32.const 0.0))
  (global $level (mut i32) (i32.const 1))

  ;; The song clock. `songT` is seconds into the current step; `stepIdx` is
  ;; which of the sixteen we are on; `barIdx` counts bars since init.
  (global $songT (mut f32) (f32.const 0.0))
  (global $stepIdx (mut i32) (i32.const 0))
  (global $barIdx (mut i32) (i32.const 0))
  (global $barClean (mut i32) (i32.const 1))   ;; nothing has reached the rim this bar

  (global $pseg (mut i32) (i32.const 0))
  (global $moveCd (mut f32) (f32.const 0.0))
  (global $fireCd (mut f32) (f32.const 0.0))

  ;; input, as reported by set_input each frame
  (global $moveIn (mut i32) (i32.const 0))
  (global $fireIn (mut i32) (i32.const 0))
  (global $prevFire (mut i32) (i32.const 0))

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  ;;
  ;; `steps` is the one that makes this title work: it ticks once per
  ;; sixteenth note, and the widget plays the track off it. The music is not
  ;; scheduled against a separate audio clock, it is *read off the simulation*,
  ;; so the note and the spawn are the same event.
  (global $steps (mut i32) (i32.const 0))
  (global $bars (mut i32) (i32.const 0))
  (global $spawns (mut i32) (i32.const 0))
  (global $shots (mut i32) (i32.const 0))
  (global $beatShots (mut i32) (i32.const 0))
  (global $kills (mut i32) (i32.const 0))
  (global $beatKills (mut i32) (i32.const 0))
  (global $leaks (mut i32) (i32.const 0))
  (global $perfects (mut i32) (i32.const 0))
  (global $moves (mut i32) (i32.const 0))

  ;; ---------------- helpers ----------------

  (func $bar_addr (param $i i32) (result i32)
    (i32.add (global.get $BAR_OFF) (i32.mul (local.get $i) (global.get $BAR_STRIDE))))
  (func $enemy_addr (param $i i32) (result i32)
    (i32.add (global.get $ENEMIES_OFF) (i32.mul (local.get $i) (global.get $ENEMY_STRIDE))))
  (func $bolt_addr (param $i i32) (result i32)
    (i32.add (global.get $BOLTS_OFF) (i32.mul (local.get $i) (global.get $BOLT_STRIDE))))

  (func $rand_u (result i32)
    (local $x i32)
    (local.set $x (global.get $rng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng (local.get $x))
    (i32.and (local.get $x) (i32.const 2147483647)))

  ;; Integer-domain, as in worm-chase and tower-defense: a remainder of a
  ;; masked u32 cannot land one past the end the way dividing by 2^32 in f32
  ;; can.
  (func $rand_below (param $n i32) (result i32)
    (i32.rem_u (call $rand_u) (local.get $n)))

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

  ;; Wrap a segment index into 0..SEGMENTS-1. The ring has no ends, which is
  ;; the one thing that makes it a ring rather than a row of lanes.
  ;;
  ;; The inner remainder is **signed**. With rem_u, stepping left from segment
  ;; 0 hands -1 to an unsigned remainder, 0xFFFFFFFF % 12 is 3, and the player
  ;; teleports a quarter of the way round the tube the first time they press
  ;; left. rem_s gives -1, and the add-then-wrap turns that into 11.
  (func $wrap_seg (param $s i32) (result i32)
    (i32.rem_u (i32.add (i32.rem_s (local.get $s) (global.get $SEGMENTS))
                        (global.get $SEGMENTS))
               (global.get $SEGMENTS)))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  (func $bpm (export "get_bpm") (result f32)
    (call $clampf
      (f32.add (f32.add (global.get $BPM_BASE)
                        (f32.mul (global.get $groove) (global.get $BPM_GROOVE)))
               (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                        (global.get $BPM_PER_LEVEL)))
      (global.get $BPM_BASE) (global.get $BPM_CAP)))

  ;; One sixteenth note, in seconds.
  (func $step_dur (export "get_step_dur") (result f32)
    (f32.div (f32.const 60.0) (f32.mul (call $bpm) (f32.const 4.0))))

  (func $mult (export "get_mult") (result f32)
    (f32.add (f32.const 1.0)
             (f32.mul (global.get $groove)
                      (f32.sub (global.get $MULT_MAX) (f32.const 1.0)))))

  ;; ---------------- the pattern ----------------

  ;; How many spawns a bar holds, and how likely a step is to be one of them.
  ;;
  ;; Steps are weighted by where they fall in the bar, which is the whole
  ;; reason the result sounds like music rather than like noise: the four
  ;; quarter notes are much the likeliest, the off-eighths next, and the
  ;; sixteenths in between are rare and are what makes a bar feel busy when
  ;; they land. Choosing uniformly at random — the first version — produced
  ;; sixteen equally probable events a bar, which a listener hears as a
  ;; stuttering machine and a player cannot anticipate at all.
  (func $step_weight (param $s i32) (result i32)
    (if (i32.eqz (i32.rem_u (local.get $s) (i32.const 4))) (then (return (i32.const 9))))
    (if (i32.eqz (i32.rem_u (local.get $s) (i32.const 2))) (then (return (i32.const 4))))
    (i32.const 1))

  (func $bar_spawns (result i32)
    (call $clampi
      (i32.add (i32.const 3) (i32.div_s (global.get $level) (i32.const 2)))
      (i32.const 3) (i32.const 11)))

  ;; Which enemy kinds this level may send. The mirror is last because it is
  ;; the one that *requires* the beat rather than rewarding it, and a player
  ;; who has not yet found the rhythm would simply be unable to kill it.
  (func $kinds_in_play (result i32)
    (if (result i32) (i32.lt_s (global.get $level) (i32.const 2))
      (then (i32.const 1))
      (else (if (result i32) (i32.lt_s (global.get $level) (i32.const 4))
        (then (i32.const 2))
        (else (if (result i32) (i32.lt_s (global.get $level) (i32.const 6))
          (then (i32.const 3))
          (else (i32.const 4))))))))

  ;; Fill the sixteen steps of the next bar. Nothing is spawned here — this is
  ;; the *plan*, and the widget reads it to draw the bar ahead of the player.
  (func $plan_bar
    (local $i i32) (local $n i32) (local $tries i32) (local $s i32) (local $a i32)
    (local $seg i32) (local $lastSeg i32)

    (local.set $i (i32.const 0))
    (block $clr
      (loop $clp
        (br_if $clr (i32.ge_s (local.get $i) (global.get $STEPS_PER_BAR)))
        (i32.store (call $bar_addr (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $clp)))

    (local.set $n (call $bar_spawns))
    (local.set $i (i32.const 0))
    (local.set $tries (i32.const 0))
    (local.set $lastSeg (global.get $pseg))

    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (br_if $done (i32.gt_s (local.get $tries) (i32.const 80)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))

        (local.set $s (call $rand_below (global.get $STEPS_PER_BAR)))
        ;; rejection sampling against the weight, so strong beats win
        (br_if $lp (i32.ge_s (call $rand_below (i32.const 10))
                             (call $step_weight (local.get $s))))
        (local.set $a (call $bar_addr (local.get $s)))
        (br_if $lp (i32.ne (i32.load8_u (local.get $a)) (i32.const 0)))

        ;; Segments wander rather than jumping across the ring. Two spawns a
        ;; quarter-note apart on opposite sides is not a pattern, it is a coin
        ;; toss the player cannot answer — there is not time to cross.
        (local.set $seg (call $wrap_seg
          (i32.add (local.get $lastSeg) (i32.sub (call $rand_below (i32.const 7))
                                                 (i32.const 3)))))
        (local.set $lastSeg (local.get $seg))

        (i32.store8 (local.get $a) (i32.add (local.get $seg) (i32.const 1)))
        (i32.store8 offset=1 (local.get $a) (call $rand_below (call $kinds_in_play)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- enemies ----------------

  (func $enemy_hp (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
      (then (f32.const 6.0))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
        (then (f32.const 4.0))
        (else (f32.const 3.0))))))

  ;; Climb rate, in depth units per second. Scaled by the level, but only
  ;; gently: the tempo is already rising with groove, and two ramps on the same
  ;; axis is how a game becomes unplayable at level 6 without anyone deciding
  ;; that it should.
  (func $enemy_speed (param $kind i32) (result f32)
    (local $base f32)
    (local.set $base
      (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (f32.const 0.055))
        (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
          (then (f32.const 0.085))
          (else (f32.const 0.105))))))
    (f32.mul (local.get $base)
             (f32.add (f32.const 1.0)
                      (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                               (f32.const 0.11)))))

  (func $spawn_enemy (param $seg i32) (param $kind i32)
    (local $i i32) (local $a i32) (local $hp f32)
    (local.set $hp (call $enemy_hp (local.get $kind)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (f32.convert_i32_s (local.get $seg)))
            (f32.store offset=4 (local.get $a) (f32.const 0.0))
            (f32.store offset=8 (local.get $a) (local.get $hp))
            (f32.store offset=12 (local.get $a) (local.get $hp))
            (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (f32.const 0.0))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (global.set $spawns (i32.add (global.get $spawns) (i32.const 1)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $enemies_alive (export "enemies_alive") (result i32)
    (local $i i32) (local $n i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (if (f32.gt (f32.load offset=20 (call $enemy_addr (local.get $i))) (f32.const 0.0))
          (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $n))

  ;; A skipper does not climb; it hops one sixteenth's worth of ground at a
  ;; time, on the step. It is the enemy that is legible by ear — you can hear
  ;; it move — and the reason the step counter is the engine's and not the
  ;; widget's.
  (func $on_step_enemies
    (local $i i32) (local $a i32) (local $kind i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $kind (i32.trunc_f32_s (f32.load offset=16 (local.get $a))))
            (if (i32.eq (local.get $kind) (i32.const 1))
              (then
                ;; hop outward, and sidestep one segment every fourth step
                (f32.store offset=4 (local.get $a)
                  (f32.add (f32.load offset=4 (local.get $a)) (f32.const 0.052)))
                (if (i32.eqz (i32.rem_u (global.get $stepIdx) (i32.const 4)))
                  (then
                    (f32.store offset=0 (local.get $a) (f32.convert_i32_s (call $wrap_seg
                      (i32.add (i32.trunc_f32_s (f32.load offset=0 (local.get $a)))
                               (if (result i32)
                                 (i32.eqz (i32.and (local.get $i) (i32.const 1)))
                                 (then (i32.const 1)) (else (i32.const -1)))))))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $kill_enemy (param $a i32) (param $onBeat i32)
    (f32.store offset=20 (local.get $a) (f32.const 0.0))
    (global.set $kills (i32.add (global.get $kills) (i32.const 1)))
    (if (i32.ne (local.get $onBeat) (i32.const 0))
      (then
        (global.set $beatKills (i32.add (global.get $beatKills) (i32.const 1)))
        (call $add_score (f32.mul (global.get $SCORE_BEAT_KILL) (call $mult))))
      (else (call $add_score (f32.mul (global.get $SCORE_KILL) (call $mult))))))

  (func $step_enemies (param $dt f32)
    (local $i i32) (local $a i32) (local $kind i32) (local $d f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=24 (local.get $a)
                      (f32.sub (f32.load offset=24 (local.get $a)) (local.get $dt)))))
            (local.set $kind (i32.trunc_f32_s (f32.load offset=16 (local.get $a))))
            (local.set $d (f32.load offset=4 (local.get $a)))
            ;; A skipper moves only on the step, in $on_step_enemies.
            (if (i32.ne (local.get $kind) (i32.const 1))
              (then
                (local.set $d (f32.add (local.get $d)
                  (f32.mul (call $enemy_speed (local.get $kind)) (local.get $dt))))))
            (f32.store offset=4 (local.get $a) (local.get $d))

            (if (f32.ge (local.get $d) (f32.const 1.0))
              (then
                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                (global.set $leaks (i32.add (global.get $leaks) (i32.const 1)))
                (global.set $barClean (i32.const 0))
                (global.set $shield (f32.sub (global.get $shield) (global.get $LEAK_COST)))
                ;; Groove is lost with the shield. A leak is a missed beat as
                ;; much as it is damage, and charging for it twice is what
                ;; makes the meter mean "you are playing in time" rather than
                ;; "you have been playing a while".
                (global.set $groove (f32.mul (global.get $groove) (f32.const 0.4)))
                (if (f32.le (global.get $shield) (f32.const 0.0))
                  (then
                    (global.set $shield (f32.const 0.0))
                    (global.set $gameOver (i32.const 1))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- bolts ----------------

  ;; How far the song clock is from the nearest eighth-note boundary, in
  ;; seconds. An eighth note is two steps, so the boundary is at the start of
  ;; every even step.
  (func $beat_error (export "get_beat_error") (result f32)
    (local $d f32) (local $half f32)
    (local.set $d (global.get $songT))
    ;; on an odd step, the previous boundary was a whole step ago
    (if (i32.ne (i32.and (global.get $stepIdx) (i32.const 1)) (i32.const 0))
      (then (local.set $d (f32.add (local.get $d) (call $step_dur)))))
    (local.set $half (call $step_dur))
    ;; distance to whichever boundary is nearer: this one, or the next
    (f32.min (local.get $d)
             (f32.sub (f32.mul (local.get $half) (f32.const 2.0)) (local.get $d))))

  (func $spawn_bolt (param $onBeat i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BOLTS)))
        (local.set $a (call $bolt_addr (local.get $i)))
        (if (f32.eq (f32.load offset=12 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (f32.convert_i32_s (global.get $pseg)))
            (f32.store offset=4 (local.get $a) (f32.const 1.0))
            (f32.store offset=8 (local.get $a)
              (if (result f32) (local.get $onBeat)
                (then (global.get $BOLT_DMG_BEAT)) (else (global.get $BOLT_DMG))))
            (f32.store offset=12 (local.get $a) (f32.const 1.0))
            (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $onBeat)))
            (f32.store offset=20 (local.get $a)
              (if (result f32) (local.get $onBeat)
                (then (global.get $BOLT_SPEED_BEAT)) (else (global.get $BOLT_SPEED))))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $step_bolts (param $dt f32)
    (local $i i32) (local $j i32) (local $a i32) (local $e i32)
    (local $d f32) (local $seg i32) (local $onBeat i32) (local $kind i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BOLTS)))
        (local.set $a (call $bolt_addr (local.get $i)))
        (if (f32.gt (f32.load offset=12 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $d (f32.sub (f32.load offset=4 (local.get $a))
              (f32.mul (f32.load offset=20 (local.get $a)) (local.get $dt))))
            (f32.store offset=4 (local.get $a) (local.get $d))
            (local.set $seg (i32.trunc_f32_s (f32.load offset=0 (local.get $a))))
            (local.set $onBeat (i32.trunc_f32_s (f32.load offset=16 (local.get $a))))

            (if (f32.lt (local.get $d) (f32.const 0.0))
              (then (f32.store offset=12 (local.get $a) (f32.const 0.0)))
              (else
                (local.set $j (i32.const 0))
                (block $hit
                  (loop $hlp
                    (br_if $hit (i32.ge_s (local.get $j) (global.get $MAX_ENEMIES)))
                    (local.set $e (call $enemy_addr (local.get $j)))
                    (if (i32.and
                          (f32.gt (f32.load offset=20 (local.get $e)) (f32.const 0.0))
                          (i32.and
                            (i32.eq (i32.trunc_f32_s (f32.load offset=0 (local.get $e)))
                                    (local.get $seg))
                            (f32.lt (f32.abs (f32.sub (f32.load offset=4 (local.get $e))
                                                      (local.get $d)))
                                    (f32.const 0.055))))
                      (then
                        (f32.store offset=12 (local.get $a) (f32.const 0.0))
                        (f32.store offset=24 (local.get $e) (f32.const 0.12))
                        (local.set $kind (i32.trunc_f32_s (f32.load offset=16 (local.get $e))))
                        ;; A mirror shrugs off anything that was not in time.
                        ;; It is the only enemy that *requires* the beat rather
                        ;; than rewarding it, which is why it does not arrive
                        ;; until level 6.
                        (if (i32.and (i32.eq (local.get $kind) (i32.const 3))
                                     (i32.eqz (local.get $onBeat)))
                          (then (br $hit)))
                        (f32.store offset=8 (local.get $e)
                          (f32.sub (f32.load offset=8 (local.get $e))
                                   (f32.load offset=8 (local.get $a))))
                        (if (f32.le (f32.load offset=8 (local.get $e)) (f32.const 0.0))
                          (then (call $kill_enemy (local.get $e) (local.get $onBeat))))
                        (br $hit)))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $hlp)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- the player ----------------

  (func $set_input (export "set_input") (param $move i32) (param $fire i32)
    (global.set $moveIn (call $clampi (local.get $move) (i32.const -1) (i32.const 1)))
    (global.set $fireIn (local.get $fire)))

  (func $step_player (param $dt f32)
    (local $onBeat i32)
    (if (f32.gt (global.get $moveCd) (f32.const 0.0))
      (then (global.set $moveCd (f32.sub (global.get $moveCd) (local.get $dt)))))
    (if (f32.gt (global.get $fireCd) (f32.const 0.0))
      (then (global.set $fireCd (f32.sub (global.get $fireCd) (local.get $dt)))))

    (if (i32.and (i32.ne (global.get $moveIn) (i32.const 0))
                 (f32.le (global.get $moveCd) (f32.const 0.0)))
      (then
        (global.set $pseg (call $wrap_seg (i32.add (global.get $pseg) (global.get $moveIn))))
        (global.set $moveCd (global.get $MOVE_CD))
        (global.set $moves (i32.add (global.get $moves) (i32.const 1)))))

    ;; Firing is edge-triggered. Holding it would let a player spray and be
    ;; on the beat by accident once every eighth note, which is exactly the
    ;; skill the game is about not needing.
    (if (i32.and
          (i32.and (i32.ne (global.get $fireIn) (i32.const 0))
                   (i32.eqz (global.get $prevFire)))
          (f32.le (global.get $fireCd) (f32.const 0.0)))
      (then
        (local.set $onBeat
          (if (result i32) (f32.le (call $beat_error) (global.get $BEAT_WINDOW))
            (then (i32.const 1)) (else (i32.const 0))))
        (call $spawn_bolt (local.get $onBeat))
        (global.set $shots (i32.add (global.get $shots) (i32.const 1)))
        (if (local.get $onBeat)
          (then
            (global.set $beatShots (i32.add (global.get $beatShots) (i32.const 1)))
            (global.set $groove (call $clampf
              (f32.add (global.get $groove) (global.get $GROOVE_GAIN))
              (f32.const 0.0) (global.get $GROOVE_MAX))))
          (else
            (global.set $groove (call $clampf
              (f32.sub (global.get $groove) (global.get $GROOVE_MISS))
              (f32.const 0.0) (global.get $GROOVE_MAX)))))
        (global.set $fireCd
          (f32.add (global.get $FIRE_CD)
                   (f32.mul (global.get $groove)
                            (f32.sub (global.get $FIRE_CD_GROOVE) (global.get $FIRE_CD)))))))
    (global.set $prevFire (global.get $fireIn)))

  ;; ---------------- the song ----------------

  (func $on_step
    (local $a i32) (local $seg i32)
    (global.set $steps (i32.add (global.get $steps) (i32.const 1)))
    (local.set $a (call $bar_addr (global.get $stepIdx)))
    (local.set $seg (i32.load8_u (local.get $a)))
    (if (i32.ne (local.get $seg) (i32.const 0))
      (then
        (i32.store8 offset=2 (local.get $a) (i32.const 1))
        (call $spawn_enemy (i32.sub (local.get $seg) (i32.const 1))
                           (i32.load8_u offset=1 (local.get $a)))))
    (call $on_step_enemies))

  (func $on_bar
    (global.set $bars (i32.add (global.get $bars) (i32.const 1)))
    (global.set $barIdx (i32.add (global.get $barIdx) (i32.const 1)))
    ;; A bar in which nothing reached the rim pays out. This is the only way
    ;; shield ever comes back.
    (if (i32.ne (global.get $barClean) (i32.const 0))
      (then
        (global.set $perfects (i32.add (global.get $perfects) (i32.const 1)))
        (global.set $shield (call $clampf
          (f32.add (global.get $shield) (global.get $PERFECT_BAR_HEAL))
          (f32.const 0.0) (global.get $SHIELD_MAX)))
        (call $add_score (f32.mul (global.get $SCORE_PERFECT_BAR) (call $mult)))))
    (global.set $barClean (i32.const 1))
    ;; Eight bars to a level. The level raises the tempo floor, the spawn count
    ;; and the climb rate, so it is the slow curve under groove's fast one —
    ;; and at four bars it was not slow. A bar is 2.5s at the opening tempo and
    ;; 1.5s once groove is up, so four bars put a level every six seconds and
    ;; the best pilot on the bench was dead in forty-six.
    (if (i32.eqz (i32.rem_u (global.get $barIdx) (i32.const 8)))
      (then (global.set $level (i32.add (global.get $level) (i32.const 1)))))
    (call $plan_bar))

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
    (global.set $rng (i32.const 707406378))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $shield (global.get $SHIELD_MAX))
    (global.set $groove (f32.const 0.0))
    (global.set $level (i32.const 1))
    (global.set $songT (f32.const 0.0))
    (global.set $stepIdx (i32.const 0))
    (global.set $barIdx (i32.const 0))
    (global.set $barClean (i32.const 1))
    (global.set $pseg (i32.const 0))
    (global.set $moveCd (f32.const 0.0))
    (global.set $fireCd (f32.const 0.0))
    (global.set $moveIn (i32.const 0))
    (global.set $fireIn (i32.const 0))
    (global.set $prevFire (i32.const 0))
    (global.set $steps (i32.const 0))
    (global.set $bars (i32.const 0))
    (global.set $spawns (i32.const 0))
    (global.set $shots (i32.const 0))
    (global.set $beatShots (i32.const 0))
    (global.set $kills (i32.const 0))
    (global.set $beatKills (i32.const 0))
    (global.set $leaks (i32.const 0))
    (global.set $perfects (i32.const 0))
    (global.set $moves (i32.const 0))
    (call $clear_pool (global.get $ENEMIES_OFF) (global.get $ENEMY_STRIDE)
                      (global.get $MAX_ENEMIES) (i32.const 20))
    (call $clear_pool (global.get $BOLTS_OFF) (global.get $BOLT_STRIDE)
                      (global.get $MAX_BOLTS) (i32.const 12))
    (call $plan_bar)
    ;; The first bar is planned but not played: the song starts one bar of
    ;; silence in, so a player hears the tempo before anything arrives on it.
    ;; A rhythm game that opens on the downbeat has asked for a reaction to a
    ;; beat nobody has heard yet.
    (global.set $songT (f32.const 0.0))
    (global.set $stepIdx (i32.const -16)))

  (func $step (export "step") (param $dt f32)
    (local $d f32) (local $sd f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))

    (call $step_player (local.get $d))

    ;; Groove bleeds all the time, so standing still is never a plan.
    (global.set $groove (call $clampf
      (f32.sub (global.get $groove) (f32.mul (global.get $GROOVE_DECAY) (local.get $d)))
      (f32.const 0.0) (global.get $GROOVE_MAX)))

    ;; ---- the song clock ----
    ;;
    ;; Advanced in a loop rather than with a single subtraction, because a
    ;; frame that took longer than one sixteenth note has to fire every step it
    ;; skipped. Dropping them would let a stutter swallow a spawn, and the
    ;; player would hear a bar that had a hole in it.
    (global.set $songT (f32.add (global.get $songT) (local.get $d)))
    (local.set $sd (call $step_dur))
    (block $ticked
      (loop $tlp
        (br_if $ticked (f32.lt (global.get $songT) (local.get $sd)))
        (global.set $songT (f32.sub (global.get $songT) (local.get $sd)))
        (global.set $stepIdx (i32.add (global.get $stepIdx) (i32.const 1)))
        (if (i32.ge_s (global.get $stepIdx) (global.get $STEPS_PER_BAR))
          (then
            (global.set $stepIdx (i32.const 0))
            (call $on_bar)))
        ;; The lead-in bar has a negative index and plays nothing.
        (if (i32.ge_s (global.get $stepIdx) (i32.const 0)) (then (call $on_step)))
        (br $tlp)))

    (call $step_bolts (local.get $d))
    (call $step_enemies (local.get $d)))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_shield (export "get_shield") (result f32) (global.get $shield))
  (func $get_shield_max (export "get_shield_max") (result f32) (global.get $SHIELD_MAX))
  (func $get_groove (export "get_groove") (result f32) (global.get $groove))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_seg (export "get_seg") (result i32) (global.get $pseg))
  (func $get_segments (export "get_segments") (result i32) (global.get $SEGMENTS))
  (func $get_step_idx (export "get_step_idx") (result i32) (global.get $stepIdx))
  (func $get_steps_per_bar (export "get_steps_per_bar") (result i32) (global.get $STEPS_PER_BAR))
  ;; How far through the current sixteenth we are, 0..1. The widget swells the
  ;; tube with it, so the picture breathes on the same clock the music does.
  (func $get_step_phase (export "get_step_phase") (result f32)
    (call $clampf (f32.div (global.get $songT) (call $step_dur))
                  (f32.const 0.0) (f32.const 1.0)))
  (func $get_beat_window (export "get_beat_window") (result f32) (global.get $BEAT_WINDOW))
  (func $get_bar (export "get_bar") (result i32) (global.get $barIdx))
  (func $get_fire_cd (export "get_fire_cd") (result f32) (global.get $fireCd))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_steps (export "get_steps") (result i32) (global.get $steps))
  (func $get_bars (export "get_bars") (result i32) (global.get $bars))
  (func $get_spawns (export "get_spawns") (result i32) (global.get $spawns))
  (func $get_shots (export "get_shots") (result i32) (global.get $shots))
  (func $get_beat_shots (export "get_beat_shots") (result i32) (global.get $beatShots))
  (func $get_kills (export "get_kills") (result i32) (global.get $kills))
  (func $get_beat_kills (export "get_beat_kills") (result i32) (global.get $beatKills))
  (func $get_leaks (export "get_leaks") (result i32) (global.get $leaks))
  (func $get_perfects (export "get_perfects") (result i32) (global.get $perfects))
  (func $get_moves (export "get_moves") (result i32) (global.get $moves))
)
