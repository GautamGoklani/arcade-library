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
  ;;
  ;; rock sizes: 3 = boulder, 2 = chunk, 1 = pebble (a pebble does not split)
  ;; pickup kinds: 0 = gem (cargo), 1 = fuel cell
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
  (global $FUEL_MAX f32 (f32.const 100.0))
  (global $FUEL_BURN f32 (f32.const 8.5))       ;; per second of thrust
  (global $REFUEL_RATE f32 (f32.const 38.0))    ;; per second, docked
  (global $FUEL_CELL f32 (f32.const 22.0))      ;; per cell picked up
  ;; The emergency reserve. A dry tank far from the depot used to be 75 seconds
  ;; of drifting with nothing to do but wait for a rock to hit you — the
  ;; headless bench measured exactly that. This trickles the tank back up to a
  ;; sliver: about 1.6 seconds of thrust, then a five-second wait for the next
  ;; sip. Running dry is meant to be a crawl home, not a dead run.
  (global $RESERVE_RATE f32 (f32.const 3.0))
  (global $RESERVE_CAP f32 (f32.const 14.0))
  (global $CARGO_MAX f32 (f32.const 12.0))
  (global $DELIVER_EVERY f32 (f32.const 0.11))  ;; seconds per gem unloaded
  (global $DEPOT_R f32 (f32.const 52.0))

  ;; ---- field ----
  (global $ROCK_R3 f32 (f32.const 42.0))
  (global $ROCK_R2 f32 (f32.const 25.0))
  (global $ROCK_R1 f32 (f32.const 14.0))
  (global $ROCK_SPEED f32 (f32.const 26.0))
  (global $ROCK_SPEED_STEP f32 (f32.const 4.0))
  (global $SPLIT_KICK f32 (f32.const 46.0))
  (global $PICKUP_LIFE f32 (f32.const 17.0))
  (global $PICKUP_R f32 (f32.const 9.0))
  (global $GRAB_R f32 (f32.const 26.0))
  (global $RESPAWN_EVERY f32 (f32.const 3.5))   ;; seconds between field top-ups

  ;; ---- scoring ----
  (global $SCORE_SPLIT f32 (f32.const 5.0))
  (global $SCORE_PEBBLE f32 (f32.const 15.0))
  (global $SCORE_GEM f32 (f32.const 25.0))
  (global $SCORE_LEVEL f32 (f32.const 200.0))
  (global $START_LIVES f32 (f32.const 4.0))

  (global $rng (mut i32) (i32.const 1103515245))
  (global $level (mut i32) (i32.const 1))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $lives (mut f32) (f32.const 4.0))
  (global $fuel (mut f32) (f32.const 100.0))
  (global $cargo (mut f32) (f32.const 0.0))
  (global $delivered (mut i32) (i32.const 0))
  (global $quota (mut i32) (i32.const 8))

  ;; input, as reported by set_input each frame
  (global $rotIn (mut f32) (f32.const 0.0))
  (global $thrustIn (mut i32) (i32.const 0))
  (global $fireIn (mut i32) (i32.const 0))
  (global $aimOn (mut i32) (i32.const 0))
  (global $aimAng (mut f32) (f32.const 0.0))

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

  (func $add_score (param $n f32)
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
        ;; A pebble pays out. One gem always, a second often, and a fuel cell
        ;; on roughly one pebble in five — which is what keeps a stranded ship
        ;; from being a dead run.
        (call $add_score (global.get $SCORE_PEBBLE))
        (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 0))
        (if (f32.lt (call $rand_f32) (f32.const 0.55))
          (then (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 0))))
        (if (f32.lt (call $rand_f32) (f32.const 0.2))
          (then (call $spawn_pickup (local.get $x) (local.get $y) (i32.const 1))))
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
                    (br $rlp)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $blp))))

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
        (global.set $deliverAcc (f32.const 0.0))
        (return)))

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
        (global.set $drops (i32.add (global.get $drops) (i32.const 1)))
        (call $add_score (global.get $SCORE_GEM))
        (br $lp))))

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
    ;; that the splits alone fill the pool.
    (local.set $n (call $clampi (i32.add (i32.const 2) (global.get $level))
                                (i32.const 3) (i32.const 10)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (call $spawn_drifter)
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    ;; Six gems to deliver on level 1, three more each level. It is a delivery
    ;; count, not a mining count: what the level asks for is round trips.
    (global.set $quota (i32.add (i32.const 3) (i32.mul (global.get $level) (i32.const 3))))
    (global.set $delivered (i32.const 0))
    (global.set $cargo (f32.const 0.0))
    (global.set $fuel (global.get $FUEL_MAX))
    (global.set $deliverAcc (f32.const 0.0))
    (global.set $respawnAcc (f32.const 0.0))
    (call $place_ship_at_depot))

  (func $init (export "init")
    (global.set $rng (i32.const 1103515245))
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
    (call $build_level))

  (func $set_input (export "set_input")
      (param $rot f32) (param $thrust i32) (param $fire i32)
      (param $aimOn i32) (param $aimAng f32)
    (global.set $rotIn (call $clampf (local.get $rot) (f32.const -1.0) (f32.const 1.0)))
    (global.set $thrustIn (local.get $thrust))
    (global.set $fireIn (local.get $fire))
    (global.set $aimOn (local.get $aimOn))
    (global.set $aimAng (local.get $aimAng)))

  (func $step (export "step") (param $dt f32)
    (local $d f32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))

    (call $step_ship (local.get $d))
    (call $step_rocks (local.get $d))
    (call $step_bullets (local.get $d))
    (call $step_pickups (local.get $d))
    (call $collide_ship (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (call $dock (local.get $d))

    ;; Top the field up on a timer rather than only at level start. A player
    ;; who has shot everything and still owes the depot gems would otherwise be
    ;; looking at an empty screen with nothing left to do — and the drifters
    ;; are also where fuel comes from.
    (global.set $respawnAcc (f32.add (global.get $respawnAcc) (local.get $d)))
    (if (f32.ge (global.get $respawnAcc) (global.get $RESPAWN_EVERY))
      (then
        (global.set $respawnAcc (f32.const 0.0))
        (if (i32.lt_s (call $rocks_alive)
                      (call $clampi (i32.add (i32.const 2) (global.get $level))
                                    (i32.const 3) (i32.const 10)))
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
)
