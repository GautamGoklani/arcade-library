(module
  ;; ============================================================
  ;; SECTOR DEFENSE — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as the other four (globals block
  ;; at the top, entity pools at fixed offsets in linear memory, xorshift RNG,
  ;; an init/set_input/step/get_* export surface) and nothing else. Every
  ;; constant and every routine below is its own.
  ;;
  ;; What is new here, and what the rest of the library did not need:
  ;;
  ;;   • Enemies with individual intent. Pixel Wave's swarm patrols as a body;
  ;;     every attacker here picks its own lateral target, re-rolls it on its
  ;;     own clock, and reacts to the defender. No two runs look alike.
  ;;   • Two meters instead of lives. A regenerating shield absorbs fire; what
  ;;     it cannot absorb damages the sector, and the sector is the only way to
  ;;     lose. The defender is never destroyed, so there is no respawn at all.
  ;;   • A combo that decays. Scoring is a function of how recently you last
  ;;     hit something, which makes the pace of the fight worth points.
  ;;
  ;; The `phase` field on each attacker is unused by the simulation. It is a
  ;; per-attacker random constant the renderer animates from, so that two
  ;; attackers spawned in the same frame do not bob in lockstep.
  ;;
  ;; JavaScript owns no game state. It forwards input, calls step(dt), and
  ;; reads entity records straight out of the memory below to draw them.
  ;; ============================================================
  ;; Like Worm Chase, this module has **no imports**. It was drafted with the
  ;; usual sinf/cosf pair and neither turned out to be reachable: attackers
  ;; steer toward a target column rather than along a curve, everything falls
  ;; straight down or on a fixed lateral, and every collision is an
  ;; axis-aligned box test — so there is no angle and no sqrt anywhere. An
  ;; import that is never called is a dependency for nothing, so they went.
  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; player   @0    : x, y, alive                          (3 f32, padded to 16)
  ;; enemies  @16   : stride 40, MAX_ENEMIES = 24
  ;;                  x, y, vx, vy, hp, kind, active, phase, cd, targetX
  ;;                  ends at 16 + 24*40 = 976
  ;; pbullets @976  : stride 24, MAX_PBULLETS = 20
  ;;                  x, y, vx, vy, life, active
  ;;                  ends at 976 + 20*24 = 1456
  ;; ebullets @1456 : stride 24, MAX_EBULLETS = 30
  ;;                  x, y, vx, vy, life, active
  ;;                  ends at 1456 + 30*24 = 2176
  ;;
  ;; enemy kinds: 0 = drifter, 1 = weaver, 2 = diver, 3 = hulk (2 hp)
  ;;
  ;; Scalars — score, shield, sector, combo — live in globals rather than
  ;; memory, as in worm-chase and asteroid-miner: the get_* readers are the
  ;; only consumer, and a global is one instruction to read.
  ;; ===================================================

  (global $PLAYER_OFF i32 (i32.const 0))
  (global $ENEMIES_OFF i32 (i32.const 16))
  (global $ENEMY_STRIDE i32 (i32.const 40))
  (global $MAX_ENEMIES i32 (i32.const 24))
  (global $PB_OFF i32 (i32.const 976))
  (global $PB_STRIDE i32 (i32.const 24))
  (global $MAX_PB i32 (i32.const 20))
  (global $EB_OFF i32 (i32.const 1456))
  (global $EB_STRIDE i32 (i32.const 24))
  (global $MAX_EB i32 (i32.const 30))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))
  (global $TAU f32 (f32.const 6.28318531))

  ;; ---- the defender ----
  ;; One axis. The defender holds a line and the whole game is about where on
  ;; that line to be, which is a decision a player can actually make under
  ;; pressure — unlike free flight, where the answer is usually "somewhere else".
  (global $PLAYER_Y f32 (f32.const 648.0))
  (global $PLAYER_HALF_W f32 (f32.const 22.0))
  (global $PLAYER_HALF_H f32 (f32.const 14.0))
  (global $PLAYER_SPEED f32 (f32.const 430.0))
  (global $FIRE_CD f32 (f32.const 0.185))
  (global $PB_SPEED f32 (f32.const 640.0))
  (global $PB_LIFE f32 (f32.const 1.3))
  (global $PB_HALF f32 (f32.const 4.0))

  ;; ---- the line being defended ----
  (global $SECTOR_Y f32 (f32.const 690.0))
  (global $SECTOR_MAX f32 (f32.const 100.0))
  (global $BREACH_DAMAGE f32 (f32.const 18.0))   ;; an attacker crossing the line
  (global $LEAK_DAMAGE f32 (f32.const 10.0))     ;; a hit the shield could not take

  ;; ---- the shield ----
  ;; It regenerates, but only after a pause. That delay is the whole mechanic:
  ;; it converts "don't get hit" into "break contact and recover", which is a
  ;; decision rather than a reflex.
  (global $SHIELD_MAX f32 (f32.const 100.0))
  (global $SHIELD_HIT f32 (f32.const 34.0))
  (global $SHIELD_REGEN f32 (f32.const 11.0))    ;; per second
  (global $SHIELD_DELAY f32 (f32.const 2.6))     ;; seconds of calm before it starts

  ;; ---- attackers ----
  (global $ENEMY_HALF_W f32 (f32.const 17.0))
  (global $ENEMY_HALF_H f32 (f32.const 14.0))
  (global $HULK_HALF_W f32 (f32.const 24.0))
  (global $DESCENT f32 (f32.const 22.0))
  (global $DESCENT_STEP f32 (f32.const 3.4))
  ;; The cap sat at 62 in the first build, which is 11 seconds to cross the
  ;; field — slow enough that the headless pilot cleared 28 waves without a
  ;; single attacker ever reaching the line. A ceiling the player never feels
  ;; is not a difficulty curve.
  (global $DESCENT_CAP f32 (f32.const 95.0))
  (global $LATERAL f32 (f32.const 95.0))
  (global $LATERAL_STEP f32 (f32.const 7.0))
  (global $DIVE_MUL f32 (f32.const 3.4))
  (global $EB_SPEED f32 (f32.const 250.0))
  (global $EB_LIFE f32 (f32.const 4.0))
  (global $EB_HALF f32 (f32.const 5.0))
  ;; Seconds between arrivals at level 1, and how much sooner each level packs
  ;; them. Without the taper a late wave is just a longer wave: 26 attackers at
  ;; a fixed 1.15s drip is thirty seconds of spawning alone, which the bench
  ;; measured and which is not what "harder" should mean.
  (global $SPAWN_EVERY f32 (f32.const 1.15))
  (global $SPAWN_STEP f32 (f32.const 0.035))
  (global $SPAWN_MIN f32 (f32.const 0.34))
  (global $MARGIN f32 (f32.const 46.0))

  ;; ---- combo ----
  ;; 2.4 seconds is long enough to cross a third of the arena and still be
  ;; rewarded for it, short enough that it lapses if you stop pressing.
  (global $COMBO_WINDOW f32 (f32.const 2.4))
  (global $COMBO_CAP f32 (f32.const 30.0))
  (global $SCORE_KILL f32 (f32.const 20.0))
  (global $SCORE_WAVE f32 (f32.const 150.0))

  (global $rng (mut i32) (i32.const 88675123))
  (global $level (mut i32) (i32.const 1))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $shield (mut f32) (f32.const 100.0))
  (global $sector (mut f32) (f32.const 100.0))
  (global $combo (mut f32) (f32.const 0.0))
  (global $comboTimer (mut f32) (f32.const 0.0))
  (global $bestCombo (mut f32) (f32.const 0.0))
  (global $toSpawn (mut i32) (i32.const 0))      ;; attackers still to arrive
  (global $spawnAcc (mut f32) (f32.const 0.0))
  (global $calm (mut f32) (f32.const 0.0))       ;; seconds since the last hit
  (global $fireCd (mut f32) (f32.const 0.0))

  ;; input, as reported by set_input each frame
  (global $moveIn (mut f32) (f32.const 0.0))
  (global $fireIn (mut i32) (i32.const 0))

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $shots (mut i32) (i32.const 0))
  (global $kills (mut i32) (i32.const 0))
  (global $hurts (mut i32) (i32.const 0))        ;; shield took a hit
  (global $leaks (mut i32) (i32.const 0))        ;; sector took a hit
  (global $breaches (mut i32) (i32.const 0))     ;; an attacker crossed the line
  (global $waves (mut i32) (i32.const 0))

  ;; ---------------- helpers ----------------

  (func $enemy_addr (param $i i32) (result i32)
    (i32.add (global.get $ENEMIES_OFF) (i32.mul (local.get $i) (global.get $ENEMY_STRIDE))))
  (func $pb_addr (param $i i32) (result i32)
    (i32.add (global.get $PB_OFF) (i32.mul (local.get $i) (global.get $PB_STRIDE))))
  (func $eb_addr (param $i i32) (result i32)
    (i32.add (global.get $EB_OFF) (i32.mul (local.get $i) (global.get $EB_STRIDE))))

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

  ;; Overlap of two axis-aligned boxes. Every collision in this game is this
  ;; function — there is no circle anywhere, so there is no sqrt either.
  (func $overlap (param $ax f32) (param $ay f32) (param $ahw f32) (param $ahh f32)
                 (param $bx f32) (param $by f32) (param $bhw f32) (param $bhh f32) (result i32)
    (i32.and
      (f32.lt (f32.abs (f32.sub (local.get $ax) (local.get $bx)))
              (f32.add (local.get $ahw) (local.get $bhw)))
      (f32.lt (f32.abs (f32.sub (local.get $ay) (local.get $by)))
              (f32.add (local.get $ahh) (local.get $bhh)))))

  (func $player_x (result f32) (f32.load (global.get $PLAYER_OFF)))

  (func $enemy_half_w (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
      (then (global.get $HULK_HALF_W))
      (else (global.get $ENEMY_HALF_W))))

  ;; The scoring multiplier: 1x with no combo, rising a tenth per kill, capped
  ;; at 4x. Reading it is how the HUD shows what the streak is worth.
  (func $multiplier (export "get_mult") (result f32)
    (call $clampf (f32.add (f32.const 1.0) (f32.mul (global.get $combo) (f32.const 0.1)))
                  (f32.const 1.0) (f32.const 4.0)))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  (func $descent_speed (result f32)
    (call $clampf
      (f32.add (global.get $DESCENT)
        (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                 (global.get $DESCENT_STEP)))
      (global.get $DESCENT) (global.get $DESCENT_CAP)))

  (func $lateral_speed (result f32)
    (f32.add (global.get $LATERAL)
      (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
               (global.get $LATERAL_STEP))))

  ;; How many attackers a wave sends, and how many kinds are in play. Kinds
  ;; arrive one level at a time so each new behaviour is met on its own before
  ;; it is met in a crowd.
  (func $wave_size (result i32)
    (call $clampi (i32.add (i32.const 3) (i32.mul (global.get $level) (i32.const 2)))
                  (i32.const 5) (i32.const 26)))

  (func $spawn_gap (result f32)
    (call $clampf
      (f32.sub (global.get $SPAWN_EVERY)
        (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                 (global.get $SPAWN_STEP)))
      (global.get $SPAWN_MIN) (global.get $SPAWN_EVERY)))

  (func $kinds_in_play (result i32)
    (call $clampi (global.get $level) (i32.const 1) (i32.const 4)))

  ;; Seconds between an attacker's shots. Falls with the level, and a hulk
  ;; fires half as often as it is twice as hard to remove.
  (func $fire_gap (param $kind i32) (result f32)
    (local $g f32)
    (local.set $g (call $frand
      (f32.sub (f32.const 2.4) (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.09)))
      (f32.sub (f32.const 4.6) (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.14)))))
    (local.set $g (call $clampf (local.get $g) (f32.const 0.75) (f32.const 5.0)))
    (if (i32.eq (local.get $kind) (i32.const 3))
      (then (local.set $g (f32.mul (local.get $g) (f32.const 1.8)))))
    (local.get $g))

  ;; ---------------- spawning ----------------

  (func $spawn_enemy
    (local $i i32) (local $a i32) (local $kind i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $kind (i32.trunc_f32_s
              (call $frand (f32.const 0.0) (f32.convert_i32_s (call $kinds_in_play)))))
            (f32.store offset=0 (local.get $a)
              (call $frand (global.get $MARGIN) (f32.sub (global.get $WORLD_W) (global.get $MARGIN))))
            (f32.store offset=4 (local.get $a) (call $frand (f32.const -34.0) (f32.const -18.0)))
            (f32.store offset=8 (local.get $a) (f32.const 0.0))
            (f32.store offset=12 (local.get $a) (call $descent_speed))
            (f32.store offset=16 (local.get $a)
              (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
                (then (f32.const 2.0)) (else (f32.const 1.0))))
            (f32.store offset=20 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=24 (local.get $a) (f32.const 1.0))
            (f32.store offset=28 (local.get $a) (call $frand (f32.const 0.0) (global.get $TAU)))
            (f32.store offset=32 (local.get $a) (call $fire_gap (local.get $kind)))
            (f32.store offset=36 (local.get $a)
              (call $frand (global.get $MARGIN) (f32.sub (global.get $WORLD_W) (global.get $MARGIN))))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $fire_player
    (local $i i32) (local $a i32)
    (if (f32.gt (global.get $fireCd) (f32.const 0.0)) (then (return)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_PB)))
        (local.set $a (call $pb_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (call $player_x))
            (f32.store offset=4 (local.get $a)
              (f32.sub (global.get $PLAYER_Y) (global.get $PLAYER_HALF_H)))
            (f32.store offset=8 (local.get $a) (f32.const 0.0))
            (f32.store offset=12 (local.get $a) (f32.neg (global.get $PB_SPEED)))
            (f32.store offset=16 (local.get $a) (global.get $PB_LIFE))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (global.set $fireCd (global.get $FIRE_CD))
            (global.set $shots (i32.add (global.get $shots) (i32.const 1)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Attackers lead their shots a little at higher levels: the bullet is aimed
  ;; at where the defender is, with a sideways component that grows with the
  ;; level, so late waves cannot be beaten by standing still and strafing late.
  (func $fire_enemy (param $ex f32) (param $ey f32) (param $kind i32)
    (local $i i32) (local $a i32) (local $dx f32) (local $lead f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_EB)))
        (local.set $a (call $eb_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $lead (call $clampf
              (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.045))
              (f32.const 0.0) (f32.const 0.45)))
            (local.set $dx (f32.mul
              (call $clampf (f32.sub (call $player_x) (local.get $ex))
                            (f32.const -260.0) (f32.const 260.0))
              (local.get $lead)))
            (f32.store offset=0 (local.get $a) (local.get $ex))
            (f32.store offset=4 (local.get $a) (local.get $ey))
            (f32.store offset=8 (local.get $a) (local.get $dx))
            (f32.store offset=12 (local.get $a) (global.get $EB_SPEED))
            (f32.store offset=16 (local.get $a) (global.get $EB_LIFE))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- the defender ----------------

  (func $step_player (param $dt f32)
    (local $x f32)
    (local.set $x (f32.add (call $player_x)
      (f32.mul (f32.mul (global.get $moveIn) (global.get $PLAYER_SPEED)) (local.get $dt))))
    (f32.store (global.get $PLAYER_OFF)
      (call $clampf (local.get $x) (global.get $PLAYER_HALF_W)
                    (f32.sub (global.get $WORLD_W) (global.get $PLAYER_HALF_W))))
    (if (f32.gt (global.get $fireCd) (f32.const 0.0))
      (then (global.set $fireCd (f32.sub (global.get $fireCd) (local.get $dt)))))
    (if (i32.ne (global.get $fireIn) (i32.const 0)) (then (call $fire_player))))

  ;; The shield only recovers after a stretch with nothing landing. `$calm` is
  ;; reset by every hit, so pressure suppresses regeneration exactly as long as
  ;; it lasts.
  (func $step_shield (param $dt f32)
    (global.set $calm (f32.add (global.get $calm) (local.get $dt)))
    (if (f32.gt (global.get $calm) (global.get $SHIELD_DELAY))
      (then
        (global.set $shield (call $clampf
          (f32.add (global.get $shield) (f32.mul (global.get $SHIELD_REGEN) (local.get $dt)))
          (f32.const 0.0) (global.get $SHIELD_MAX))))))

  ;; A hit lands on the shield if there is any left, and on the sector if there
  ;; is not. Partial shields absorb the whole hit — a shield that let some
  ;; through would need the player to track two numbers to predict one outcome.
  (func $take_hit
    (global.set $calm (f32.const 0.0))
    (global.set $combo (f32.const 0.0))
    (global.set $comboTimer (f32.const 0.0))
    (if (f32.gt (global.get $shield) (f32.const 0.0))
      (then
        (global.set $shield (call $clampf (f32.sub (global.get $shield) (global.get $SHIELD_HIT))
                                          (f32.const 0.0) (global.get $SHIELD_MAX)))
        (global.set $hurts (i32.add (global.get $hurts) (i32.const 1))))
      (else
        (global.set $leaks (i32.add (global.get $leaks) (i32.const 1)))
        (call $damage_sector (global.get $LEAK_DAMAGE)))))

  (func $damage_sector (param $n f32)
    (global.set $sector (call $clampf (f32.sub (global.get $sector) (local.get $n))
                                      (f32.const 0.0) (global.get $SECTOR_MAX)))
    (if (f32.le (global.get $sector) (f32.const 0.0))
      (then (global.set $gameOver (i32.const 1)))))

  ;; ---------------- attackers ----------------

  (func $step_enemies (param $dt f32)
    (local $i i32) (local $a i32) (local $kind i32)
    (local $x f32) (local $y f32) (local $tx f32) (local $vy f32) (local $lat f32)
    (local.set $lat (call $lateral_speed))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $kind (i32.trunc_f32_s (f32.load offset=20 (local.get $a))))
            (local.set $x (f32.load offset=0 (local.get $a)))
            (local.set $y (f32.load offset=4 (local.get $a)))
            (local.set $tx (f32.load offset=36 (local.get $a)))
            (local.set $vy (f32.load offset=12 (local.get $a)))

            ;; Lateral intent. Each attacker walks toward a target column of
            ;; its own and picks a new one on arrival — which is what makes the
            ;; formation unreadable without making any single attacker
            ;; unfair: it always moves in a straight line you can see.
            (if (f32.lt (f32.abs (f32.sub (local.get $x) (local.get $tx))) (f32.const 10.0))
              (then
                (f32.store offset=36 (local.get $a)
                  (call $frand (global.get $MARGIN)
                               (f32.sub (global.get $WORLD_W) (global.get $MARGIN))))
                (local.set $tx (f32.load offset=36 (local.get $a)))))

            ;; A weaver re-rolls early and often, so it changes its mind
            ;; mid-crossing; a hulk barely bothers.
            (if (i32.eq (local.get $kind) (i32.const 1))
              (then
                (local.set $lat (f32.mul (call $lateral_speed) (f32.const 1.55)))
                (if (f32.lt (call $rand_f32) (f32.mul (f32.const 0.9) (local.get $dt)))
                  (then
                    (f32.store offset=36 (local.get $a)
                      (call $frand (global.get $MARGIN)
                                   (f32.sub (global.get $WORLD_W) (global.get $MARGIN)))))))
              (else
                (if (i32.eq (local.get $kind) (i32.const 3))
                  (then (local.set $lat (f32.mul (call $lateral_speed) (f32.const 0.45))))
                  (else (local.set $lat (call $lateral_speed))))))

            (if (f32.gt (local.get $tx) (local.get $x))
              (then (local.set $x (f32.add (local.get $x) (f32.mul (local.get $lat) (local.get $dt)))))
              (else (local.set $x (f32.sub (local.get $x) (f32.mul (local.get $lat) (local.get $dt))))))

            ;; A diver commits: line up with the defender and it drops. It is
            ;; the one attacker that reacts to where you are, and the counter
            ;; is simply not to be under it.
            (if (i32.eq (local.get $kind) (i32.const 2))
              (then
                (if (f32.lt (f32.abs (f32.sub (local.get $x) (call $player_x))) (f32.const 52.0))
                  (then (local.set $vy (f32.mul (call $descent_speed) (global.get $DIVE_MUL))))
                  (else (local.set $vy (call $descent_speed))))
                (f32.store offset=12 (local.get $a) (local.get $vy))))

            (local.set $y (f32.add (local.get $y) (f32.mul (local.get $vy) (local.get $dt))))
            (f32.store offset=0 (local.get $a)
              (call $clampf (local.get $x) (global.get $MARGIN)
                            (f32.sub (global.get $WORLD_W) (global.get $MARGIN))))
            (f32.store offset=4 (local.get $a) (local.get $y))

            ;; Firing.
            (f32.store offset=32 (local.get $a)
              (f32.sub (f32.load offset=32 (local.get $a)) (local.get $dt)))
            (if (f32.le (f32.load offset=32 (local.get $a)) (f32.const 0.0))
              (then
                (f32.store offset=32 (local.get $a) (call $fire_gap (local.get $kind)))
                (if (f32.gt (local.get $y) (f32.const 0.0))
                  (then (call $fire_enemy (local.get $x) (local.get $y) (local.get $kind))))))

            ;; Crossing the line is the failure this game is about.
            (if (f32.gt (local.get $y) (global.get $SECTOR_Y))
              (then
                (f32.store offset=24 (local.get $a) (f32.const 0.0))
                (global.set $breaches (i32.add (global.get $breaches) (i32.const 1)))
                (global.set $combo (f32.const 0.0))
                (global.set $comboTimer (f32.const 0.0))
                (call $damage_sector (global.get $BREACH_DAMAGE))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $kill_enemy (param $a i32)
    (f32.store offset=24 (local.get $a) (f32.const 0.0))
    (global.set $kills (i32.add (global.get $kills) (i32.const 1)))
    ;; Score is paid at the multiplier the streak had *before* this kill
    ;; extended it, so the first kill of a streak is worth 1x and the reward
    ;; is unambiguously for keeping one going.
    (call $add_score (f32.mul (global.get $SCORE_KILL) (call $multiplier)))
    (global.set $combo (call $clampf (f32.add (global.get $combo) (f32.const 1.0))
                                     (f32.const 0.0) (global.get $COMBO_CAP)))
    (if (f32.gt (global.get $combo) (global.get $bestCombo))
      (then (global.set $bestCombo (global.get $combo))))
    (global.set $comboTimer (global.get $COMBO_WINDOW)))

  (func $step_pbullets (param $dt f32)
    (local $i i32) (local $j i32) (local $a i32) (local $e i32)
    (local $x f32) (local $y f32) (local $kind i32)
    (local.set $i (i32.const 0))
    (block $bdone
      (loop $blp
        (br_if $bdone (i32.ge_s (local.get $i) (global.get $MAX_PB)))
        (local.set $a (call $pb_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=16 (local.get $a)
              (f32.sub (f32.load offset=16 (local.get $a)) (local.get $dt)))
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
              (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt))))
            (local.set $x (f32.load offset=0 (local.get $a)))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (if (i32.or (f32.le (f32.load offset=16 (local.get $a)) (f32.const 0.0))
                        (f32.lt (local.get $y) (f32.const -20.0)))
              (then (f32.store offset=20 (local.get $a) (f32.const 0.0)))
              (else
                (local.set $j (i32.const 0))
                (block $edone
                  (loop $elp
                    (br_if $edone (i32.ge_s (local.get $j) (global.get $MAX_ENEMIES)))
                    (local.set $e (call $enemy_addr (local.get $j)))
                    (if (f32.gt (f32.load offset=24 (local.get $e)) (f32.const 0.0))
                      (then
                        (local.set $kind (i32.trunc_f32_s (f32.load offset=20 (local.get $e))))
                        (if (call $overlap
                              (local.get $x) (local.get $y)
                              (global.get $PB_HALF) (global.get $PB_HALF)
                              (f32.load offset=0 (local.get $e)) (f32.load offset=4 (local.get $e))
                              (call $enemy_half_w (local.get $kind)) (global.get $ENEMY_HALF_H))
                          (then
                            (f32.store offset=20 (local.get $a) (f32.const 0.0))
                            (f32.store offset=16 (local.get $e)
                              (f32.sub (f32.load offset=16 (local.get $e)) (f32.const 1.0)))
                            (if (f32.le (f32.load offset=16 (local.get $e)) (f32.const 0.0))
                              (then (call $kill_enemy (local.get $e))))
                            (br $edone)))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $elp)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $blp))))

  (func $step_ebullets (param $dt f32)
    (local $i i32) (local $a i32) (local $x f32) (local $y f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_EB)))
        (local.set $a (call $eb_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=16 (local.get $a)
              (f32.sub (f32.load offset=16 (local.get $a)) (local.get $dt)))
            (local.set $x (f32.add (f32.load offset=0 (local.get $a))
              (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt))))
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
              (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt))))
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (if (i32.or (f32.le (f32.load offset=16 (local.get $a)) (f32.const 0.0))
                        (f32.gt (local.get $y) (global.get $WORLD_H)))
              (then (f32.store offset=20 (local.get $a) (f32.const 0.0)))
              (else
                (if (call $overlap
                      (local.get $x) (local.get $y) (global.get $EB_HALF) (global.get $EB_HALF)
                      (call $player_x) (global.get $PLAYER_Y)
                      (global.get $PLAYER_HALF_W) (global.get $PLAYER_HALF_H))
                  (then
                    (f32.store offset=20 (local.get $a) (f32.const 0.0))
                    (call $take_hit)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $enemies_alive (export "enemies_alive") (result i32)
    (local $i i32) (local $n i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (if (f32.gt (f32.load offset=24 (call $enemy_addr (local.get $i))) (f32.const 0.0))
          (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $n))

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

  (func $build_wave
    (call $clear_pool (global.get $ENEMIES_OFF) (global.get $ENEMY_STRIDE)
                      (global.get $MAX_ENEMIES) (i32.const 24))
    (call $clear_pool (global.get $PB_OFF) (global.get $PB_STRIDE)
                      (global.get $MAX_PB) (i32.const 20))
    (call $clear_pool (global.get $EB_OFF) (global.get $EB_STRIDE)
                      (global.get $MAX_EB) (i32.const 20))
    (global.set $toSpawn (call $wave_size))
    ;; The first attacker arrives after a beat, not instantly: a wave that
    ;; began mid-screen would punish a player still reading the last one. The
    ;; beat is short, though — at level 1 an attacker enters at the top edge
    ;; and descends at 22px/s, so too long a pause leaves the player looking at
    ;; an empty field wondering whether the game has started.
    (global.set $spawnAcc (f32.const -0.25))
    (global.set $fireCd (f32.const 0.0)))

  (func $init (export "init")
    (global.set $rng (i32.const 88675123))
    (global.set $level (i32.const 1))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $shield (global.get $SHIELD_MAX))
    (global.set $sector (global.get $SECTOR_MAX))
    (global.set $combo (f32.const 0.0))
    (global.set $comboTimer (f32.const 0.0))
    (global.set $bestCombo (f32.const 0.0))
    (global.set $calm (f32.const 0.0))
    (global.set $moveIn (f32.const 0.0))
    (global.set $fireIn (i32.const 0))
    (global.set $shots (i32.const 0))
    (global.set $kills (i32.const 0))
    (global.set $hurts (i32.const 0))
    (global.set $leaks (i32.const 0))
    (global.set $breaches (i32.const 0))
    (global.set $waves (i32.const 0))
    (f32.store (global.get $PLAYER_OFF) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
    (f32.store offset=4 (global.get $PLAYER_OFF) (global.get $PLAYER_Y))
    (f32.store offset=8 (global.get $PLAYER_OFF) (f32.const 1.0))
    (call $build_wave))

  ;; Surviving a wave repairs some of the sector. Without it a single bad wave
  ;; on level 2 is carried for the rest of the run, and the game becomes about
  ;; a mistake made minutes ago.
  (func $next_wave
    (global.set $level (i32.add (global.get $level) (i32.const 1)))
    (global.set $waves (i32.add (global.get $waves) (i32.const 1)))
    (call $add_score (global.get $SCORE_WAVE))
    (call $add_score (global.get $shield))
    (global.set $sector (call $clampf (f32.add (global.get $sector) (f32.const 15.0))
                                      (f32.const 0.0) (global.get $SECTOR_MAX)))
    (global.set $shield (global.get $SHIELD_MAX))
    (call $build_wave))

  (func $set_input (export "set_input") (param $move f32) (param $fire i32)
    (global.set $moveIn (call $clampf (local.get $move) (f32.const -1.0) (f32.const 1.0)))
    (global.set $fireIn (local.get $fire)))

  (func $step (export "step") (param $dt f32)
    (local $d f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))

    (call $step_player (local.get $d))
    (call $step_shield (local.get $d))

    ;; The combo is a decaying resource, not a counter of consecutive hits:
    ;; letting the window lapse costs it just as surely as being hit does.
    (if (f32.gt (global.get $comboTimer) (f32.const 0.0))
      (then
        (global.set $comboTimer (f32.sub (global.get $comboTimer) (local.get $d)))
        (if (f32.le (global.get $comboTimer) (f32.const 0.0))
          (then (global.set $combo (f32.const 0.0))))))

    ;; Attackers arrive on a drip rather than all at once, so a wave is a
    ;; stream to be managed rather than a wall to be survived.
    (if (i32.gt_s (global.get $toSpawn) (i32.const 0))
      (then
        (global.set $spawnAcc (f32.add (global.get $spawnAcc) (local.get $d)))
        (if (f32.ge (global.get $spawnAcc) (call $spawn_gap))
          (then
            (global.set $spawnAcc (f32.sub (global.get $spawnAcc) (call $spawn_gap)))
            (call $spawn_enemy)
            (global.set $toSpawn (i32.sub (global.get $toSpawn) (i32.const 1)))))))

    (call $step_enemies (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (call $step_pbullets (local.get $d))
    (call $step_ebullets (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))

    (if (i32.and (i32.le_s (global.get $toSpawn) (i32.const 0))
                 (i32.eqz (call $enemies_alive)))
      (then (call $next_wave))))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_shield (export "get_shield") (result f32) (global.get $shield))
  (func $get_shield_max (export "get_shield_max") (result f32) (global.get $SHIELD_MAX))
  (func $get_sector (export "get_sector") (result f32) (global.get $sector))
  (func $get_sector_max (export "get_sector_max") (result f32) (global.get $SECTOR_MAX))
  (func $get_sector_y (export "get_sector_y") (result f32) (global.get $SECTOR_Y))
  (func $get_combo (export "get_combo") (result f32) (global.get $combo))
  (func $get_best_combo (export "get_best_combo") (result f32) (global.get $bestCombo))
  (func $get_combo_timer (export "get_combo_timer") (result f32) (global.get $comboTimer))
  (func $get_combo_window (export "get_combo_window") (result f32) (global.get $COMBO_WINDOW))
  (func $get_to_spawn (export "get_to_spawn") (result i32) (global.get $toSpawn))
  (func $get_player_x (export "get_player_x") (result f32) (call $player_x))
  (func $get_calm (export "get_calm") (result f32) (global.get $calm))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_shots (export "get_shots") (result i32) (global.get $shots))
  (func $get_kills (export "get_kills") (result i32) (global.get $kills))
  (func $get_hurts (export "get_hurts") (result i32) (global.get $hurts))
  (func $get_leaks (export "get_leaks") (result i32) (global.get $leaks))
  (func $get_breaches (export "get_breaches") (result i32) (global.get $breaches))
  (func $get_waves (export "get_waves") (result i32) (global.get $waves))
)
