(module
  ;; ---- imports (trig from host, everything else is pure wasm) ----
  (import "env" "sinf" (func $sinf (param f32) (result f32)))
  (import "env" "cosf" (func $cosf (param f32) (result f32)))

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; player   @0    : x,y,vx,vy,heading,alive        (6 f32 = 24 bytes)
  ;; bots     @24   : stride 32 bytes each, MAX_BOTS=8
  ;;            fields: x,y,vx,vy,heading,alive,cooldown,strafeDir
  ;; bullets  @280  : stride 24 bytes each, MAX_BULLETS=80
  ;;            fields: x,y,vx,vy,owner(0=player,1=bot),active
  ;; score    @2200 (f32)
  ;; lives    @2204 (f32)
  ;; ===================================================

  (global $MAX_BOTS i32 (i32.const 8))
  (global $MAX_BULLETS i32 (i32.const 80))
  (global $BOTS_OFF i32 (i32.const 24))
  (global $BOT_STRIDE i32 (i32.const 32))
  (global $BULLETS_OFF i32 (i32.const 280))
  (global $BULLET_STRIDE i32 (i32.const 24))
  (global $SCORE_OFF i32 (i32.const 2200))
  (global $LIVES_OFF i32 (i32.const 2204))

  (global $WORLD_W f32 (f32.const 900.0))
  (global $WORLD_H f32 (f32.const 600.0))
  (global $PI f32 (f32.const 3.14159265))

  ;; Turn rate, applied directly as radians/sec (heading += rotDir * this * dt).
  ;; Was 4.0 — 229°/sec, a full spin in 1.6s, so a tap of A or D overshot every
  ;; time. 2.8 is ~160°/sec (full turn 2.2s): calm enough to aim with, but these
  ;; bots orbit and strafe, and dropping to 2.4 left too little turn authority to
  ;; keep the nose on one at all. This is the knob to touch if it still feels
  ;; twitchy — nothing else depends on it.
  (global $ROT_SPEED f32 (f32.const 2.8))
  (global $ACCEL f32 (f32.const 380.0))
  (global $DRAG f32 (f32.const 0.6))
  (global $MAX_SPEED f32 (f32.const 260.0))
  ;; ---- difficulty tuning, 2026-08 ----------------------------------------
  ;; Six bots that orbit, lead their shots and dodge yours killed a competent
  ;; player in seconds; on a portfolio page that reads as broken rather than
  ;; hard. Original values are noted per line, and the untouched engine is still
  ;; embedded in standalone.html if the old balance is ever wanted back.
  (global $PLAYER_BULLET_SPEED f32 (f32.const 520.0))
  (global $PLAYER_FIRE_CD f32 (f32.const 0.15))       ;; was 0.22 — more of your shots in the air
  (global $BOT_MAX_SPEED f32 (f32.const 145.0))       ;; was 165 — you can now outrun them
  (global $BOT_BULLET_SPEED f32 (f32.const 240.0))    ;; was 300 — leaves time to dodge
  (global $ORBIT f32 (f32.const 280.0))               ;; was 220 — they hang further back
  (global $FIRE_RANGE f32 (f32.const 360.0))          ;; was 480 — no more sniping from across the arena
  (global $HIT_RADIUS f32 (f32.const 16.0))
  (global $DODGE_RADIUS f32 (f32.const 48.0))

  (global $rng (mut i32) (i32.const 88172645))
  (global $numBots (mut i32) (i32.const 0))
  (global $rotDir (mut f32) (f32.const 0.0))
  (global $thrustOn (mut i32) (i32.const 0))
  (global $firing (mut i32) (i32.const 0))
  (global $playerCooldown (mut f32) (f32.const 0.0))
  (global $gameOver (mut i32) (i32.const 0))

  ;; ---- burst fire ---------------------------------------------------------
  ;; Holding Space used to stream bullets for as long as it was down, which made
  ;; the weapon a hose and every fight a matter of pointing. One press now buys
  ;; exactly $BURST_SIZE rounds, spaced by $BURST_GAP, and the next burst needs a
  ;; fresh press: $prevFiring holds last frame's input so the engine can see the
  ;; edge, since set_input only ever reports the held state.
  (global $BURST_SIZE i32 (i32.const 3))
  (global $BURST_GAP f32 (f32.const 0.09))
  ;; Recovery after the third round. Without it a player mashing Space beats the
  ;; old hold-to-fire rate (9.1 rounds/sec against 6.7), which would make burst
  ;; fire a buff rather than the trade it is meant to be. 0.35 puts a mashed
  ;; cycle at ~5.7 rounds/sec: aiming a burst is worth more than spamming one.
  (global $BURST_RECOVER f32 (f32.const 0.35))
  (global $prevFiring (mut i32) (i32.const 0))
  (global $burstLeft (mut i32) (i32.const 0))
  (global $pendingFire (mut i32) (i32.const 0))

  ;; ---------------- helpers ----------------

  (func $bot_addr (param $i i32) (result i32)
    (i32.add (global.get $BOTS_OFF) (i32.mul (local.get $i) (global.get $BOT_STRIDE))))

  (func $bullet_addr (param $i i32) (result i32)
    (i32.add (global.get $BULLETS_OFF) (i32.mul (local.get $i) (global.get $BULLET_STRIDE))))

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

  (func $wrap (param $v f32) (param $max f32) (result f32)
    (local $r f32)
    (local.set $r (local.get $v))
    (if (f32.lt (local.get $r) (f32.const 0.0)) (then (local.set $r (f32.add (local.get $r) (local.get $max)))))
    (if (f32.gt (local.get $r) (local.get $max)) (then (local.set $r (f32.sub (local.get $r) (local.get $max)))))
    (local.get $r))

  ;; find a free bullet slot and fill it
  (func $spawn_bullet (param $owner i32) (param $x f32) (param $y f32) (param $vx f32) (param $vy f32)
    (local $i i32)
    (local $a i32)
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
        (br $lp)))
    )

  ;; ---------------- init ----------------

  (func $init (export "init") (param $n i32)
    (local $i i32)
    (local $a i32)
    (local $ang f32)
    (local $rad f32)

    (global.set $numBots (local.get $n))
    (if (i32.gt_s (global.get $numBots) (global.get $MAX_BOTS))
      (then (global.set $numBots (global.get $MAX_BOTS))))

    (global.set $gameOver (i32.const 0))
    (global.set $playerCooldown (f32.const 0.0))
    (global.set $thrustOn (i32.const 0))
    (global.set $firing (i32.const 0))
    ;; a burst must not survive a restart, and a Space still held from the last
    ;; run must not count as the press that arms the next one
    (global.set $prevFiring (i32.const 1))
    (global.set $burstLeft (i32.const 0))
    (global.set $pendingFire (i32.const 0))
    (global.set $rotDir (f32.const 0.0))

    ;; player
    (f32.store offset=0 (i32.const 0) (f32.const 450.0))
    (f32.store offset=4 (i32.const 0) (f32.const 300.0))
    (f32.store offset=8 (i32.const 0) (f32.const 0.0))
    (f32.store offset=12 (i32.const 0) (f32.const 0.0))
    (f32.store offset=16 (i32.const 0) (f32.const -1.5708))
    (f32.store offset=20 (i32.const 0) (f32.const 1.0))

    (f32.store (global.get $SCORE_OFF) (f32.const 0.0))
    (f32.store (global.get $LIVES_OFF) (f32.const 5.0))   ;; was 3.0

    ;; bots
    (local.set $i (i32.const 0))
    (block $donebots
      (loop $lp
        (br_if $donebots (i32.ge_s (local.get $i) (global.get $MAX_BOTS)))
        (local.set $a (call $bot_addr (local.get $i)))
        (if (i32.lt_s (local.get $i) (global.get $numBots))
          (then
            (local.set $ang (call $frand (f32.const 0.0) (f32.mul (global.get $PI) (f32.const 2.0))))
            (local.set $rad (call $frand (f32.const 260.0) (f32.const 400.0)))
            (f32.store offset=0 (local.get $a) (f32.add (f32.const 450.0) (f32.mul (call $cosf (local.get $ang)) (local.get $rad))))
            (f32.store offset=4 (local.get $a) (f32.add (f32.const 300.0) (f32.mul (call $sinf (local.get $ang)) (local.get $rad))))
            (f32.store offset=8 (local.get $a) (f32.const 0.0))
            (f32.store offset=12 (local.get $a) (f32.const 0.0))
            (f32.store offset=16 (local.get $a) (f32.const 0.0))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            ;; opening cooldown, was 0.3–1.5: a wave no longer opens fire the
            ;; instant it spawns, which is what made the first seconds lethal
            (f32.store offset=24 (local.get $a) (call $frand (f32.const 1.2) (f32.const 2.6)))
            (f32.store offset=28 (local.get $a) (if (result f32) (f32.lt (call $rand_f32) (f32.const 0.5)) (then (f32.const -1.0)) (else (f32.const 1.0)))))
          (else
            (f32.store offset=20 (local.get $a) (f32.const 0.0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    ;; bullets
    (local.set $i (i32.const 0))
    (block $donebul
      (loop $lp
        (br_if $donebul (i32.ge_s (local.get $i) (global.get $MAX_BULLETS)))
        (f32.store offset=20 (call $bullet_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    )

  ;; ---------------- input ----------------

  (func $set_input (export "set_input") (param $rot f32) (param $thrust i32) (param $fire i32)
    (global.set $rotDir (local.get $rot))
    (global.set $thrustOn (local.get $thrust))
    (global.set $firing (local.get $fire)))

  ;; ---------------- queries ----------------

  (func $get_score (export "get_score") (result f32) (f32.load (global.get $SCORE_OFF)))
  (func $get_lives (export "get_lives") (result f32) (f32.load (global.get $LIVES_OFF)))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $bots_alive_count (export "bots_alive_count") (result i32)
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

  ;; ---------------- main step ----------------

  (func $step (export "step") (param $dt f32)
    (local $px f32) (local $py f32) (local $pvx f32) (local $pvy f32) (local $phead f32) (local $palive f32)
    (local $speed f32) (local $ax f32) (local $ay f32)
    (local $i i32) (local $j i32) (local $a i32) (local $b i32)
    (local $bx f32) (local $by f32) (local $bvx f32) (local $bvy f32) (local $bhead f32) (local $balive f32) (local $bcd f32) (local $bstrafe f32)
    (local $dx f32) (local $dy f32) (local $dist f32) (local $nx f32) (local $ny f32)
    (local $steerX f32) (local $steerY f32)
    (local $farF f32) (local $nearF f32) (local $midF f32)
    (local $relx f32) (local $rely f32) (local $rbvx f32) (local $rbvy f32) (local $denom f32) (local $t f32) (local $cx f32) (local $cy f32) (local $cdist f32)
    (local $slen f32) (local $tx f32) (local $ty f32)
    (local $leadT f32) (local $ppx f32) (local $ppy f32) (local $ddx f32) (local $ddy f32) (local $dd f32)
    (local $ox f32) (local $oy f32) (local $ovx f32) (local $ovy f32) (local $owner f32) (local $active f32)
    (local $hit i32)
    (local $score f32) (local $lives f32)

    (if (global.get $gameOver) (then (return)))

    ;; ===== player =====
    (local.set $px (f32.load offset=0 (i32.const 0)))
    (local.set $py (f32.load offset=4 (i32.const 0)))
    (local.set $pvx (f32.load offset=8 (i32.const 0)))
    (local.set $pvy (f32.load offset=12 (i32.const 0)))
    (local.set $phead (f32.load offset=16 (i32.const 0)))

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

    (local.set $px (call $wrap (f32.add (local.get $px) (f32.mul (local.get $pvx) (local.get $dt))) (global.get $WORLD_W)))
    (local.set $py (call $wrap (f32.add (local.get $py) (f32.mul (local.get $pvy) (local.get $dt))) (global.get $WORLD_H)))

    (global.set $playerCooldown (f32.sub (global.get $playerCooldown) (local.get $dt)))

    ;; A fresh press (0 -> 1) requests a burst; holding does nothing further.
    (if (i32.and (i32.ne (global.get $firing) (i32.const 0))
                 (i32.eq (global.get $prevFiring) (i32.const 0)))
      (then (global.set $pendingFire (i32.const 1))))
    (global.set $prevFiring (global.get $firing))

    ;; The request is granted only once the previous burst has fired out and its
    ;; recovery has elapsed — otherwise mashing Space re-arms the counter
    ;; mid-burst, the recovery is never paid, and the weapon is a hose again with
    ;; extra steps. It is held rather than discarded: dropping presses that land
    ;; during recovery loses half the inputs of anyone tapping at ~2Hz, which
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

    ;; ===== bots =====
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
            (local.set $bstrafe (f32.load offset=28 (local.get $a)))

            (local.set $steerX (f32.const 0.0))
            (local.set $steerY (f32.const 0.0))

            (local.set $dx (f32.sub (local.get $px) (local.get $bx)))
            (local.set $dy (f32.sub (local.get $py) (local.get $by)))
            (local.set $dist (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))))

            (if (f32.gt (local.get $dist) (f32.const 1.0))
              (then
                (local.set $nx (f32.div (local.get $dx) (local.get $dist)))
                (local.set $ny (f32.div (local.get $dy) (local.get $dist)))
                (local.set $farF (f32.convert_i32_u (f32.gt (local.get $dist) (f32.add (global.get $ORBIT) (f32.const 40.0)))))
                (local.set $nearF (f32.convert_i32_u (f32.lt (local.get $dist) (f32.sub (global.get $ORBIT) (f32.const 40.0)))))
                (local.set $midF (f32.sub (f32.sub (f32.const 1.0) (local.get $farF)) (local.get $nearF)))
                (local.set $steerX (f32.add (local.get $steerX)
                  (f32.add (f32.mul (local.get $nx) (f32.sub (local.get $farF) (local.get $nearF)))
                           (f32.mul (f32.mul (f32.neg (local.get $ny)) (local.get $bstrafe)) (local.get $midF)))))
                (local.set $steerY (f32.add (local.get $steerY)
                  (f32.add (f32.mul (local.get $ny) (f32.sub (local.get $farF) (local.get $nearF)))
                           (f32.mul (f32.mul (local.get $nx) (local.get $bstrafe)) (local.get $midF)))))))

            ;; dodge incoming player bullets
            (local.set $j (i32.const 0))
            (block $donebul2
              (loop $lp2
                (br_if $donebul2 (i32.ge_s (local.get $j) (global.get $MAX_BULLETS)))
                (local.set $b (call $bullet_addr (local.get $j)))
                (local.set $active (f32.load offset=20 (local.get $b)))
                (local.set $owner (f32.load offset=16 (local.get $b)))
                (if (i32.and (f32.gt (local.get $active) (f32.const 0.0)) (f32.eq (local.get $owner) (f32.const 0.0)))
                  (then
                    (local.set $ox (f32.load offset=0 (local.get $b)))
                    (local.set $oy (f32.load offset=4 (local.get $b)))
                    (local.set $ovx (f32.load offset=8 (local.get $b)))
                    (local.set $ovy (f32.load offset=12 (local.get $b)))
                    (local.set $relx (f32.sub (local.get $ox) (local.get $bx)))
                    (local.set $rely (f32.sub (local.get $oy) (local.get $by)))
                    (local.set $denom (f32.add (f32.mul (local.get $ovx) (local.get $ovx)) (f32.mul (local.get $ovy) (local.get $ovy))))
                    (if (f32.gt (local.get $denom) (f32.const 1.0))
                      (then
                        (local.set $t (f32.neg (f32.div (f32.add (f32.mul (local.get $relx) (local.get $ovx)) (f32.mul (local.get $rely) (local.get $ovy))) (local.get $denom))))
                        (if (f32.lt (local.get $t) (f32.const 0.0)) (then (local.set $t (f32.const 0.0))))
                        (if (f32.gt (local.get $t) (f32.const 1.2)) (then (local.set $t (f32.const 1.2))))
                        (local.set $cx (f32.add (local.get $relx) (f32.mul (local.get $ovx) (local.get $t))))
                        (local.set $cy (f32.add (local.get $rely) (f32.mul (local.get $ovy) (local.get $t))))
                        (local.set $cdist (f32.sqrt (f32.add (f32.mul (local.get $cx) (local.get $cx)) (f32.mul (local.get $cy) (local.get $cy)))))
                        (if (i32.and (f32.gt (local.get $t) (f32.const 0.0)) (f32.lt (local.get $cdist) (global.get $DODGE_RADIUS)))
                          (then
                            (if (f32.gt (local.get $cdist) (f32.const 0.001))
                              (then
                                (local.set $steerX (f32.add (local.get $steerX) (f32.mul (f32.div (local.get $cx) (local.get $cdist)) (f32.const 3.0))))
                                (local.set $steerY (f32.add (local.get $steerY) (f32.mul (f32.div (local.get $cy) (local.get $cdist)) (f32.const 3.0))))))))))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $lp2)))

            (local.set $slen (f32.sqrt (f32.add (f32.mul (local.get $steerX) (local.get $steerX)) (f32.mul (local.get $steerY) (local.get $steerY)))))
            (if (f32.gt (local.get $slen) (f32.const 0.001))
              (then
                (local.set $tx (f32.mul (f32.div (local.get $steerX) (local.get $slen)) (global.get $BOT_MAX_SPEED)))
                (local.set $ty (f32.mul (f32.div (local.get $steerY) (local.get $slen)) (global.get $BOT_MAX_SPEED))))
              (else
                (local.set $tx (f32.const 0.0))
                (local.set $ty (f32.const 0.0))))

            (local.set $bvx (f32.add (local.get $bvx) (f32.mul (f32.sub (local.get $tx) (local.get $bvx)) (f32.mul (local.get $dt) (f32.const 4.0)))))
            (local.set $bvy (f32.add (local.get $bvy) (f32.mul (f32.sub (local.get $ty) (local.get $bvy)) (f32.mul (local.get $dt) (f32.const 4.0)))))

            (local.set $bx (call $wrap (f32.add (local.get $bx) (f32.mul (local.get $bvx) (local.get $dt))) (global.get $WORLD_W)))
            (local.set $by (call $wrap (f32.add (local.get $by) (f32.mul (local.get $bvy) (local.get $dt))) (global.get $WORLD_H)))

            (local.set $bcd (f32.sub (local.get $bcd) (local.get $dt)))
            (if (i32.and (f32.le (local.get $bcd) (f32.const 0.0)) (f32.lt (local.get $dist) (global.get $FIRE_RANGE)))
              (then
                (local.set $leadT (f32.div (local.get $dist) (global.get $BOT_BULLET_SPEED)))
                (local.set $ppx (f32.add (local.get $px) (f32.mul (local.get $pvx) (local.get $leadT))))
                (local.set $ppy (f32.add (local.get $py) (f32.mul (local.get $pvy) (local.get $leadT))))
                (local.set $ddx (f32.sub (local.get $ppx) (local.get $bx)))
                (local.set $ddy (f32.sub (local.get $ppy) (local.get $by)))
                (local.set $dd (f32.sqrt (f32.add (f32.mul (local.get $ddx) (local.get $ddx)) (f32.mul (local.get $ddy) (local.get $ddy)))))
                (if (f32.gt (local.get $dd) (f32.const 0.001))
                  (then
                    (call $spawn_bullet (i32.const 1) (local.get $bx) (local.get $by)
                      (f32.mul (f32.div (local.get $ddx) (local.get $dd)) (global.get $BOT_BULLET_SPEED))
                      (f32.mul (f32.div (local.get $ddy) (local.get $dd)) (global.get $BOT_BULLET_SPEED)))))
                (local.set $bcd (call $frand (f32.const 1.6) (f32.const 3.0)))))   ;; was 0.7–1.5

            (f32.store offset=0 (local.get $a) (local.get $bx))
            (f32.store offset=4 (local.get $a) (local.get $by))
            (f32.store offset=8 (local.get $a) (local.get $bvx))
            (f32.store offset=12 (local.get $a) (local.get $bvy))
            (f32.store offset=24 (local.get $a) (local.get $bcd))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    ;; ===== bullets =====
    (local.set $score (f32.load (global.get $SCORE_OFF)))
    (local.set $lives (f32.load (global.get $LIVES_OFF)))
    (local.set $palive (f32.load offset=20 (i32.const 0)))

    (local.set $j (i32.const 0))
    (block $donebul3
      (loop $lp3
        (br_if $donebul3 (i32.ge_s (local.get $j) (global.get $MAX_BULLETS)))
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

            (if (i32.or (i32.or (f32.lt (local.get $ox) (f32.const -20.0)) (f32.gt (local.get $ox) (f32.add (global.get $WORLD_W) (f32.const 20.0))))
                        (i32.or (f32.lt (local.get $oy) (f32.const -20.0)) (f32.gt (local.get $oy) (f32.add (global.get $WORLD_H) (f32.const 20.0)))))
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
                                        (f32.mul (global.get $HIT_RADIUS) (global.get $HIT_RADIUS)))
                              (then
                                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                                (local.set $score (f32.add (local.get $score) (f32.const 1.0)))
                                (local.set $hit (i32.const 1))
                                (br $donechk)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $lpchk))))
                  (else
                    ;; bot bullet vs player
                    (if (f32.gt (local.get $palive) (f32.const 0.0))
                      (then
                        (local.set $dx (f32.sub (local.get $ox) (local.get $px)))
                        (local.set $dy (f32.sub (local.get $oy) (local.get $py)))
                        (if (f32.lt (f32.add (f32.mul (local.get $dx) (local.get $dx)) (f32.mul (local.get $dy) (local.get $dy)))
                                    (f32.mul (global.get $HIT_RADIUS) (global.get $HIT_RADIUS)))
                          (then
                            (local.set $hit (i32.const 1))
                            (local.set $lives (f32.sub (local.get $lives) (f32.const 1.0)))
                            (if (f32.le (local.get $lives) (f32.const 0.0))
                              (then
                                (local.set $palive (f32.const 0.0))
                                (global.set $gameOver (i32.const 1))))))))))
                (if (i32.ne (local.get $hit) (i32.const 0)) (then (local.set $active (f32.const 0.0))))))

            (f32.store offset=0 (local.get $b) (local.get $ox))
            (f32.store offset=4 (local.get $b) (local.get $oy))
            (f32.store offset=20 (local.get $b) (local.get $active))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $lp3)))

    (f32.store offset=20 (i32.const 0) (local.get $palive))
    (f32.store (global.get $SCORE_OFF) (local.get $score))
    (f32.store (global.get $LIVES_OFF) (local.get $lives))
    )
)
