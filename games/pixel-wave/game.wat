(module
  (import "env" "sinf" (func $sinf (param f32) (result f32)))
  (import "env" "cosf" (func $cosf (param f32) (result f32)))

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; player    @0     : x,y,vx,vy,heading,alive                 (6 f32 = 24 B)
  ;; bots      @24    : stride 40B, MAX_BOTS=33
  ;;             x,y,vx,vy,heading,alive,cooldown,wanderTimer,targetX,targetY
  ;;             ends at 24 + 33*40 = 1344
  ;; bullets   @1344  : stride 24B, MAX_BULLETS=160 (x,y,vx,vy,owner,active)
  ;;             ends at 1344 + 160*24 = 5184
  ;; asteroids @5184  : stride 24B, MAX_AST=20 (x,y,vx,vy,radius,active)
  ;;             ends at 5184 + 20*24 = 5664
  ;; score @5664  lives @5668
  ;; ===================================================

  (global $MAX_BOTS i32 (i32.const 33))
  (global $MAX_BULLETS i32 (i32.const 160))
  (global $MAX_AST i32 (i32.const 20))
  (global $BOTS_OFF i32 (i32.const 24))
  (global $BOT_STRIDE i32 (i32.const 40))
  (global $BULLETS_OFF i32 (i32.const 1344))
  (global $BULLET_STRIDE i32 (i32.const 24))
  (global $AST_OFF i32 (i32.const 5184))
  (global $AST_STRIDE i32 (i32.const 24))
  (global $SCORE_OFF i32 (i32.const 5664))
  (global $LIVES_OFF i32 (i32.const 5668))

  (global $WORLD_W f32 (f32.const 1200.0))
  (global $WORLD_H f32 (f32.const 750.0))
  (global $MID_Y f32 (f32.const 375.0))

  ;; Turn rate in radians/sec, applied directly (heading += rotDir * this * dt)
  ;; — note the docs call it an acceleration in §7.1; it is not. Was 4.2, i.e.
  ;; 241°/sec, which made A and D impossible to aim with. 2.5 is ~143°/sec.
  (global $ROT_SPEED f32 (f32.const 2.5))
  (global $ACCEL f32 (f32.const 420.0))
  (global $DRAG f32 (f32.const 0.6))
  (global $MAX_SPEED f32 (f32.const 270.0))
  (global $PLAYER_BULLET_SPEED f32 (f32.const 620.0))
  ;; ---- difficulty tuning, 2026-08 ---------------------------------------
  ;; Eased so a first-time visitor gets past the opening levels. Original values
  ;; are noted per line; the untouched engine is still embedded in
  ;; pixel-wave-standalone.html if the old balance is ever wanted back.
  (global $PLAYER_FIRE_CD f32 (f32.const 0.14))   ;; was 0.2
  (global $SHIP_R f32 (f32.const 19.0))
  (global $BOT_R f32 (f32.const 18.0))
  (global $BULLET_HIT_R f32 (f32.const 18.0))
  (global $BOT_SPEED_BASE f32 (f32.const 50.0))   ;; was 60

  (global $rng (mut i32) (i32.const 88172645))
  (global $level (mut i32) (i32.const 1))
  (global $rotDir (mut f32) (f32.const 0.0))
  (global $thrustOn (mut i32) (i32.const 0))
  (global $firing (mut i32) (i32.const 0))
  (global $playerCooldown (mut f32) (f32.const 0.0))
  (global $gameOver (mut i32) (i32.const 0))
  (global $astTimer (mut f32) (f32.const 2.0))

  ;; ---- burst fire ---------------------------------------------------------
  ;; Holding Space used to stream bullets for as long as it was down. One press
  ;; now buys exactly $BURST_SIZE rounds, spaced by $BURST_GAP, and the next
  ;; burst needs a fresh press: $prevFiring holds last frame's input so the
  ;; engine can see the edge, since set_input only reports the held state.
  (global $BURST_SIZE i32 (i32.const 3))
  (global $BURST_GAP f32 (f32.const 0.09))
  ;; Recovery after the third round, so mashing Space cannot beat the old
  ;; hold-to-fire rate — see "Burst fire" in README.md for the measurements.
  (global $BURST_RECOVER f32 (f32.const 0.35))
  (global $prevFiring (mut i32) (i32.const 0))
  (global $burstLeft (mut i32) (i32.const 0))
  (global $pendingFire (mut i32) (i32.const 0))

  ;; ---- event counters ------------------------------------------------------
  ;; JavaScript diffs these between frames to decide what to play and what to
  ;; flash. They only ever increase, and init zeroes them.
  ;;
  ;; This was the first title, and it predates the convention the eight after
  ;; it follow. Its widget used to work out what had happened by watching state
  ;; change — a bot's alive flag dropping, the lives float going down — which
  ;; chapter 15 quoted as the crude version, with the limitation it has: two
  ;; kills in one frame are one event, and a kill cannot be told from a bot
  ;; that rammed you, because both clear the same flag. The counters below are
  ;; where each of those is *decided*, so they are exact by construction.
  (global $shots (mut i32) (i32.const 0))        ;; a player round left the gun
  (global $enemyShots (mut i32) (i32.const 0))   ;; a bot fired
  (global $kills (mut i32) (i32.const 0))        ;; a bot shot down
  (global $rocks (mut i32) (i32.const 0))        ;; an asteroid shot down
  (global $hurts (mut i32) (i32.const 0))        ;; a life lost, to anything
  (global $waves (mut i32) (i32.const 0))        ;; a wave cleared

  ;; ---------------- helpers ----------------

  (func $bot_addr (param $i i32) (result i32)
    (i32.add (global.get $BOTS_OFF) (i32.mul (local.get $i) (global.get $BOT_STRIDE))))
  (func $bullet_addr (param $i i32) (result i32)
    (i32.add (global.get $BULLETS_OFF) (i32.mul (local.get $i) (global.get $BULLET_STRIDE))))
  (func $ast_addr (param $i i32) (result i32)
    (i32.add (global.get $AST_OFF) (i32.mul (local.get $i) (global.get $AST_STRIDE))))

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

  ;; ramp level: max(0, level - 30). Stat difficulty only ramps after lvl 30.
  (func $ramp_f (result f32)
    (local $r f32)
    (local.set $r (f32.sub (f32.convert_i32_s (global.get $level)) (f32.const 30.0)))
    (if (f32.lt (local.get $r) (f32.const 0.0)) (then (local.set $r (f32.const 0.0))))
    (local.get $r))

  (func $spawn_bullet (param $owner i32) (param $x f32) (param $y f32) (param $vx f32) (param $vy f32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
        (local.set $a (call $bullet_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (local.get $vx))
            (f32.store offset=12 (local.get $a) (local.get $vy))
            (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $owner)))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $spawn_asteroid
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_AST)))
        (local.set $a (call $ast_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (call $frand (f32.const 24.0) (f32.sub (global.get $WORLD_W) (f32.const 24.0))))
            (f32.store offset=4 (local.get $a) (f32.const -30.0))
            (f32.store offset=8 (local.get $a) (call $frand (f32.const -45.0) (f32.const 45.0)))
            ;; fall speed, was 90–150 with a +6/level ramp
            (f32.store offset=12 (local.get $a) (f32.add (call $frand (f32.const 70.0) (f32.const 115.0)) (f32.mul (call $ramp_f) (f32.const 4.0))))
            (f32.store offset=16 (local.get $a) (call $frand (f32.const 16.0) (f32.const 34.0)))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; spawn/refresh a wave of $count bots, rest marked dead
  (func $spawn_wave (param $count i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
        (local.set $a (call $bot_addr (local.get $i)))
        (if (i32.lt_s (local.get $i) (local.get $count))
          (then
            (f32.store offset=0 (local.get $a) (call $frand (f32.const 34.0) (f32.sub (global.get $WORLD_W) (f32.const 34.0))))
            (f32.store offset=4 (local.get $a) (call $frand (f32.const 34.0) (f32.sub (global.get $MID_Y) (f32.const 34.0))))
            (f32.store offset=8 (local.get $a) (f32.const 0.0))
            (f32.store offset=12 (local.get $a) (f32.const 0.0))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (call $frand (f32.const 1.5) (f32.const 4.0)))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (f32.store offset=32 (local.get $a) (call $frand (f32.const 34.0) (f32.sub (global.get $WORLD_W) (f32.const 34.0))))
            (f32.store offset=36 (local.get $a) (call $frand (f32.const 34.0) (f32.sub (global.get $MID_Y) (f32.const 34.0)))))
          (else
            (f32.store offset=20 (local.get $a) (f32.const 0.0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $count_alive_bots (result i32)
    (local $i i32) (local $c i32)
    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
        (if (f32.gt (f32.load offset=20 (call $bot_addr (local.get $i))) (f32.const 0.0))
          (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $c))

  ;; Wave size: 1 + level, capped at 24. Was 3 + level capped at MAX_BOTS (33),
  ;; which opened on four enemies and saturated the screen by level 30. The
  ;; gentler slope keeps the same shape — pure numbers until the cap, then the
  ;; stat ramps below take over — while giving a new player a level 1 they can
  ;; actually read. The pool is still 33 wide; only the wave is smaller.
  (func $wave_size (result i32)
    (local $n i32)
    (local.set $n (i32.add (i32.const 1) (global.get $level)))
    (if (i32.gt_s (local.get $n) (i32.const 24)) (then (local.set $n (i32.const 24))))
    (if (i32.gt_s (local.get $n) (global.get $MAX_BOTS)) (then (local.set $n (global.get $MAX_BOTS))))
    (local.get $n))

  ;; ---------------- init / input / queries ----------------

  (func $init (export "init")
    (local $i i32)
    (global.set $level (i32.const 1))
    (global.set $gameOver (i32.const 0))
    (global.set $playerCooldown (f32.const 0.0))
    (global.set $thrustOn (i32.const 0))
    (global.set $firing (i32.const 0))
    ;; a burst must not survive a restart, and a Space still held from the last
    ;; run must not count as the press that arms the next one
    (global.set $prevFiring (i32.const 1))
    (global.set $burstLeft (i32.const 0))
    (global.set $pendingFire (i32.const 0))
    (global.set $shots (i32.const 0))
    (global.set $enemyShots (i32.const 0))
    (global.set $kills (i32.const 0))
    (global.set $rocks (i32.const 0))
    (global.set $hurts (i32.const 0))
    (global.set $waves (i32.const 0))
    (global.set $rotDir (f32.const 0.0))
    (global.set $astTimer (f32.const 2.5))

    (f32.store offset=0 (i32.const 0) (f32.const 600.0))
    (f32.store offset=4 (i32.const 0) (f32.const 640.0))
    (f32.store offset=8 (i32.const 0) (f32.const 0.0))
    (f32.store offset=12 (i32.const 0) (f32.const 0.0))
    (f32.store offset=16 (i32.const 0) (f32.const -1.5708))
    (f32.store offset=20 (i32.const 0) (f32.const 1.0))

    (f32.store (global.get $SCORE_OFF) (f32.const 0.0))
    (f32.store (global.get $LIVES_OFF) (f32.const 5.0))   ;; was 3.0

    (call $spawn_wave (call $wave_size))

    (local.set $i (i32.const 0))
    (block $db
      (loop $lb
        (br_if $db (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
        (f32.store offset=20 (call $bullet_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lb)))
    (local.set $i (i32.const 0))
    (block $da
      (loop $la
        (br_if $da (i32.ge_s (local.get $i) (global.get $MAX_AST)))
        (f32.store offset=20 (call $ast_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $la))))

  (func $set_input (export "set_input") (param $rot f32) (param $thrust i32) (param $fire i32)
    (global.set $rotDir (local.get $rot))
    (global.set $thrustOn (local.get $thrust))
    (global.set $firing (local.get $fire)))

  (func $get_score (export "get_score") (result f32) (f32.load (global.get $SCORE_OFF)))
  (func $get_lives (export "get_lives") (result f32) (f32.load (global.get $LIVES_OFF)))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $bots_alive_count (export "bots_alive_count") (result i32) (call $count_alive_bots))
  (func $get_shots (export "get_shots") (result i32) (global.get $shots))
  (func $get_enemy_shots (export "get_enemy_shots") (result i32) (global.get $enemyShots))
  (func $get_kills (export "get_kills") (result i32) (global.get $kills))
  (func $get_rocks (export "get_rocks") (result i32) (global.get $rocks))
  (func $get_hurts (export "get_hurts") (result i32) (global.get $hurts))
  (func $get_waves (export "get_waves") (result i32) (global.get $waves))

  ;; ---------------- main step ----------------

  (func $step (export "step") (param $dt f32)
    (local $px f32) (local $py f32) (local $pvx f32) (local $pvy f32) (local $phead f32) (local $palive f32)
    (local $speed f32) (local $ax f32) (local $ay f32)
    (local $i i32) (local $a i32) (local $b i32)
    (local $bx f32) (local $by f32) (local $bvx f32) (local $bvy f32) (local $balive f32)
    (local $bcd f32) (local $bwt f32) (local $btx f32) (local $bty f32)
    (local $dx f32) (local $dy f32) (local $dist f32)
    (local $steerX f32) (local $steerY f32)
    (local $ox f32) (local $oy f32) (local $ovx f32) (local $ovy f32) (local $owner f32) (local $active f32)
    (local $hit i32)
    (local $score f32) (local $lives f32)
    (local $cdMin f32) (local $cdMax f32) (local $botSpeed f32)
    (local $astR f32) (local $j i32)
    (local $astIntMin f32) (local $astIntMax f32)
    (local $ramp f32)

    (if (global.get $gameOver) (then (return)))

    ;; ===== player =====
    (local.set $px (f32.load offset=0 (i32.const 0)))
    (local.set $py (f32.load offset=4 (i32.const 0)))
    (local.set $pvx (f32.load offset=8 (i32.const 0)))
    (local.set $pvy (f32.load offset=12 (i32.const 0)))
    (local.set $phead (f32.load offset=16 (i32.const 0)))
    (local.set $palive (f32.load offset=20 (i32.const 0)))

    (local.set $phead (f32.add (local.get $phead) (f32.mul (global.get $rotDir) (f32.mul (global.get $ROT_SPEED) (local.get $dt)))))

    (if (i32.ne (global.get $thrustOn) (i32.const 0))
      (then
        (local.set $ax (f32.mul (call $cosf (local.get $phead)) (global.get $ACCEL)))
        (local.set $ay (f32.mul (call $sinf (local.get $phead)) (global.get $ACCEL)))
        (local.set $pvx (f32.add (local.get $pvx) (f32.mul (local.get $ax) (local.get $dt))))
        (local.set $pvy (f32.add (local.get $pvy) (f32.mul (local.get $ay) (local.get $dt))))))

    (local.set $pvx (f32.mul (local.get $pvx) (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))))
    (local.set $pvy (f32.mul (local.get $pvy) (f32.sub (f32.const 1.0) (f32.mul (global.get $DRAG) (local.get $dt)))))

    (local.set $speed (f32.sqrt (f32.add (f32.mul (local.get $pvx) (local.get $pvx)) (f32.mul (local.get $pvy) (local.get $pvy)))))
    (if (f32.gt (local.get $speed) (global.get $MAX_SPEED))
      (then
        (local.set $pvx (f32.mul (f32.div (local.get $pvx) (local.get $speed)) (global.get $MAX_SPEED)))
        (local.set $pvy (f32.mul (f32.div (local.get $pvy) (local.get $speed)) (global.get $MAX_SPEED)))))

    (local.set $px (call $clampf (f32.add (local.get $px) (f32.mul (local.get $pvx) (local.get $dt))) (f32.const 20.0) (f32.sub (global.get $WORLD_W) (f32.const 20.0))))
    (local.set $py (call $clampf (f32.add (local.get $py) (f32.mul (local.get $pvy) (local.get $dt))) (f32.const 20.0) (f32.sub (global.get $WORLD_H) (f32.const 20.0))))

    (global.set $playerCooldown (f32.sub (global.get $playerCooldown) (local.get $dt)))

    ;; A fresh press (0 -> 1) requests a burst; holding does nothing further.
    (if (i32.and (i32.ne (global.get $firing) (i32.const 0))
                 (i32.eq (global.get $prevFiring) (i32.const 0)))
      (then (global.set $pendingFire (i32.const 1))))
    (global.set $prevFiring (global.get $firing))

    ;; Granted only once the previous burst has fired out and its recovery has
    ;; elapsed, and held rather than discarded until then: dropping a press that
    ;; arrives mid-burst cost anyone tapping at ~2 Hz half their inputs, which
    ;; reads as the key not working.
    (if (i32.and (i32.ne (global.get $pendingFire) (i32.const 0))
                 (i32.and (i32.eq (global.get $burstLeft) (i32.const 0))
                          (f32.le (global.get $playerCooldown) (f32.const 0.0))))
      (then
        (global.set $burstLeft (global.get $BURST_SIZE))
        (global.set $pendingFire (i32.const 0))))

    ;; the armed burst then fires itself out, one round per $BURST_GAP
    (if (i32.and (i32.gt_s (global.get $burstLeft) (i32.const 0))
                 (f32.le (global.get $playerCooldown) (f32.const 0.0)))
      (then
        (call $spawn_bullet (i32.const 0) (local.get $px) (local.get $py)
          (f32.mul (call $cosf (local.get $phead)) (global.get $PLAYER_BULLET_SPEED))
          (f32.mul (call $sinf (local.get $phead)) (global.get $PLAYER_BULLET_SPEED)))
        (global.set $shots (i32.add (global.get $shots) (i32.const 1)))
        (global.set $burstLeft (i32.sub (global.get $burstLeft) (i32.const 1)))
        ;; the last round of a burst pays the recovery, so mashing the key
        ;; cannot beat the fire rate the weapon is meant to have
        (global.set $playerCooldown
          (if (result f32) (i32.gt_s (global.get $burstLeft) (i32.const 0))
            (then (global.get $BURST_GAP))
            (else (global.get $BURST_RECOVER))))))

    (f32.store offset=0 (i32.const 0) (local.get $px))
    (f32.store offset=4 (i32.const 0) (local.get $py))
    (f32.store offset=8 (i32.const 0) (local.get $pvx))
    (f32.store offset=12 (i32.const 0) (local.get $pvy))
    (f32.store offset=16 (i32.const 0) (local.get $phead))

    ;; ===== difficulty: flat until level 30, then stat ramps =====
    (local.set $ramp (call $ramp_f))
    ;; ramp softened: +5/level was +8, and the fire-rate floors were 0.5/1.2 —
    ;; low enough that a level-60 swarm fired almost continuously
    (local.set $botSpeed (f32.add (global.get $BOT_SPEED_BASE) (f32.mul (local.get $ramp) (f32.const 5.0))))
    (if (f32.gt (local.get $botSpeed) (f32.const 190.0)) (then (local.set $botSpeed (f32.const 190.0))))   ;; was 230
    (local.set $cdMin (f32.sub (f32.const 4.2) (f32.mul (local.get $ramp) (f32.const 0.2))))               ;; was 3.0
    (if (f32.lt (local.get $cdMin) (f32.const 1.2)) (then (local.set $cdMin (f32.const 1.2))))
    (local.set $cdMax (f32.sub (f32.const 7.0) (f32.mul (local.get $ramp) (f32.const 0.28))))              ;; was 5.5
    (if (f32.lt (local.get $cdMax) (f32.const 2.0)) (then (local.set $cdMax (f32.const 2.0))))

    ;; ===== bots: random wander + occasional aimed fire =====
    (local.set $i (i32.const 0))
    (block $donebots
      (loop $lp
        (br_if $donebots (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
        (local.set $a (call $bot_addr (local.get $i)))
        (local.set $balive (f32.load offset=20 (local.get $a)))
        (if (f32.gt (local.get $balive) (f32.const 0.0))
          (then
            (local.set $bx (f32.load offset=0 (local.get $a)))
            (local.set $by (f32.load offset=4 (local.get $a)))
            (local.set $bvx (f32.load offset=8 (local.get $a)))
            (local.set $bvy (f32.load offset=12 (local.get $a)))
            (local.set $bcd (f32.load offset=24 (local.get $a)))
            (local.set $bwt (f32.load offset=28 (local.get $a)))
            (local.set $btx (f32.load offset=32 (local.get $a)))
            (local.set $bty (f32.load offset=36 (local.get $a)))

            (local.set $bwt (f32.sub (local.get $bwt) (local.get $dt)))
            (local.set $dx (f32.sub (local.get $btx) (local.get $bx)))
            (local.set $dy (f32.sub (local.get $bty) (local.get $by)))
            (local.set $dist (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))))
            (if (i32.or (f32.le (local.get $bwt) (f32.const 0.0)) (f32.lt (local.get $dist) (f32.const 16.0)))
              (then
                (local.set $btx (call $frand (f32.const 34.0) (f32.sub (global.get $WORLD_W) (f32.const 34.0))))
                (local.set $bty (call $frand (f32.const 34.0) (f32.sub (global.get $MID_Y) (f32.const 34.0))))
                (local.set $bwt (call $frand (f32.const 1.2) (f32.const 3.2)))
                (local.set $dx (f32.sub (local.get $btx) (local.get $bx)))
                (local.set $dy (f32.sub (local.get $bty) (local.get $by)))
                (local.set $dist (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))))))

            (local.set $steerX (f32.const 0.0))
            (local.set $steerY (f32.const 0.0))
            (if (f32.gt (local.get $dist) (f32.const 0.5))
              (then
                (local.set $steerX (f32.div (local.get $dx) (local.get $dist)))
                (local.set $steerY (f32.div (local.get $dy) (local.get $dist)))))

            (local.set $bvx (f32.add (local.get $bvx) (f32.mul (f32.sub (f32.mul (local.get $steerX) (local.get $botSpeed)) (local.get $bvx)) (f32.mul (local.get $dt) (f32.const 2.5)))))
            (local.set $bvy (f32.add (local.get $bvy) (f32.mul (f32.sub (f32.mul (local.get $steerY) (local.get $botSpeed)) (local.get $bvy)) (f32.mul (local.get $dt) (f32.const 2.5)))))

            (local.set $bx (call $clampf (f32.add (local.get $bx) (f32.mul (local.get $bvx) (local.get $dt))) (f32.const 18.0) (f32.sub (global.get $WORLD_W) (f32.const 18.0))))
            (local.set $by (call $clampf (f32.add (local.get $by) (f32.mul (local.get $bvy) (local.get $dt))) (f32.const 18.0) (f32.sub (global.get $MID_Y) (f32.const 18.0))))

            (local.set $bcd (f32.sub (local.get $bcd) (local.get $dt)))
            (if (f32.le (local.get $bcd) (f32.const 0.0))
              (then
                (local.set $dx (f32.sub (local.get $px) (local.get $bx)))
                (local.set $dy (f32.sub (local.get $py) (local.get $by)))
                (local.set $dist (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))))
                (if (f32.gt (local.get $dist) (f32.const 0.001))
                  (then
                    (call $spawn_bullet (i32.const 1) (local.get $bx) (local.get $by)
                      (f32.mul (f32.div (local.get $dx) (local.get $dist)) (f32.const 280.0))
                      (f32.mul (f32.div (local.get $dy) (local.get $dist)) (f32.const 280.0)))
                    (global.set $enemyShots (i32.add (global.get $enemyShots) (i32.const 1)))))
                (local.set $bcd (call $frand (local.get $cdMin) (local.get $cdMax)))))

            (f32.store offset=0 (local.get $a) (local.get $bx))
            (f32.store offset=4 (local.get $a) (local.get $by))
            (f32.store offset=8 (local.get $a) (local.get $bvx))
            (f32.store offset=12 (local.get $a) (local.get $bvy))
            (f32.store offset=24 (local.get $a) (local.get $bcd))
            (f32.store offset=28 (local.get $a) (local.get $bwt))
            (f32.store offset=32 (local.get $a) (local.get $btx))
            (f32.store offset=36 (local.get $a) (local.get $bty))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    ;; ===== asteroids: spawn timer (flat until 30, faster after) =====
    ;; asteroids arrive less often, was 3.0–5.0 with floors of 0.7/1.4
    (local.set $astIntMin (f32.sub (f32.const 4.5) (f32.mul (local.get $ramp) (f32.const 0.18))))
    (if (f32.lt (local.get $astIntMin) (f32.const 1.5)) (then (local.set $astIntMin (f32.const 1.5))))
    (local.set $astIntMax (f32.sub (f32.const 7.0) (f32.mul (local.get $ramp) (f32.const 0.24))))
    (if (f32.lt (local.get $astIntMax) (f32.const 2.5)) (then (local.set $astIntMax (f32.const 2.5))))

    (global.set $astTimer (f32.sub (global.get $astTimer) (local.get $dt)))
    (if (f32.le (global.get $astTimer) (f32.const 0.0))
      (then
        (call $spawn_asteroid)
        (global.set $astTimer (call $frand (local.get $astIntMin) (local.get $astIntMax)))))

    ;; ===== score/lives locals =====
    (local.set $score (f32.load (global.get $SCORE_OFF)))
    (local.set $lives (f32.load (global.get $LIVES_OFF)))
    (local.set $palive (f32.load offset=20 (i32.const 0)))
    (local.set $px (f32.load offset=0 (i32.const 0)))
    (local.set $py (f32.load offset=4 (i32.const 0)))

    ;; ===== bullets update + collisions =====
    (local.set $j (i32.const 0))
    (block $donebul
      (loop $lpb
        (br_if $donebul (i32.ge_s (local.get $j) (global.get $MAX_BULLETS)))
        (local.set $b (call $bullet_addr (local.get $j)))
        (local.set $active (f32.load offset=20 (local.get $b)))
        (if (f32.gt (local.get $active) (f32.const 0.0))
          (then
            (local.set $ox (f32.load offset=0 (local.get $b)))
            (local.set $oy (f32.load offset=4 (local.get $b)))
            (local.set $ovx (f32.load offset=8 (local.get $b)))
            (local.set $ovy (f32.load offset=12 (local.get $b)))
            (local.set $owner (f32.load offset=16 (local.get $b)))
            (local.set $ox (f32.add (local.get $ox) (f32.mul (local.get $ovx) (local.get $dt))))
            (local.set $oy (f32.add (local.get $oy) (f32.mul (local.get $ovy) (local.get $dt))))

            (if (i32.or (i32.or (f32.lt (local.get $ox) (f32.const -24.0)) (f32.gt (local.get $ox) (f32.add (global.get $WORLD_W) (f32.const 24.0))))
                        (i32.or (f32.lt (local.get $oy) (f32.const -24.0)) (f32.gt (local.get $oy) (f32.add (global.get $WORLD_H) (f32.const 24.0)))))
              (then (local.set $active (f32.const 0.0)))
              (else
                (local.set $hit (i32.const 0))
                (if (f32.eq (local.get $owner) (f32.const 0.0))
                  (then
                    ;; player bullet vs bots
                    (local.set $i (i32.const 0))
                    (block $donechk
                      (loop $lpchk
                        (br_if $donechk (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
                        (local.set $a (call $bot_addr (local.get $i)))
                        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                          (then
                            (local.set $dx (f32.sub (local.get $ox) (f32.load offset=0 (local.get $a))))
                            (local.set $dy (f32.sub (local.get $oy) (f32.load offset=4 (local.get $a))))
                            (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                                        (f32.mul (global.get $BULLET_HIT_R) (global.get $BULLET_HIT_R)))
                              (then
                                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                                (local.set $score (f32.add (local.get $score) (f32.const 1.0)))
                                (local.set $hit (i32.const 1))
                                (global.set $kills (i32.add (global.get $kills) (i32.const 1)))
                                (br $donechk)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $lpchk)))
                    ;; player bullet vs asteroids
                    (if (i32.eqz (local.get $hit))
                      (then
                        (local.set $i (i32.const 0))
                        (block $donechk2
                          (loop $lpchk2
                            (br_if $donechk2 (i32.ge_s (local.get $i) (global.get $MAX_AST)))
                            (local.set $a (call $ast_addr (local.get $i)))
                            (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                              (then
                                (local.set $astR (f32.load offset=16 (local.get $a)))
                                (local.set $dx (f32.sub (local.get $ox) (f32.load offset=0 (local.get $a))))
                                (local.set $dy (f32.sub (local.get $oy) (f32.load offset=4 (local.get $a))))
                                (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                                            (f32.mul (f32.add (local.get $astR) (f32.const 4.0)) (f32.add (local.get $astR) (f32.const 4.0))))
                                  (then
                                    (f32.store offset=20 (local.get $a) (f32.const 0.0))
                                    (local.set $score (f32.add (local.get $score) (f32.const 1.0)))
                                    (local.set $hit (i32.const 1))
                                    (global.set $rocks (i32.add (global.get $rocks) (i32.const 1)))
                                    (br $donechk2)))))
                            (local.set $i (i32.add (local.get $i) (i32.const 1)))
                            (br $lpchk2))))))
                  (else
                    ;; bot bullet vs player
                    (if (f32.gt (local.get $palive) (f32.const 0.0))
                      (then
                        (local.set $dx (f32.sub (local.get $ox) (local.get $px)))
                        (local.set $dy (f32.sub (local.get $oy) (local.get $py)))
                        (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                                    (f32.mul (global.get $BULLET_HIT_R) (global.get $BULLET_HIT_R)))
                          (then
                            (local.set $hit (i32.const 1))
                            (local.set $lives (f32.sub (local.get $lives) (f32.const 1.0)))
                (global.set $hurts (i32.add (global.get $hurts) (i32.const 1)))
                            (if (f32.le (local.get $lives) (f32.const 0.0))
                              (then
                                (local.set $palive (f32.const 0.0))
                                (global.set $gameOver (i32.const 1))))))))))
                (if (i32.ne (local.get $hit) (i32.const 0)) (then (local.set $active (f32.const 0.0))))))

            (f32.store offset=0 (local.get $b) (local.get $ox))
            (f32.store offset=4 (local.get $b) (local.get $oy))
            (f32.store offset=20 (local.get $b) (local.get $active))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $lpb)))

    ;; ===== asteroids: move + collide vs player =====
    (local.set $j (i32.const 0))
    (block $doneast
      (loop $lpa
        (br_if $doneast (i32.ge_s (local.get $j) (global.get $MAX_AST)))
        (local.set $a (call $ast_addr (local.get $j)))
        (local.set $active (f32.load offset=20 (local.get $a)))
        (if (f32.gt (local.get $active) (f32.const 0.0))
          (then
            (local.set $ox (f32.load offset=0 (local.get $a)))
            (local.set $oy (f32.load offset=4 (local.get $a)))
            (local.set $ovx (f32.load offset=8 (local.get $a)))
            (local.set $ovy (f32.load offset=12 (local.get $a)))
            (local.set $astR (f32.load offset=16 (local.get $a)))
            (local.set $ox (f32.add (local.get $ox) (f32.mul (local.get $ovx) (local.get $dt))))
            (local.set $oy (f32.add (local.get $oy) (f32.mul (local.get $ovy) (local.get $dt))))

            (if (f32.gt (local.get $oy) (f32.add (global.get $WORLD_H) (f32.const 44.0)))
              (then (local.set $active (f32.const 0.0)))
              (else
                (if (f32.gt (local.get $palive) (f32.const 0.0))
                  (then
                    (local.set $dx (f32.sub (local.get $ox) (local.get $px)))
                    (local.set $dy (f32.sub (local.get $oy) (local.get $py)))
                    (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                                (f32.mul (f32.add (local.get $astR) (global.get $SHIP_R)) (f32.add (local.get $astR) (global.get $SHIP_R))))
                      (then
                        (local.set $active (f32.const 0.0))
                        (local.set $lives (f32.sub (local.get $lives) (f32.const 1.0)))
                (global.set $hurts (i32.add (global.get $hurts) (i32.const 1)))
                        (if (f32.le (local.get $lives) (f32.const 0.0))
                          (then
                            (local.set $palive (f32.const 0.0))
                            (global.set $gameOver (i32.const 1))))))))))
            (f32.store offset=0 (local.get $a) (local.get $ox))
            (f32.store offset=4 (local.get $a) (local.get $oy))
            (f32.store offset=20 (local.get $a) (local.get $active))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $lpa)))

    ;; ===== ramming: player body vs bot body =====
    ;; Only reachable since the player lost its half-arena wall: before that the
    ;; two could never occupy the same space, so no such check existed. Both die
    ;; on contact — the bot is cleared so a single collision cannot bill the
    ;; player for several lives while the ships are still overlapping (nothing
    ;; respawns or blinks the player after a hit). No score: the life paid for it.
    (local.set $i (i32.const 0))
    (block $doneram
      (loop $lpram
        (br_if $doneram (f32.le (local.get $palive) (f32.const 0.0)))
        (br_if $doneram (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
        (local.set $a (call $bot_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $dx (f32.sub (local.get $px) (f32.load offset=0 (local.get $a))))
            (local.set $dy (f32.sub (local.get $py) (f32.load offset=4 (local.get $a))))
            (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                        (f32.mul (f32.add (global.get $SHIP_R) (global.get $BOT_R)) (f32.add (global.get $SHIP_R) (global.get $BOT_R))))
              (then
                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                (local.set $lives (f32.sub (local.get $lives) (f32.const 1.0)))
                (global.set $hurts (i32.add (global.get $hurts) (i32.const 1)))
                (if (f32.le (local.get $lives) (f32.const 0.0))
                  (then
                    (local.set $palive (f32.const 0.0))
                    (global.set $gameOver (i32.const 1))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lpram)))

    (f32.store offset=20 (i32.const 0) (local.get $palive))
    (f32.store (global.get $SCORE_OFF) (local.get $score))
    (f32.store (global.get $LIVES_OFF) (local.get $lives))

    ;; ===== level up when wave cleared =====
    (if (i32.and (i32.eqz (global.get $gameOver)) (i32.eqz (call $count_alive_bots)))
      (then
        (global.set $level (i32.add (global.get $level) (i32.const 1)))
        (global.set $waves (i32.add (global.get $waves) (i32.const 1)))
        (call $spawn_wave (call $wave_size))))
    )
)
