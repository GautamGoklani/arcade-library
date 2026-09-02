(module
  ;; ============================================================
  ;; GRID BREAKER — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as arena-shooters/game.wat
  ;; (globals block at the top, entity pools at fixed offsets in linear
  ;; memory, xorshift RNG, an init/set_input/step/get_* export surface)
  ;; and nothing else. Every constant and every routine below is its own.
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
  ;; paddle   @0    : x, y, halfW, vx                        (4 f32 = 16 B)
  ;; balls    @16   : stride 32, MAX_BALLS=6
  ;;                  x, y, vx, vy, radius, active, stuck, stickOff
  ;;                  ends at 16 + 6*32 = 208
  ;; powerups @208  : stride 24, MAX_POWER=8
  ;;                  x, y, vx, vy, kind, active
  ;;                  ends at 208 + 8*24 = 400
  ;; tiles    @400  : stride 8, COLS*ROWS = 15*12 = 180 cells
  ;;                  hp, kind    (hp 0 = empty, hp <0 = indestructible)
  ;;                  cell (col,row) is at 400 + (row*COLS + col)*8
  ;;                  ends at 400 + 180*8 = 1840
  ;; score @1840  lives @1844  level @1848  tilesLeft @1852
  ;;
  ;; tile kinds: 0 = plain, 1 = tough (2 hp), 2 = bomb, 3 = solid
  ;; powerup kinds: 0 = WIDE, 1 = MULTI, 2 = SLOW, 3 = STICKY
  ;; ===================================================

  (global $MAX_BALLS i32 (i32.const 6))
  (global $MAX_POWER i32 (i32.const 8))
  (global $BALLS_OFF i32 (i32.const 16))
  (global $BALL_STRIDE i32 (i32.const 32))
  (global $POWER_OFF i32 (i32.const 208))
  (global $POWER_STRIDE i32 (i32.const 24))
  (global $TILES_OFF i32 (i32.const 400))
  (global $TILE_STRIDE i32 (i32.const 8))
  (global $SCORE_OFF i32 (i32.const 1840))
  (global $LIVES_OFF i32 (i32.const 1844))
  (global $LEVEL_OFF i32 (i32.const 1848))
  (global $LEFT_OFF i32 (i32.const 1852))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))

  ;; The tile grid. 15 * 60 = 900, leaving a 30px gutter either side.
  (global $COLS i32 (i32.const 15))
  (global $ROWS i32 (i32.const 12))
  (global $TILE_W f32 (f32.const 60.0))
  (global $TILE_H f32 (f32.const 26.0))
  (global $GRID_X f32 (f32.const 30.0))
  (global $GRID_Y f32 (f32.const 70.0))

  (global $PADDLE_Y f32 (f32.const 660.0))
  (global $PADDLE_HALF_H f32 (f32.const 9.0))
  (global $PADDLE_HALF_BASE f32 (f32.const 70.0))
  (global $PADDLE_SPEED f32 (f32.const 640.0))
  ;; How wide WIDE makes it, and how far a caught ball can be deflected.
  (global $WIDE_MUL f32 (f32.const 1.55))
  (global $MAX_DEFLECT f32 (f32.const 1.05))

  (global $BALL_R f32 (f32.const 9.0))
  ;; Speed is set against the arena, not in the abstract: at 330 the ball took
  ;; ~4s to cross 720px and back, so a 60-tile wall was a four-minute level.
  ;; 430 puts a round trip near 2.7s, which is a level in about a minute.
  (global $BALL_SPEED_BASE f32 (f32.const 430.0))
  (global $BALL_SPEED_STEP f32 (f32.const 14.0))
  (global $BALL_SPEED_CAP f32 (f32.const 620.0))
  ;; SLOW does not change a ball's stored velocity, only how far it is
  ;; advanced per second — so the effect expiring restores the exact
  ;; trajectory rather than an approximation of it.
  (global $SLOW_MUL f32 (f32.const 0.68))

  (global $POWER_FALL f32 (f32.const 155.0))
  (global $POWER_HALF f32 (f32.const 14.0))
  (global $DROP_CHANCE f32 (f32.const 0.16))
  (global $WIDE_TIME f32 (f32.const 12.0))
  (global $SLOW_TIME f32 (f32.const 9.0))
  (global $STICKY_TIME f32 (f32.const 15.0))

  ;; Scoring.
  (global $SCORE_PLAIN f32 (f32.const 10.0))
  (global $SCORE_TOUGH f32 (f32.const 25.0))
  (global $SCORE_BOMB f32 (f32.const 15.0))
  (global $SCORE_CHIP f32 (f32.const 5.0))
  (global $SCORE_POWER f32 (f32.const 25.0))
  (global $SCORE_LEVEL f32 (f32.const 100.0))

  (global $START_LIVES f32 (f32.const 5.0))

  (global $rng (mut i32) (i32.const 1973272912))
  (global $level (mut i32) (i32.const 1))
  (global $gameOver (mut i32) (i32.const 0))

  ;; input, as reported by set_input each frame
  (global $moveDir (mut f32) (f32.const 0.0))
  (global $launchReq (mut i32) (i32.const 0))
  (global $ptrActive (mut i32) (i32.const 0))
  (global $ptrX (mut f32) (f32.const 0.0))

  ;; power-up timers
  (global $wideTimer (mut f32) (f32.const 0.0))
  (global $slowTimer (mut f32) (f32.const 0.0))
  (global $stickyTimer (mut f32) (f32.const 0.0))

  ;; ---------------- helpers ----------------

  (func $ball_addr (param $i i32) (result i32)
    (i32.add (global.get $BALLS_OFF) (i32.mul (local.get $i) (global.get $BALL_STRIDE))))
  (func $power_addr (param $i i32) (result i32)
    (i32.add (global.get $POWER_OFF) (i32.mul (local.get $i) (global.get $POWER_STRIDE))))
  (func $tile_addr (param $c i32) (param $r i32) (result i32)
    (i32.add (global.get $TILES_OFF)
      (i32.mul (i32.add (i32.mul (local.get $r) (global.get $COLS)) (local.get $c))
               (global.get $TILE_STRIDE))))

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

  (func $cell_cx (param $c i32) (result f32)
    (f32.add (global.get $GRID_X)
      (f32.mul (f32.add (f32.convert_i32_s (local.get $c)) (f32.const 0.5)) (global.get $TILE_W))))
  (func $cell_cy (param $r i32) (result f32)
    (f32.add (global.get $GRID_Y)
      (f32.mul (f32.add (f32.convert_i32_s (local.get $r)) (f32.const 0.5)) (global.get $TILE_H))))

  ;; Ball speed for the current level, capped.
  (func $level_speed (result f32)
    (call $clampf
      (f32.add (global.get $BALL_SPEED_BASE)
        (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                 (global.get $BALL_SPEED_STEP)))
      (global.get $BALL_SPEED_BASE)
      (global.get $BALL_SPEED_CAP)))

  ;; Paddle half-width for the current level and power-up state. The paddle
  ;; narrows by 1.5px a level down to a floor, so late levels press without
  ;; the ball ever getting fast enough to be unreadable.
  (func $paddle_half (result f32)
    (local $h f32)
    (local.set $h
      (call $clampf
        (f32.sub (global.get $PADDLE_HALF_BASE)
          (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1))) (f32.const 1.5)))
        (f32.const 44.0)
        (global.get $PADDLE_HALF_BASE)))
    (if (f32.gt (global.get $wideTimer) (f32.const 0.0))
      (then (local.set $h (f32.mul (local.get $h) (global.get $WIDE_MUL)))))
    (local.get $h))

  (func $add_score (param $n f32)
    (f32.store (global.get $SCORE_OFF)
      (f32.add (f32.load (global.get $SCORE_OFF)) (local.get $n))))

  ;; ---------------- spawning ----------------

  (func $spawn_ball (param $x f32) (param $y f32) (param $vx f32) (param $vy f32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (local.set $a (call $ball_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (local.get $vx))
            (f32.store offset=12 (local.get $a) (local.get $vy))
            (f32.store offset=16 (local.get $a) (global.get $BALL_R))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (f32.const 0.0))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $spawn_power (param $x f32) (param $y f32) (param $kind i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_POWER)))
        (local.set $a (call $power_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a) (f32.const 0.0))
            (f32.store offset=12 (local.get $a) (global.get $POWER_FALL))
            (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (br $done)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $maybe_drop (param $c i32) (param $r i32)
    (if (f32.lt (call $rand_f32) (global.get $DROP_CHANCE))
      (then
        (call $spawn_power
          (call $cell_cx (local.get $c))
          (call $cell_cy (local.get $r))
          (i32.trunc_f32_s (call $frand (f32.const 0.0) (f32.const 3.999)))))))

  ;; ---------------- tile destruction ----------------
  ;;
  ;; $blast and $explode_at are mutually recursive: a bomb destroys its
  ;; neighbours, and a neighbour that is itself a bomb goes off in turn. The
  ;; recursion terminates because $blast zeroes a cell's hp *before* it calls
  ;; $explode_at, so a cell can never be blasted twice; depth is bounded by
  ;; the 180 cells in the grid.

  ;; Destroy a cell outright, whatever its hp — this is a blast, not a hit.
  ;; Solid cells (hp < 0) and empty cells are left alone.
  (func $blast (param $c i32) (param $r i32)
    (local $a i32) (local $kind i32)
    (local.set $a (call $tile_addr (local.get $c) (local.get $r)))
    (if (f32.le (f32.load offset=0 (local.get $a)) (f32.const 0.0)) (then (return)))
    (local.set $kind (i32.trunc_f32_s (f32.load offset=4 (local.get $a))))
    (f32.store offset=0 (local.get $a) (f32.const 0.0))
    (i32.store (global.get $LEFT_OFF)
      (i32.sub (i32.load (global.get $LEFT_OFF)) (i32.const 1)))
    (call $add_score (global.get $SCORE_BOMB))
    (call $maybe_drop (local.get $c) (local.get $r))
    (if (i32.eq (local.get $kind) (i32.const 2))
      (then (call $explode_at (local.get $c) (local.get $r)))))

  (func $explode_at (param $c i32) (param $r i32)
    (local $dc i32) (local $dr i32) (local $nc i32) (local $nr i32)
    (local.set $dr (i32.const -1))
    (block $rdone
      (loop $rlp
        (br_if $rdone (i32.gt_s (local.get $dr) (i32.const 1)))
        (local.set $dc (i32.const -1))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.gt_s (local.get $dc) (i32.const 1)))
            (local.set $nc (i32.add (local.get $c) (local.get $dc)))
            (local.set $nr (i32.add (local.get $r) (local.get $dr)))
            (if (i32.and
                  (i32.and (i32.ge_s (local.get $nc) (i32.const 0))
                           (i32.lt_s (local.get $nc) (global.get $COLS)))
                  (i32.and (i32.ge_s (local.get $nr) (i32.const 0))
                           (i32.lt_s (local.get $nr) (global.get $ROWS))))
              (then (call $blast (local.get $nc) (local.get $nr))))
            (local.set $dc (i32.add (local.get $dc) (i32.const 1)))
            (br $clp)))
        (local.set $dr (i32.add (local.get $dr) (i32.const 1)))
        (br $rlp))))

  ;; One ball-strike on a cell. Returns 1 if the cell was occupied (so the
  ;; ball bounces) and 0 if it was empty (so the ball passes through).
  (func $damage_tile (param $c i32) (param $r i32) (result i32)
    (local $a i32) (local $hp f32) (local $kind i32)
    (local.set $a (call $tile_addr (local.get $c) (local.get $r)))
    (local.set $hp (f32.load offset=0 (local.get $a)))
    (if (f32.eq (local.get $hp) (f32.const 0.0)) (then (return (i32.const 0))))
    ;; solid: bounces, never breaks
    (if (f32.lt (local.get $hp) (f32.const 0.0)) (then (return (i32.const 1))))

    (local.set $kind (i32.trunc_f32_s (f32.load offset=4 (local.get $a))))
    (local.set $hp (f32.sub (local.get $hp) (f32.const 1.0)))
    (f32.store offset=0 (local.get $a) (local.get $hp))

    (if (f32.le (local.get $hp) (f32.const 0.0))
      (then
        (f32.store offset=0 (local.get $a) (f32.const 0.0))
        (i32.store (global.get $LEFT_OFF)
          (i32.sub (i32.load (global.get $LEFT_OFF)) (i32.const 1)))
        (call $add_score
          (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
            (then (global.get $SCORE_TOUGH))
            (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
                    (then (global.get $SCORE_BOMB))
                    (else (global.get $SCORE_PLAIN))))))
        (call $maybe_drop (local.get $c) (local.get $r))
        (if (i32.eq (local.get $kind) (i32.const 2))
          (then (call $explode_at (local.get $c) (local.get $r)))))
      (else
        ;; a tough tile that survived — chipping it is worth something
        (call $add_score (global.get $SCORE_CHIP))))
    (i32.const 1))

  ;; Does a ball at (x,y,r) overlap an occupied cell? If so, strike the first
  ;; one found and report the bounce.
  (func $collide_tiles (param $x f32) (param $y f32) (param $r f32) (result i32)
    (local $x0 f32) (local $x1 f32) (local $y0 f32) (local $y1 f32)
    (local $c0 i32) (local $c1 i32) (local $r0 i32) (local $r1 i32)
    (local $c i32) (local $rr i32)

    (local.set $x0 (f32.sub (f32.sub (local.get $x) (local.get $r)) (global.get $GRID_X)))
    (local.set $x1 (f32.sub (f32.add (local.get $x) (local.get $r)) (global.get $GRID_X)))
    (local.set $y0 (f32.sub (f32.sub (local.get $y) (local.get $r)) (global.get $GRID_Y)))
    (local.set $y1 (f32.sub (f32.add (local.get $y) (local.get $r)) (global.get $GRID_Y)))

    ;; entirely outside the grid — the common case, so it is checked first
    (if (f32.lt (local.get $x1) (f32.const 0.0)) (then (return (i32.const 0))))
    (if (f32.lt (local.get $y1) (f32.const 0.0)) (then (return (i32.const 0))))
    (if (f32.gt (local.get $x0)
          (f32.mul (f32.convert_i32_s (global.get $COLS)) (global.get $TILE_W)))
      (then (return (i32.const 0))))
    (if (f32.gt (local.get $y0)
          (f32.mul (f32.convert_i32_s (global.get $ROWS)) (global.get $TILE_H)))
      (then (return (i32.const 0))))

    (local.set $c0 (call $clampi (i32.trunc_f32_s (f32.div (local.get $x0) (global.get $TILE_W)))
                                 (i32.const 0) (i32.sub (global.get $COLS) (i32.const 1))))
    (local.set $c1 (call $clampi (i32.trunc_f32_s (f32.div (local.get $x1) (global.get $TILE_W)))
                                 (i32.const 0) (i32.sub (global.get $COLS) (i32.const 1))))
    (local.set $r0 (call $clampi (i32.trunc_f32_s (f32.div (local.get $y0) (global.get $TILE_H)))
                                 (i32.const 0) (i32.sub (global.get $ROWS) (i32.const 1))))
    (local.set $r1 (call $clampi (i32.trunc_f32_s (f32.div (local.get $y1) (global.get $TILE_H)))
                                 (i32.const 0) (i32.sub (global.get $ROWS) (i32.const 1))))

    (local.set $rr (local.get $r0))
    (block $done
      (loop $rlp
        (br_if $done (i32.gt_s (local.get $rr) (local.get $r1)))
        (local.set $c (local.get $c0))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.gt_s (local.get $c) (local.get $c1)))
            (if (call $damage_tile (local.get $c) (local.get $rr))
              (then (return (i32.const 1))))
            (local.set $c (i32.add (local.get $c) (i32.const 1)))
            (br $clp)))
        (local.set $rr (i32.add (local.get $rr) (i32.const 1)))
        (br $rlp)))
    (i32.const 0))

  ;; ---------------- level construction ----------------

  (func $clear_grid
    (local $i i32) (local $n i32) (local $a i32)
    (local.set $n (i32.mul (global.get $COLS) (global.get $ROWS)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $a (i32.add (global.get $TILES_OFF)
                        (i32.mul (local.get $i) (global.get $TILE_STRIDE))))
        (f32.store offset=0 (local.get $a) (f32.const 0.0))
        (f32.store offset=4 (local.get $a) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Five patterns, cycled by level, so the wall a player meets is laid out
  ;; differently every level rather than being the same rectangle with more
  ;; hit points. Returns 1 if cell (c,r) should hold a tile.
  (func $pattern_fill (param $pat i32) (param $c i32) (param $r i32) (param $rows i32) (result i32)
    (local $mid i32) (local $d i32)
    (local.set $mid (i32.div_s (global.get $COLS) (i32.const 2)))
    (local.set $d (i32.sub (local.get $c) (local.get $mid)))
    (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.sub (i32.const 0) (local.get $d)))))

    ;; 0 — checkerboard. Level 1 is this rather than the solid block on
    ;; purpose: half the tiles, so a first-time player clears a level and sees
    ;; the level-up before deciding whether the game is worth their time.
    (if (i32.eq (local.get $pat) (i32.const 0))
      (then (return (i32.eqz (i32.and (i32.add (local.get $c) (local.get $r)) (i32.const 1))))))
    ;; 1 — solid block
    (if (i32.eq (local.get $pat) (i32.const 1)) (then (return (i32.const 1))))
    ;; 2 — pyramid, one tile wide at the top
    (if (i32.eq (local.get $pat) (i32.const 2))
      (then (return (i32.le_s (local.get $d) (local.get $r)))))
    ;; 3 — vertical stripes with gaps to thread
    (if (i32.eq (local.get $pat) (i32.const 3))
      (then (return (i32.ne (i32.rem_s (local.get $c) (i32.const 3)) (i32.const 2)))))
    ;; 4 — hollow frame with a lattice inside
    (return (i32.or
      (i32.or (i32.eqz (local.get $r))
              (i32.eq (local.get $r) (i32.sub (local.get $rows) (i32.const 1))))
      (i32.or (i32.or (i32.eqz (local.get $c))
                      (i32.eq (local.get $c) (i32.sub (global.get $COLS) (i32.const 1))))
              (i32.eqz (i32.and (i32.add (local.get $c) (local.get $r)) (i32.const 3)))))))

  (func $build_level
    (local $pat i32) (local $rows i32) (local $c i32) (local $r i32) (local $a i32)
    (local $roll f32) (local $bomb f32) (local $tough f32) (local $kind i32)

    (call $clear_grid)
    (i32.store (global.get $LEFT_OFF) (i32.const 0))

    (local.set $pat (i32.rem_s (i32.sub (global.get $level) (i32.const 1)) (i32.const 5)))
    ;; four rows at level 1, one more every second level, capped at 10 of the
    ;; 12 the grid can hold — the last two stay empty so the wall never starts
    ;; within a ball's reach of the paddle.
    (local.set $rows (call $clampi
      (i32.add (i32.const 4) (i32.div_s (global.get $level) (i32.const 2)))
      (i32.const 4) (i32.const 10)))

    (local.set $bomb (call $clampf
      (f32.add (f32.const 0.06) (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.005)))
      (f32.const 0.0) (f32.const 0.14)))
    (local.set $tough (call $clampf
      (f32.add (f32.const 0.10) (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.02)))
      (f32.const 0.0) (f32.const 0.35)))

    (local.set $r (i32.const 0))
    (block $rdone
      (loop $rlp
        (br_if $rdone (i32.ge_s (local.get $r) (local.get $rows)))
        (local.set $c (i32.const 0))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.ge_s (local.get $c) (global.get $COLS)))
            (if (call $pattern_fill (local.get $pat) (local.get $c) (local.get $r) (local.get $rows))
              (then
                (local.set $a (call $tile_addr (local.get $c) (local.get $r)))
                (local.set $roll (call $rand_f32))
                (local.set $kind (i32.const 0))
                (if (f32.lt (local.get $roll) (local.get $bomb))
                  (then (local.set $kind (i32.const 2)))
                  (else (if (f32.lt (local.get $roll) (f32.add (local.get $bomb) (local.get $tough)))
                          (then (local.set $kind (i32.const 1)))
                          ;; solid tiles only from level 3, and never on the
                          ;; bottom row of the wall — one parked in front of a
                          ;; pocket can make a level unclearable
                          (else (if (i32.and (i32.ge_s (global.get $level) (i32.const 3))
                                             (i32.and (f32.gt (local.get $roll) (f32.const 0.94))
                                                      (i32.lt_s (local.get $r) (i32.sub (local.get $rows) (i32.const 1)))))
                                  (then (local.set $kind (i32.const 3))))))))

                (f32.store offset=4 (local.get $a) (f32.convert_i32_s (local.get $kind)))
                (if (i32.eq (local.get $kind) (i32.const 3))
                  (then
                    (f32.store offset=0 (local.get $a) (f32.const -1.0)))
                  (else
                    (f32.store offset=0 (local.get $a)
                      (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
                        (then (f32.const 2.0))
                        (else (f32.const 1.0))))
                    (i32.store (global.get $LEFT_OFF)
                      (i32.add (i32.load (global.get $LEFT_OFF)) (i32.const 1)))))))
            (local.set $c (i32.add (local.get $c) (i32.const 1)))
            (br $clp)))
        (local.set $r (i32.add (local.get $r) (i32.const 1)))
        (br $rlp))))

  ;; ---------------- resets ----------------

  (func $clear_balls
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (f32.store offset=20 (call $ball_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $clear_powers
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_POWER)))
        (f32.store offset=20 (call $power_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; One ball, parked on the paddle, waiting for a launch press. Every way of
  ;; starting a ball goes through here: a new level, a lost life, a new game.
  (func $serve
    (local $a i32)
    (call $clear_balls)
    (call $clear_powers)
    (global.set $wideTimer (f32.const 0.0))
    (global.set $slowTimer (f32.const 0.0))
    (global.set $stickyTimer (f32.const 0.0))
    (f32.store offset=8 (i32.const 0) (call $paddle_half))
    (call $spawn_ball
      (f32.load offset=0 (i32.const 0))
      (f32.sub (f32.sub (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)) (global.get $BALL_R))
      (f32.const 0.0) (f32.const 0.0))
    (local.set $a (call $ball_addr (i32.const 0)))
    (f32.store offset=24 (local.get $a) (f32.const 1.0))
    (f32.store offset=28 (local.get $a) (f32.const 0.0)))

  (func $init (export "init")
    (global.set $level (i32.const 1))
    (global.set $gameOver (i32.const 0))
    (global.set $moveDir (f32.const 0.0))
    ;; A launch key still held from the last run must not serve the next one:
    ;; the press has to arrive fresh.
    (global.set $launchReq (i32.const 0))
    (global.set $ptrActive (i32.const 0))

    (f32.store offset=0 (i32.const 0) (f32.mul (global.get $WORLD_W) (f32.const 0.5)))
    (f32.store offset=4 (i32.const 0) (global.get $PADDLE_Y))
    (f32.store offset=8 (i32.const 0) (global.get $PADDLE_HALF_BASE))
    (f32.store offset=12 (i32.const 0) (f32.const 0.0))

    (f32.store (global.get $SCORE_OFF) (f32.const 0.0))
    (f32.store (global.get $LIVES_OFF) (global.get $START_LIVES))
    (i32.store (global.get $LEVEL_OFF) (i32.const 1))

    (call $build_level)
    (call $serve))

  (func $set_input (export "set_input")
      (param $dir f32) (param $launch i32) (param $ptrOn i32) (param $px f32)
    (global.set $moveDir (local.get $dir))
    (global.set $launchReq (local.get $launch))
    (global.set $ptrActive (local.get $ptrOn))
    (global.set $ptrX (local.get $px)))

  ;; ---------------- per-frame passes ----------------

  (func $step_paddle (param $dt f32)
    (local $x f32) (local $half f32) (local $target f32) (local $prev f32)
    (local.set $prev (f32.load offset=0 (i32.const 0)))
    (local.set $half (call $paddle_half))
    (local.set $x (local.get $prev))

    (if (i32.ne (global.get $ptrActive) (i32.const 0))
      (then
        ;; Pointer/touch steering wins over the keys when both arrive: the
        ;; paddle eases toward the finger rather than snapping, so a drag
        ;; cannot teleport it across the arena between two frames.
        (local.set $target (global.get $ptrX))
        (local.set $x (f32.add (local.get $x)
          (f32.mul (f32.sub (local.get $target) (local.get $x))
                   (call $clampf (f32.mul (local.get $dt) (f32.const 18.0))
                                 (f32.const 0.0) (f32.const 1.0))))))
      (else
        (local.set $x (f32.add (local.get $x)
          (f32.mul (f32.mul (global.get $moveDir) (global.get $PADDLE_SPEED)) (local.get $dt))))))

    (local.set $x (call $clampf (local.get $x)
      (local.get $half) (f32.sub (global.get $WORLD_W) (local.get $half))))

    (f32.store offset=0 (i32.const 0) (local.get $x))
    (f32.store offset=8 (i32.const 0) (local.get $half))
    (f32.store offset=12 (i32.const 0)
      (f32.div (f32.sub (local.get $x) (local.get $prev)) (f32.max (local.get $dt) (f32.const 0.0001)))))

  ;; Bounce a ball off the paddle, steering it by where it landed: the edges
  ;; throw it out at up to $MAX_DEFLECT from vertical, the middle sends it
  ;; straight back. Speed is preserved exactly, so control is the only thing
  ;; the paddle gives you.
  (func $paddle_bounce (param $a i32) (param $half f32)
    (local $off f32) (local $ang f32) (local $sp f32)
    (local.set $off (call $clampf
      (f32.div (f32.sub (f32.load offset=0 (local.get $a)) (f32.load offset=0 (i32.const 0)))
               (local.get $half))
      (f32.const -1.0) (f32.const 1.0)))
    (local.set $ang (f32.mul (local.get $off) (global.get $MAX_DEFLECT)))
    (local.set $sp (f32.sqrt
      (f32.add (f32.mul (f32.load offset=8 (local.get $a)) (f32.load offset=8 (local.get $a)))
               (f32.mul (f32.load offset=12 (local.get $a)) (f32.load offset=12 (local.get $a))))))
    (if (f32.lt (local.get $sp) (f32.const 1.0))
      (then (local.set $sp (call $level_speed))))

    (f32.store offset=4 (local.get $a)
      (f32.sub (f32.sub (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)) (global.get $BALL_R)))
    (f32.store offset=8 (local.get $a) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
    (f32.store offset=12 (local.get $a)
      (f32.mul (f32.mul (call $cosf (local.get $ang)) (local.get $sp)) (f32.const -1.0)))

    ;; STICKY catches the ball instead of returning it, until it is launched.
    (if (f32.gt (global.get $stickyTimer) (f32.const 0.0))
      (then
        (f32.store offset=24 (local.get $a) (f32.const 1.0))
        (f32.store offset=28 (local.get $a)
          (f32.sub (f32.load offset=0 (local.get $a)) (f32.load offset=0 (i32.const 0)))))))

  ;; Advance one ball. The motion is split into sub-steps short enough that a
  ;; ball can never cross a whole tile in one of them — without this a fast
  ;; ball tunnels straight through the wall — and each sub-step moves one axis
  ;; at a time, so the axis that hit something is the axis that reverses.
  (func $step_ball (param $a i32) (param $dt f32)
    (local $mul f32) (local $sp f32) (local $n i32) (local $i i32) (local $sdt f32)
    (local $x f32) (local $y f32) (local $vx f32) (local $vy f32) (local $r f32)
    (local $half f32) (local $px f32)

    (local.set $r (f32.load offset=16 (local.get $a)))
    (local.set $mul (if (result f32) (f32.gt (global.get $slowTimer) (f32.const 0.0))
                      (then (global.get $SLOW_MUL)) (else (f32.const 1.0))))

    (local.set $vx (f32.mul (f32.load offset=8 (local.get $a)) (local.get $mul)))
    (local.set $vy (f32.mul (f32.load offset=12 (local.get $a)) (local.get $mul)))
    (local.set $sp (f32.sqrt
      (f32.add (f32.mul (local.get $vx) (local.get $vx)) (f32.mul (local.get $vy) (local.get $vy)))))

    ;; one sub-step per 5px of travel, capped so a stalled frame cannot spin here
    (local.set $n (i32.trunc_f32_s
      (f32.add (f32.div (f32.mul (local.get $sp) (local.get $dt)) (f32.const 5.0)) (f32.const 1.0))))
    (local.set $n (call $clampi (local.get $n) (i32.const 1) (i32.const 12)))
    (local.set $sdt (f32.div (local.get $dt) (f32.convert_i32_s (local.get $n))))

    (local.set $x (f32.load offset=0 (local.get $a)))
    (local.set $y (f32.load offset=4 (local.get $a)))
    (local.set $half (f32.load offset=8 (i32.const 0)))
    (local.set $px (f32.load offset=0 (i32.const 0)))

    (local.set $i (i32.const 0))
    (block $sdone
      (loop $slp
        (br_if $sdone (i32.ge_s (local.get $i) (local.get $n)))

        ;; ---- X axis ----
        (local.set $x (f32.add (local.get $x) (f32.mul (local.get $vx) (local.get $sdt))))
        (if (call $collide_tiles (local.get $x) (local.get $y) (local.get $r))
          (then
            (local.set $x (f32.sub (local.get $x) (f32.mul (local.get $vx) (local.get $sdt))))
            (local.set $vx (f32.mul (local.get $vx) (f32.const -1.0)))
            (f32.store offset=8 (local.get $a)
              (f32.mul (f32.load offset=8 (local.get $a)) (f32.const -1.0)))))

        ;; side walls
        (if (f32.lt (local.get $x) (local.get $r))
          (then
            (local.set $x (local.get $r))
            (local.set $vx (f32.abs (local.get $vx)))
            (f32.store offset=8 (local.get $a) (f32.abs (f32.load offset=8 (local.get $a))))))
        (if (f32.gt (local.get $x) (f32.sub (global.get $WORLD_W) (local.get $r)))
          (then
            (local.set $x (f32.sub (global.get $WORLD_W) (local.get $r)))
            (local.set $vx (f32.neg (f32.abs (local.get $vx))))
            (f32.store offset=8 (local.get $a) (f32.neg (f32.abs (f32.load offset=8 (local.get $a)))))))

        ;; ---- Y axis ----
        (local.set $y (f32.add (local.get $y) (f32.mul (local.get $vy) (local.get $sdt))))
        (if (call $collide_tiles (local.get $x) (local.get $y) (local.get $r))
          (then
            (local.set $y (f32.sub (local.get $y) (f32.mul (local.get $vy) (local.get $sdt))))
            (local.set $vy (f32.mul (local.get $vy) (f32.const -1.0)))
            (f32.store offset=12 (local.get $a)
              (f32.mul (f32.load offset=12 (local.get $a)) (f32.const -1.0)))))

        ;; ceiling
        (if (f32.lt (local.get $y) (local.get $r))
          (then
            (local.set $y (local.get $r))
            (local.set $vy (f32.abs (local.get $vy)))
            (f32.store offset=12 (local.get $a) (f32.abs (f32.load offset=12 (local.get $a))))))

        ;; paddle — only ever while descending, so a ball that clipped the
        ;; edge cannot be caught a second time on its way back up
        (if (i32.and (f32.gt (local.get $vy) (f32.const 0.0))
              (i32.and
                (f32.ge (f32.add (local.get $y) (local.get $r))
                        (f32.sub (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)))
                (i32.and
                  (f32.le (f32.sub (local.get $y) (local.get $r))
                          (f32.add (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)))
                  (f32.le (f32.abs (f32.sub (local.get $x) (local.get $px)))
                          (f32.add (local.get $half) (local.get $r))))))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (call $paddle_bounce (local.get $a) (local.get $half))
            (local.set $y (f32.load offset=4 (local.get $a)))
            (local.set $vx (f32.mul (f32.load offset=8 (local.get $a)) (local.get $mul)))
            (local.set $vy (f32.mul (f32.load offset=12 (local.get $a)) (local.get $mul)))
            ;; caught by STICKY — stop here, the ball is on the paddle now
            (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
              (then (br $sdone)))))

        ;; lost below the floor
        (if (f32.gt (f32.sub (local.get $y) (local.get $r)) (global.get $WORLD_H))
          (then
            (f32.store offset=20 (local.get $a) (f32.const 0.0))
            (br $sdone)))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $slp)))

    (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
      (then
        (f32.store offset=0 (local.get $a) (local.get $x))
        (f32.store offset=4 (local.get $a) (local.get $y)))))

  (func $balls_alive (export "balls_alive") (result i32)
    (local $i i32) (local $n i32)
    (local.set $i (i32.const 0))
    (local.set $n (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (if (f32.gt (f32.load offset=20 (call $ball_addr (local.get $i))) (f32.const 0.0))
          (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $n))

  ;; MULTI: every ball in play splits into three, the copies leaving at
  ;; ±0.4 rad. Read the live count first — otherwise the balls this loop
  ;; spawns are themselves split, and one capsule fills the pool.
  (func $split_balls
    (local $i i32) (local $a i32) (local $vx f32) (local $vy f32) (local $c f32) (local $s f32)
    (local.set $c (call $cosf (f32.const 0.4)))
    (local.set $s (call $sinf (f32.const 0.4)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (local.set $a (call $ball_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                     (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0)))
          (then
            (local.set $vx (f32.load offset=8 (local.get $a)))
            (local.set $vy (f32.load offset=12 (local.get $a)))
            (call $spawn_ball (f32.load offset=0 (local.get $a)) (f32.load offset=4 (local.get $a))
              (f32.sub (f32.mul (local.get $vx) (local.get $c)) (f32.mul (local.get $vy) (local.get $s)))
              (f32.add (f32.mul (local.get $vx) (local.get $s)) (f32.mul (local.get $vy) (local.get $c))))
            (call $spawn_ball (f32.load offset=0 (local.get $a)) (f32.load offset=4 (local.get $a))
              (f32.add (f32.mul (local.get $vx) (local.get $c)) (f32.mul (local.get $vy) (local.get $s)))
              (f32.sub (f32.mul (local.get $vy) (local.get $c)) (f32.mul (local.get $vx) (local.get $s))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $apply_power (param $kind i32)
    (call $add_score (global.get $SCORE_POWER))
    (if (i32.eq (local.get $kind) (i32.const 0))
      (then (global.set $wideTimer (global.get $WIDE_TIME))))
    (if (i32.eq (local.get $kind) (i32.const 1))
      (then (call $split_balls)))
    (if (i32.eq (local.get $kind) (i32.const 2))
      (then (global.set $slowTimer (global.get $SLOW_TIME))))
    (if (i32.eq (local.get $kind) (i32.const 3))
      (then (global.set $stickyTimer (global.get $STICKY_TIME)))))

  (func $step_powers (param $dt f32)
    (local $i i32) (local $a i32) (local $x f32) (local $y f32) (local $half f32) (local $px f32)
    (local.set $half (f32.load offset=8 (i32.const 0)))
    (local.set $px (f32.load offset=0 (i32.const 0)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_POWER)))
        (local.set $a (call $power_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $x (f32.load offset=0 (local.get $a)))
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
                            (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt))))
            (f32.store offset=4 (local.get $a) (local.get $y))

            (if (i32.and
                  (f32.ge (f32.add (local.get $y) (global.get $POWER_HALF))
                          (f32.sub (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)))
                  (i32.and
                    (f32.le (f32.sub (local.get $y) (global.get $POWER_HALF))
                            (f32.add (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)))
                    (f32.le (f32.abs (f32.sub (local.get $x) (local.get $px)))
                            (f32.add (local.get $half) (global.get $POWER_HALF)))))
              (then
                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                (call $apply_power (i32.trunc_f32_s (f32.load offset=16 (local.get $a)))))
              (else
                (if (f32.gt (f32.sub (local.get $y) (global.get $POWER_HALF)) (global.get $WORLD_H))
                  (then (f32.store offset=20 (local.get $a) (f32.const 0.0))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; A stuck ball rides the paddle until the launch key is pressed. The offset
  ;; it was caught at is kept, so it leaves from where it landed.
  (func $step_stuck
    (local $i i32) (local $a i32) (local $sp f32) (local $ang f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (local.set $a (call $ball_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                     (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0)))
          (then
            (f32.store offset=0 (local.get $a)
              (f32.add (f32.load offset=0 (i32.const 0)) (f32.load offset=28 (local.get $a))))
            (f32.store offset=4 (local.get $a)
              (f32.sub (f32.sub (global.get $PADDLE_Y) (global.get $PADDLE_HALF_H)) (global.get $BALL_R)))
            (if (i32.ne (global.get $launchReq) (i32.const 0))
              (then
                (local.set $sp (call $level_speed))
                ;; leaves at the angle its resting offset implies, so a ball
                ;; caught on the edge launches outward rather than straight up
                (local.set $ang (f32.mul
                  (call $clampf (f32.div (f32.load offset=28 (local.get $a))
                                         (f32.load offset=8 (i32.const 0)))
                                (f32.const -1.0) (f32.const 1.0))
                  (f32.const 0.6)))
                ;; Never serve vertically. A ball with vx == 0 drills a single
                ;; column and, if the paddle just tracks it, stays vertical for
                ;; the rest of the run — found by the headless bench, whose
                ;; pilot centres perfectly and so hit exactly that state.
                (if (f32.lt (f32.abs (local.get $ang)) (f32.const 0.15))
                  (then
                    (local.set $ang (call $frand (f32.const 0.22) (f32.const 0.5)))
                    (if (f32.lt (call $rand_f32) (f32.const 0.5))
                      (then (local.set $ang (f32.neg (local.get $ang)))))))
                (f32.store offset=8 (local.get $a) (f32.mul (call $sinf (local.get $ang)) (local.get $sp)))
                (f32.store offset=12 (local.get $a)
                  (f32.mul (f32.mul (call $cosf (local.get $ang)) (local.get $sp)) (f32.const -1.0)))
                (f32.store offset=24 (local.get $a) (f32.const 0.0))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $lose_life
    (f32.store (global.get $LIVES_OFF)
      (f32.sub (f32.load (global.get $LIVES_OFF)) (f32.const 1.0)))
    (if (f32.le (f32.load (global.get $LIVES_OFF)) (f32.const 0.0))
      (then
        (f32.store (global.get $LIVES_OFF) (f32.const 0.0))
        (global.set $gameOver (i32.const 1)))
      (else (call $serve))))

  (func $next_level
    (global.set $level (i32.add (global.get $level) (i32.const 1)))
    (i32.store (global.get $LEVEL_OFF) (global.get $level))
    (call $add_score (global.get $SCORE_LEVEL))
    (call $build_level)
    (call $serve))

  (func $step (export "step") (param $dt f32)
    (local $i i32) (local $a i32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))

    (if (f32.gt (global.get $wideTimer) (f32.const 0.0))
      (then (global.set $wideTimer (f32.sub (global.get $wideTimer) (local.get $dt)))))
    (if (f32.gt (global.get $slowTimer) (f32.const 0.0))
      (then (global.set $slowTimer (f32.sub (global.get $slowTimer) (local.get $dt)))))
    (if (f32.gt (global.get $stickyTimer) (f32.const 0.0))
      (then (global.set $stickyTimer (f32.sub (global.get $stickyTimer) (local.get $dt)))))

    (call $step_paddle (local.get $dt))
    (call $step_stuck)

    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_BALLS)))
        (local.set $a (call $ball_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                     (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0)))
          (then (call $step_ball (local.get $a) (local.get $dt))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    (call $step_powers (local.get $dt))

    ;; Order matters: a level cleared by the shot that also lost the last ball
    ;; should advance, not cost a life.
    (if (i32.le_s (i32.load (global.get $LEFT_OFF)) (i32.const 0))
      (then (call $next_level))
      (else
        (if (i32.eqz (call $balls_alive))
          (then (call $lose_life))))))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (f32.load (global.get $SCORE_OFF)))
  (func $get_lives (export "get_lives") (result f32) (f32.load (global.get $LIVES_OFF)))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_tiles_left (export "get_tiles_left") (result i32) (i32.load (global.get $LEFT_OFF)))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_wide (export "get_wide") (result f32) (global.get $wideTimer))
  (func $get_slow (export "get_slow") (result f32) (global.get $slowTimer))
  (func $get_sticky (export "get_sticky") (result f32) (global.get $stickyTimer))
)
