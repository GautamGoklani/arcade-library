(module
  ;; ============================================================
  ;; TOWER DEFENSE LITE — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as the other seven (globals
  ;; block at the top, entity pools at fixed offsets in linear memory, xorshift
  ;; RNG, monotonic event counters, an init/set_input/step/get_* export
  ;; surface) and nothing else. Every constant and every routine below is its
  ;; own.
  ;;
  ;; ---- what is new here ----
  ;;
  ;; **The player does not steer anything.** Every other title in this library
  ;; hands you a thing and asks where to put it thirty times a second. This one
  ;; asks where to put something four or five times a wave, and then makes you
  ;; watch. That changes what the engine has to be: the interesting state is
  ;; the *board*, not a position, and the input is a cell and a verb rather
  ;; than an axis.
  ;;
  ;; **Heat, not money, is the binding resource.** Scrap runs out and comes
  ;; back; heat runs out inside the wave you need it. Every gun tower heats as
  ;; it fires, trips at 100, and will not fire again until it has cooled to 40.
  ;; A block of eight pylons therefore does not fire eight guns' worth — it
  ;; fires all eight for four seconds and then nothing at all, and the wave
  ;; walks through the hole. Keeping the *damage continuous* is the game, and
  ;; the answer is the vent, which shoots nothing and cools its eight
  ;; neighbours. Every vent is a gun you did not build, which is the trade.
  ;;
  ;; **The build phase can be skipped, for money.** A timer with nothing
  ;; happening in it is dead time, and this repository has a rule about that.
  ;; Calling the wave in early pays out the remaining seconds as scrap, so the
  ;; quiet part of the loop is a decision — bank the time or spend it — rather
  ;; than a wait.
  ;;
  ;; There are **no imports**, as in worm-chase, sector-defense,
  ;; circuit-runner and starfield-runner. Towers range-check with a distance,
  ;; shells fly along a normalised vector, and both of those are f32.sqrt,
  ;; which is an instruction. Nothing here needs an angle: the widget derives
  ;; the barrel direction from the tower's stored aim point with Math.atan2,
  ;; because that is a drawing question.
  ;;
  ;; JavaScript owns no game state — not the selected tower, not the scrap,
  ;; not whether a cell can be built on. It forwards a cell and a verb, calls
  ;; step(dt), and reads the grid and the pools to draw them.
  ;; ============================================================

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; grid    @0    : stride 4, COLS*ROWS = 16*12 = 192 cells
  ;;                 byte 0  kind    0 = open, 1 = path, 2 = core
  ;;                 byte 1  tower   pool index + 1, or 0 for none
  ;;                 byte 2  step    index along the path, meaningless if kind 0
  ;;                 byte 3  spare
  ;;                 cell (c,r) is at (r*COLS + c)*4
  ;;                 ends at 192*4 = 768
  ;; towers  @768  : stride 40, MAX_TOWERS = 28
  ;;                 x, y, kind, heat, cd, active, aimX, aimY, tracer, tripped
  ;;                 ends at 768 + 28*40 = 1888
  ;; enemies @1888 : stride 40, MAX_ENEMIES = 40
  ;;                 x, y, hp, maxHp, kind, active, step, t, flash, spare
  ;;                 ends at 1888 + 40*40 = 3488
  ;; shells  @3488 : stride 32, MAX_SHELLS = 24
  ;;                 x, y, vx, vy, tx, ty, active, dmg
  ;;                 ends at 3488 + 24*32 = 4256
  ;; path    @4256 : stride 8, MAX_PATH = 120
  ;;                 px, py — the world centre of each path cell, in order
  ;;                 ends at 4256 + 120*8 = 5216
  ;;
  ;; tower kinds:  0 = pylon, 1 = mortar, 2 = vent
  ;; enemy kinds:  0 = crawler, 1 = sprinter, 2 = hauler, 3 = damper
  ;;
  ;; `tripped` is 1 while a tower is over its heat limit and refusing to fire;
  ;; it clears at $HEAT_RESET rather than at 100, because a tower that resumes
  ;; the instant it drops below the limit chatters on and off every frame and
  ;; delivers neither damage nor a legible picture. `tracer` is a countdown the
  ;; widget draws a hitscan line for — the engine sets it, so the line and the
  ;; damage can never disagree about whether a shot happened.
  ;;
  ;; Scalars — scrap, core integrity, level, the phase clock — live in globals
  ;; rather than memory, as in the other recent titles: the get_* readers are
  ;; the only consumer, and a global is one instruction to read.
  ;; ===================================================

  (global $GRID_OFF i32 (i32.const 0))
  (global $CELL_STRIDE i32 (i32.const 4))
  (global $COLS i32 (i32.const 16))
  (global $ROWS i32 (i32.const 12))
  (global $TOWERS_OFF i32 (i32.const 768))
  (global $TOWER_STRIDE i32 (i32.const 40))
  ;; Twenty-eight, on a board with about 140 buildable squares. The cap is a
  ;; game rule, not a memory bound: at forty the bench could eventually fill
  ;; every useful square, at which point every strategy converges on one of
  ;; everything everywhere and none of the choices this game is made of mean
  ;; anything. Twenty-eight keeps a slot spent on a vent a slot not spent on a
  ;; gun, which is the trade the whole title rests on.
  (global $MAX_TOWERS i32 (i32.const 28))
  (global $ENEMIES_OFF i32 (i32.const 1888))
  (global $ENEMY_STRIDE i32 (i32.const 40))
  (global $MAX_ENEMIES i32 (i32.const 40))
  (global $SHELLS_OFF i32 (i32.const 3488))
  (global $SHELL_STRIDE i32 (i32.const 32))
  (global $MAX_SHELLS i32 (i32.const 24))
  (global $PATH_OFF i32 (i32.const 4256))
  (global $PATH_STRIDE i32 (i32.const 8))
  (global $MAX_PATH i32 (i32.const 120))

  (global $WORLD_W f32 (f32.const 960.0))
  (global $WORLD_H f32 (f32.const 720.0))
  (global $CELL f32 (f32.const 60.0))

  ;; ---- towers ----
  ;; Costs are in scrap. The ratio that matters is pylon:vent — a vent at 15
  ;; against a pylon at 20 makes cooling three quarters the price of shooting,
  ;; which is roughly where the arithmetic makes it worth building one for
  ;; every two or three guns. Cheaper and the board fills with vents; dearer
  ;; and nobody builds one and the whole mechanic is a tax.
  (global $COST_PYLON f32 (f32.const 20.0))
  (global $COST_MORTAR f32 (f32.const 45.0))
  (global $COST_VENT f32 (f32.const 15.0))
  ;; Selling gives back most of it. Not all, or a player rearranges the board
  ;; between every wave for free and placement stops being a commitment.
  (global $SELL_FRACTION f32 (f32.const 0.65))

  (global $PYLON_RANGE f32 (f32.const 132.0))
  (global $PYLON_DMG f32 (f32.const 9.0))
  (global $PYLON_RELOAD f32 (f32.const 0.26))
  (global $PYLON_HEAT f32 (f32.const 13.0))

  (global $MORTAR_RANGE f32 (f32.const 210.0))
  (global $MORTAR_DMG f32 (f32.const 26.0))
  (global $MORTAR_RELOAD f32 (f32.const 1.5))
  (global $MORTAR_HEAT f32 (f32.const 33.0))
  (global $MORTAR_SPLASH f32 (f32.const 62.0))
  (global $SHELL_SPEED f32 (f32.const 460.0))

  ;; 92px against a 60px cell reaches the eight neighbours and nothing else:
  ;; orthogonal is 60, diagonal is 85, and two cells away is 120. So a vent
  ;; cools exactly the ring around it, which is a rule a player can see on the
  ;; grid rather than one they have to be told.
  (global $VENT_RANGE f32 (f32.const 92.0))
  (global $VENT_COOL f32 (f32.const 20.0))    ;; extra heat/s per vent in reach

  (global $HEAT_MAX f32 (f32.const 100.0))
  ;; Where a tripped tower comes back. 40 rather than 99: the gap is what turns
  ;; overheating into a duty cycle you can plan around instead of a stutter.
  (global $HEAT_RESET f32 (f32.const 40.0))
  ;; Passive cooling, per second, and the number this whole mechanic turns on.
  ;;
  ;; The arithmetic a player is being asked to do: a pylon makes 50 heat/s
  ;; while firing, so on its own it trips after 2.4 seconds and then sits out
  ;; 6.7 while it drops back to 40 — a duty cycle of about a quarter. One vent
  ;; in reach takes the recovery to 2.1s and the time to trip to 4.8, which is
  ;; nearer three quarters. That is the trade: a vent is a gun you did not
  ;; build, and it is worth it if it roughly triples what the guns around it
  ;; deliver.
  ;;
  ;; Whether it *is* worth it turned out to depend on what it is cooling, and
  ;; that was the surprise. See the README: over the bench, a third of the
  ;; slots given to vents made no difference at all to a board of pylons, and
  ;; added three whole levels to a board that also had mortars on it. A vent
  ;; only pays when the tower it cools was worth keeping running.
  (global $HEAT_COOL f32 (f32.const 9.0))
  (global $TRACER_TIME f32 (f32.const 0.07))

  ;; ---- enemies ----
  (global $ENEMY_R f32 (f32.const 15.0))
  ;; A damper does not shoot. It heats every tower within reach as it walks
  ;; past, which is an attack on the one resource the player has been managing
  ;; all game — and the only enemy here whose counter is *where you built*,
  ;; not what you built.
  (global $DAMPER_RANGE f32 (f32.const 145.0))
  (global $DAMPER_HEAT f32 (f32.const 21.0))  ;; added per second, per damper

  ;; ---- the run ----
  (global $CORE_MAX f32 (f32.const 20.0))
  (global $START_SCRAP f32 (f32.const 95.0))
  ;; Level 1 is meant to be walkable. 95 scrap is four pylons, or three and a
  ;; vent, against six crawlers — enough that a first-time player who puts them
  ;; anywhere at all clears it, which is the bar this repository sets.
  (global $BUILD_TIME f32 (f32.const 14.0))
  (global $BUILD_TIME_MIN f32 (f32.const 8.0))
  (global $EARLY_RATE f32 (f32.const 3.0))    ;; scrap per second of build time skipped
  (global $WAVE_BOUNTY f32 (f32.const 24.0))
  (global $WAVE_BOUNTY_PER_LEVEL f32 (f32.const 2.0))

  ;; ---- scoring ----
  (global $SCORE_KILL f32 (f32.const 12.0))
  (global $SCORE_WAVE f32 (f32.const 150.0))
  (global $SCORE_INTACT f32 (f32.const 25.0))  ;; per point of core left, at the end

  (global $rng (mut i32) (i32.const 1145141919))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $scrap (mut f32) (f32.const 95.0))
  (global $core (mut f32) (f32.const 20.0))
  (global $level (mut i32) (i32.const 1))
  ;; 0 = building, 1 = the wave is walking
  (global $phase (mut i32) (i32.const 0))
  (global $phaseT (mut f32) (f32.const 14.0))
  (global $toSpawn (mut i32) (i32.const 0))
  (global $spawnT (mut f32) (f32.const 0.0))
  (global $pathLen (mut i32) (i32.const 0))

  ;; input, as reported by set_input each frame. `action` is edge-triggered by
  ;; the widget and consumed here on the frame it arrives, so a held mouse
  ;; button cannot build a row of towers.
  (global $inC (mut i32) (i32.const 0))
  (global $inR (mut i32) (i32.const 0))
  (global $inAction (mut i32) (i32.const 0))

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $builds (mut i32) (i32.const 0))
  (global $sells (mut i32) (i32.const 0))
  (global $shots (mut i32) (i32.const 0))
  (global $booms (mut i32) (i32.const 0))
  (global $kills (mut i32) (i32.const 0))
  (global $leaks (mut i32) (i32.const 0))
  (global $trips (mut i32) (i32.const 0))
  (global $waves (mut i32) (i32.const 0))
  (global $refused (mut i32) (i32.const 0))   ;; a build the rules would not allow

  ;; ---------------- helpers ----------------

  (func $cell_addr (param $c i32) (param $r i32) (result i32)
    (i32.add (global.get $GRID_OFF)
      (i32.mul (i32.add (i32.mul (local.get $r) (global.get $COLS)) (local.get $c))
               (global.get $CELL_STRIDE))))
  (func $tower_addr (param $i i32) (result i32)
    (i32.add (global.get $TOWERS_OFF) (i32.mul (local.get $i) (global.get $TOWER_STRIDE))))
  (func $enemy_addr (param $i i32) (result i32)
    (i32.add (global.get $ENEMIES_OFF) (i32.mul (local.get $i) (global.get $ENEMY_STRIDE))))
  (func $shell_addr (param $i i32) (result i32)
    (i32.add (global.get $SHELLS_OFF) (i32.mul (local.get $i) (global.get $SHELL_STRIDE))))
  (func $path_addr (param $i i32) (result i32)
    (i32.add (global.get $PATH_OFF) (i32.mul (local.get $i) (global.get $PATH_STRIDE))))

  (func $rand_u (result i32)
    (local $x i32)
    (local.set $x (global.get $rng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng (local.get $x))
    (i32.and (local.get $x) (i32.const 2147483647)))

  ;; Integer-domain, as in worm-chase: a remainder of a masked u32 cannot land
  ;; one past the end the way dividing by 2^32 in f32 can.
  (func $rand_below (param $n i32) (result i32)
    (i32.rem_u (call $rand_u) (local.get $n)))

  (func $rand_f32 (result f32)
    (f32.div (f32.convert_i32_u (call $rand_u)) (f32.const 2147483648.0)))

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

  (func $dist (param $ax f32) (param $ay f32) (param $bx f32) (param $by f32) (result f32)
    (local $dx f32) (local $dy f32)
    (local.set $dx (f32.sub (local.get $ax) (local.get $bx)))
    (local.set $dy (f32.sub (local.get $ay) (local.get $by)))
    (f32.sqrt (f32.add (f32.mul (local.get $dx) (local.get $dx))
                       (f32.mul (local.get $dy) (local.get $dy)))))

  (func $cell_cx (param $c i32) (result f32)
    (f32.mul (f32.add (f32.convert_i32_s (local.get $c)) (f32.const 0.5)) (global.get $CELL)))
  (func $cell_cy (param $r i32) (result f32)
    (f32.mul (f32.add (f32.convert_i32_s (local.get $r)) (f32.const 0.5)) (global.get $CELL)))

  (func $in_bounds (param $c i32) (param $r i32) (result i32)
    (i32.and
      (i32.and (i32.ge_s (local.get $c) (i32.const 0)) (i32.lt_s (local.get $c) (global.get $COLS)))
      (i32.and (i32.ge_s (local.get $r) (i32.const 0)) (i32.lt_s (local.get $r) (global.get $ROWS)))))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  (func $tower_cost (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
      (then (global.get $COST_MORTAR))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (global.get $COST_VENT))
        (else (global.get $COST_PYLON))))))

  ;; ---------------- the board ----------------

  ;; Lay a path from the left edge to a core on the right.
  ;;
  ;; The construction is what makes it safe rather than a check afterwards:
  ;; **columns are only ever entered left to right, and within a column the
  ;; path runs in one vertical direction.** A cell therefore cannot be visited
  ;; twice, the path cannot enclose anything, and it always terminates — none
  ;; of which needs a validity test, a retry loop, or a search.
  ;;
  ;; A random walk *with* a retry loop was the first version, and it did work;
  ;; it was replaced because "generate and check" is a shape that eventually
  ;; fails to terminate on some seed nobody has tried yet, and there is no way
  ;; to know which seed that is.
  (func $mark_path (param $c i32) (param $r i32) (param $n i32)
    (local $a i32)
    (local.set $a (call $cell_addr (local.get $c) (local.get $r)))
    (i32.store8 (local.get $a) (i32.const 1))
    (i32.store8 offset=2 (local.get $a) (local.get $n))
    (f32.store offset=0 (call $path_addr (local.get $n)) (call $cell_cx (local.get $c)))
    (f32.store offset=4 (call $path_addr (local.get $n)) (call $cell_cy (local.get $r))))

  (func $lay_path
    (local $c i32) (local $r i32) (local $dir i32) (local $vrun i32) (local $i i32)
    (local $n i32)

    (local.set $r (i32.add (i32.const 2) (call $rand_below (i32.sub (global.get $ROWS) (i32.const 4)))))
    (local.set $c (i32.const 0))
    (local.set $n (i32.const 0))
    (local.set $dir (if (result i32) (i32.eqz (call $rand_below (i32.const 2)))
                      (then (i32.const -1)) (else (i32.const 1))))

    ;; Exactly one append per cell. The first draft appended the cell it was
    ;; standing on at the top of the loop *and* again at the end of a vertical
    ;; run, which put two path entries on the same square — a zero-length
    ;; segment. $step_enemies divides the frame's travel by the segment length
    ;; to get progress, so a zero-length segment produced a progress of about a
    ;; thousand and walked the enemy off the end of the path in a single frame.
    ;; The symptom was not a crash: the wave simply arrived at the core the
    ;; instant it spawned, and no tower ever got a shot away.
    (block $done
      (loop $lp
        (call $mark_path (local.get $c) (local.get $r) (local.get $n))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))

        ;; Run vertically for a bit before stepping right again — at most two
        ;; squares, and usually in the same direction as last time.
        ;;
        ;; Both of those are legibility, not difficulty. Runs of up to three
        ;; with a fresh coin toss each column produced routes that were
        ;; perfectly valid and looked like a car park: a column going down
        ;; three and the next going up three puts eight track squares in a
        ;; two-by-four block, and a player cannot see a route in that. Keeping
        ;; the direction 3 times in 4 turns the same wander into long diagonals
        ;; you can follow, and it leaves more of the board buildable.
        (local.set $vrun (call $rand_below (i32.const 3)))
        (if (i32.eqz (call $rand_below (i32.const 4)))
          (then (local.set $dir (i32.sub (i32.const 0) (local.get $dir)))))
        (if (i32.eqz (local.get $dir)) (then (local.set $dir (i32.const 1))))
        (local.set $i (i32.const 0))
        (block $vdone
          (loop $vlp
            (br_if $vdone (i32.ge_s (local.get $i) (local.get $vrun)))
            ;; Stay one row clear of the top and bottom edges, so there is
            ;; always somewhere to build on both sides of the path.
            (br_if $vdone (i32.lt_s (i32.add (local.get $r) (local.get $dir)) (i32.const 1)))
            (br_if $vdone (i32.gt_s (i32.add (local.get $r) (local.get $dir))
                                    (i32.sub (global.get $ROWS) (i32.const 2))))
            (local.set $r (i32.add (local.get $r) (local.get $dir)))
            (call $mark_path (local.get $c) (local.get $r) (local.get $n))
            (local.set $n (i32.add (local.get $n) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $vlp)))

        (br_if $done (i32.ge_s (local.get $c) (i32.sub (global.get $COLS) (i32.const 1))))
        (br_if $done (i32.ge_s (local.get $n) (i32.sub (global.get $MAX_PATH) (i32.const 8))))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br $lp)))

    (global.set $pathLen (local.get $n))
    ;; The last cell is the core. It is drawn differently and it is the thing
    ;; the enemies are walking toward, so it gets its own kind rather than a
    ;; separate coordinate to keep in step with the path.
    (i32.store8 (call $cell_addr (local.get $c) (local.get $r)) (i32.const 2)))

  (func $clear_grid
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i)
                               (i32.mul (global.get $COLS) (global.get $ROWS))))
        (i32.store (i32.add (global.get $GRID_OFF)
                            (i32.mul (local.get $i) (global.get $CELL_STRIDE)))
                   (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- building ----------------

  ;; Can a tower of this kind go here, right now? Exported, because the widget
  ;; draws the cursor from it — so the preview and the rule are the same
  ;; sentence, and a cell that looks buildable is buildable.
  (func $can_build (export "can_build") (param $c i32) (param $r i32) (param $kind i32) (result i32)
    (local $a i32)
    (if (i32.eqz (call $in_bounds (local.get $c) (local.get $r))) (then (return (i32.const 0))))
    (local.set $a (call $cell_addr (local.get $c) (local.get $r)))
    (if (i32.ne (i32.load8_u (local.get $a)) (i32.const 0)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u offset=1 (local.get $a)) (i32.const 0)) (then (return (i32.const 0))))
    (if (f32.lt (global.get $scrap) (call $tower_cost (local.get $kind)))
      (then (return (i32.const 0))))
    (i32.const 1))

  (func $do_build (param $c i32) (param $r i32) (param $kind i32)
    (local $i i32) (local $a i32) (local $cell i32)
    (if (i32.eqz (call $can_build (local.get $c) (local.get $r) (local.get $kind)))
      (then (global.set $refused (i32.add (global.get $refused) (i32.const 1))) (return)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_TOWERS)))
        (local.set $a (call $tower_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (call $cell_cx (local.get $c)))
            (f32.store offset=4 (local.get $a) (call $cell_cy (local.get $r)))
            (f32.store offset=8 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=12 (local.get $a) (f32.const 0.0))
            (f32.store offset=16 (local.get $a) (f32.const 0.0))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (call $cell_cx (local.get $c)))
            (f32.store offset=28 (local.get $a) (f32.sub (call $cell_cy (local.get $r)) (f32.const 40.0)))
            (f32.store offset=32 (local.get $a) (f32.const 0.0))
            (f32.store offset=36 (local.get $a) (f32.const 0.0))
            (local.set $cell (call $cell_addr (local.get $c) (local.get $r)))
            (i32.store8 offset=1 (local.get $cell) (i32.add (local.get $i) (i32.const 1)))
            (global.set $scrap (f32.sub (global.get $scrap) (call $tower_cost (local.get $kind))))
            (global.set $builds (i32.add (global.get $builds) (i32.const 1)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    ;; pool full
    (global.set $refused (i32.add (global.get $refused) (i32.const 1))))

  (func $do_sell (param $c i32) (param $r i32)
    (local $cell i32) (local $t i32) (local $a i32)
    (if (i32.eqz (call $in_bounds (local.get $c) (local.get $r))) (then (return)))
    (local.set $cell (call $cell_addr (local.get $c) (local.get $r)))
    (local.set $t (i32.load8_u offset=1 (local.get $cell)))
    (if (i32.eqz (local.get $t))
      (then (global.set $refused (i32.add (global.get $refused) (i32.const 1))) (return)))
    (local.set $a (call $tower_addr (i32.sub (local.get $t) (i32.const 1))))
    (global.set $scrap (f32.add (global.get $scrap)
      (f32.mul (call $tower_cost (i32.trunc_f32_s (f32.load offset=8 (local.get $a))))
               (global.get $SELL_FRACTION))))
    (f32.store offset=20 (local.get $a) (f32.const 0.0))
    (i32.store8 offset=1 (local.get $cell) (i32.const 0))
    (global.set $sells (i32.add (global.get $sells) (i32.const 1))))

  ;; ---------------- enemies ----------------

  (func $enemy_hp (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
      (then (f32.const 16.0))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (f32.const 92.0))
        (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
          (then (f32.const 46.0))
          (else (f32.const 26.0))))))))

  ;; Speeds are set against the *walk*, not against each other. The generated
  ;; route is around 2,900px end to end; at the first draft's 62px/s a crawler
  ;; took 47 seconds to cross it, which made one wave nearly a minute of
  ;; watching and a losing run thirteen minutes long. 96 puts the crossing at
  ;; about 30s, and the rest are scaled from it.
  (func $enemy_speed (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
      (then (f32.const 172.0))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (f32.const 62.0))
        (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
          (then (f32.const 84.0))
          (else (f32.const 96.0))))))))

  ;; What reaching the core costs. A hauler is worth three crawlers of damage
  ;; as well as three of health, so letting one through is the mistake the run
  ;; actually turns on.
  (func $enemy_leak (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
      (then (f32.const 3.0))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
        (then (f32.const 2.0))
        (else (f32.const 1.0))))))

  ;; Bounties are deliberately mean. The first pass paid 5-11 a kill on top of
  ;; a wave bonus that grew with the level, and by wave 10 the bench was
  ;; sitting on hundreds of unspent scrap and by wave 20 on sixteen thousand —
  ;; at which point the board fills up, every strategy converges on "one of
  ;; everything, everywhere", and none of the choices this game is made of
  ;; mean anything any more. Money has to stay the thing you do not have.
  (func $enemy_bounty (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
      (then (f32.const 6.0))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 3))
        (then (f32.const 5.0))
        (else (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
          (then (f32.const 2.0))
          (else (f32.const 3.0))))))))

  ;; Which kinds this level may send. Crawlers alone at first; the sprinter is
  ;; the first thing that punishes a gap in coverage, the hauler the first that
  ;; punishes not having enough of it, and the damper — which attacks the heat
  ;; system rather than the towers — arrives once the player has had five
  ;; levels to build a heat plan worth attacking.
  (func $pick_kind (result i32)
    (local $roll i32)
    (if (i32.lt_s (global.get $level) (i32.const 2)) (then (return (i32.const 0))))
    (local.set $roll (call $rand_below (i32.const 100)))
    (if (i32.lt_s (global.get $level) (i32.const 4))
      (then (return (if (result i32) (i32.lt_s (local.get $roll) (i32.const 30))
                      (then (i32.const 1)) (else (i32.const 0))))))
    (if (i32.lt_s (global.get $level) (i32.const 6))
      (then (return
        (if (result i32) (i32.lt_s (local.get $roll) (i32.const 26))
          (then (i32.const 1))
          (else (if (result i32) (i32.lt_s (local.get $roll) (i32.const 44))
            (then (i32.const 2)) (else (i32.const 0))))))))
    (if (i32.lt_s (local.get $roll) (i32.const 24)) (then (return (i32.const 1))))
    (if (i32.lt_s (local.get $roll) (i32.const 44)) (then (return (i32.const 2))))
    (if (i32.lt_s (local.get $roll) (i32.const 60)) (then (return (i32.const 3))))
    (i32.const 0))

  ;; Enemies get tougher with the level as well as more numerous, but the
  ;; multiplier is deliberately gentle: this is a game about coverage, and
  ;; health inflation is the cheapest and least interesting way to ask for
  ;; more of it.
  (func $hp_scale (result f32)
    (f32.add (f32.const 1.0)
             (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                      (f32.const 0.26))))

  (func $wave_size (result i32)
    (call $clampi
      (i32.add (i32.const 5) (i32.mul (i32.sub (global.get $level) (i32.const 1)) (i32.const 2)))
      (i32.const 5) (i32.const 34)))

  (func $spawn_enemy
    (local $i i32) (local $a i32) (local $kind i32) (local $hp f32)
    (local.set $kind (call $pick_kind))
    (local.set $hp (f32.mul (call $enemy_hp (local.get $kind)) (call $hp_scale)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (f32.load offset=0 (call $path_addr (i32.const 0))))
            (f32.store offset=4 (local.get $a) (f32.load offset=4 (call $path_addr (i32.const 0))))
            (f32.store offset=8 (local.get $a) (local.get $hp))
            (f32.store offset=12 (local.get $a) (local.get $hp))
            (f32.store offset=16 (local.get $a) (f32.convert_i32_s (local.get $kind)))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (f32.const 0.0))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (f32.store offset=32 (local.get $a) (f32.const 0.0))
            (f32.store offset=36 (local.get $a) (f32.const 0.0))
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

  (func $kill_enemy (param $a i32)
    (f32.store offset=20 (local.get $a) (f32.const 0.0))
    (global.set $kills (i32.add (global.get $kills) (i32.const 1)))
    (global.set $scrap (f32.add (global.get $scrap)
      (call $enemy_bounty (i32.trunc_f32_s (f32.load offset=16 (local.get $a))))))
    (call $add_score (global.get $SCORE_KILL)))

  (func $hurt_enemy (param $a i32) (param $dmg f32)
    (f32.store offset=8 (local.get $a) (f32.sub (f32.load offset=8 (local.get $a)) (local.get $dmg)))
    (f32.store offset=32 (local.get $a) (f32.const 0.12))
    (if (f32.le (f32.load offset=8 (local.get $a)) (f32.const 0.0))
      (then (call $kill_enemy (local.get $a)))))

  (func $step_enemies (param $dt f32)
    (local $i i32) (local $a i32) (local $step i32) (local $t f32)
    (local $sp f32) (local $seg f32) (local $ax f32) (local $ay f32)
    (local $bx f32) (local $by f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (if (f32.gt (f32.load offset=32 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=32 (local.get $a)
                      (f32.sub (f32.load offset=32 (local.get $a)) (local.get $dt)))))

            (local.set $step (i32.trunc_f32_s (f32.load offset=24 (local.get $a))))
            (local.set $t (f32.load offset=28 (local.get $a)))
            (local.set $sp (call $enemy_speed (i32.trunc_f32_s (f32.load offset=16 (local.get $a)))))

            (block $walked
              (loop $wlp
                (br_if $walked (i32.ge_s (local.get $step)
                                         (i32.sub (global.get $pathLen) (i32.const 1))))
                (local.set $ax (f32.load offset=0 (call $path_addr (local.get $step))))
                (local.set $ay (f32.load offset=4 (call $path_addr (local.get $step))))
                (local.set $bx (f32.load offset=0 (call $path_addr
                  (i32.add (local.get $step) (i32.const 1)))))
                (local.set $by (f32.load offset=4 (call $path_addr
                  (i32.add (local.get $step) (i32.const 1)))))
                (local.set $seg (call $dist (local.get $ax) (local.get $ay)
                                            (local.get $bx) (local.get $by)))
                ;; A zero-length segment is stepped over rather than divided
                ;; by. $lay_path no longer produces one; this is here so that
                ;; if it ever does again the failure is an enemy skipping a
                ;; square rather than teleporting to the core.
                (if (f32.lt (local.get $seg) (f32.const 1.0))
                  (then
                    (local.set $step (i32.add (local.get $step) (i32.const 1)))
                    (br $wlp)))
                ;; Progress is a fraction of the *segment*, so the walk is at a
                ;; constant speed in pixels rather than in squares per second.
                (local.set $t (f32.add (local.get $t)
                  (f32.div (f32.mul (local.get $sp) (local.get $dt)) (local.get $seg))))
                (br_if $walked (f32.lt (local.get $t) (f32.const 1.0)))
                (local.set $t (f32.sub (local.get $t) (f32.const 1.0)))
                (local.set $step (i32.add (local.get $step) (i32.const 1)))
                (br $wlp)))

            (if (i32.ge_s (local.get $step) (i32.sub (global.get $pathLen) (i32.const 1)))
              (then
                ;; reached the core
                (global.set $core (f32.sub (global.get $core)
                  (call $enemy_leak (i32.trunc_f32_s (f32.load offset=16 (local.get $a))))))
                (global.set $leaks (i32.add (global.get $leaks) (i32.const 1)))
                (f32.store offset=20 (local.get $a) (f32.const 0.0))
                (if (f32.le (global.get $core) (f32.const 0.0))
                  (then
                    (global.set $core (f32.const 0.0))
                    (global.set $gameOver (i32.const 1)))))
              (else
                (local.set $ax (f32.load offset=0 (call $path_addr (local.get $step))))
                (local.set $ay (f32.load offset=4 (call $path_addr (local.get $step))))
                (local.set $bx (f32.load offset=0 (call $path_addr
                  (i32.add (local.get $step) (i32.const 1)))))
                (local.set $by (f32.load offset=4 (call $path_addr
                  (i32.add (local.get $step) (i32.const 1)))))
                (f32.store offset=0 (local.get $a)
                  (f32.add (local.get $ax) (f32.mul (f32.sub (local.get $bx) (local.get $ax))
                                                    (local.get $t))))
                (f32.store offset=4 (local.get $a)
                  (f32.add (local.get $ay) (f32.mul (f32.sub (local.get $by) (local.get $ay))
                                                    (local.get $t))))
                (f32.store offset=24 (local.get $a) (f32.convert_i32_s (local.get $step)))
                (f32.store offset=28 (local.get $a) (local.get $t))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- towers ----------------

  ;; The enemy furthest along the path that this tower can reach. "Furthest
  ;; along" rather than "nearest" is the whole of the targeting logic, and it
  ;; is the right default: the nearest enemy is by definition the one with the
  ;; most board left to walk, so shooting it wastes the towers behind you.
  (func $find_target (param $tx f32) (param $ty f32) (param $range f32) (result i32)
    (local $i i32) (local $a i32) (local $best i32) (local $bestProg f32) (local $prog f32)
    (local.set $best (i32.const -1))
    (local.set $bestProg (f32.const -1.0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (if (f32.le (call $dist (local.get $tx) (local.get $ty)
                                    (f32.load offset=0 (local.get $a))
                                    (f32.load offset=4 (local.get $a)))
                        (local.get $range))
              (then
                (local.set $prog (f32.add (f32.load offset=24 (local.get $a))
                                          (f32.load offset=28 (local.get $a))))
                (if (f32.gt (local.get $prog) (local.get $bestProg))
                  (then
                    (local.set $bestProg (local.get $prog))
                    (local.set $best (local.get $i))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $best))

  (func $spawn_shell (param $x f32) (param $y f32) (param $tx f32) (param $ty f32) (param $dmg f32)
    (local $i i32) (local $a i32) (local $d f32)
    (local.set $d (f32.max (call $dist (local.get $x) (local.get $y)
                                       (local.get $tx) (local.get $ty))
                           (f32.const 0.001)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_SHELLS)))
        (local.set $a (call $shell_addr (local.get $i)))
        (if (f32.eq (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            (f32.store offset=8 (local.get $a)
              (f32.mul (f32.div (f32.sub (local.get $tx) (local.get $x)) (local.get $d))
                       (global.get $SHELL_SPEED)))
            (f32.store offset=12 (local.get $a)
              (f32.mul (f32.div (f32.sub (local.get $ty) (local.get $y)) (local.get $d))
                       (global.get $SHELL_SPEED)))
            (f32.store offset=16 (local.get $a) (local.get $tx))
            (f32.store offset=20 (local.get $a) (local.get $ty))
            (f32.store offset=24 (local.get $a) (f32.const 1.0))
            (f32.store offset=28 (local.get $a) (local.get $dmg))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $detonate (param $x f32) (param $y f32) (param $dmg f32)
    (local $i i32) (local $a i32)
    (global.set $booms (i32.add (global.get $booms) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (if (f32.le (call $dist (local.get $x) (local.get $y)
                                    (f32.load offset=0 (local.get $a))
                                    (f32.load offset=4 (local.get $a)))
                        (global.get $MORTAR_SPLASH))
              (then (call $hurt_enemy (local.get $a) (local.get $dmg))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $step_shells (param $dt f32)
    (local $i i32) (local $a i32) (local $x f32) (local $y f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_SHELLS)))
        (local.set $a (call $shell_addr (local.get $i)))
        (if (f32.gt (f32.load offset=24 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $x (f32.add (f32.load offset=0 (local.get $a))
              (f32.mul (f32.load offset=8 (local.get $a)) (local.get $dt))))
            (local.set $y (f32.add (f32.load offset=4 (local.get $a))
              (f32.mul (f32.load offset=12 (local.get $a)) (local.get $dt))))
            (f32.store offset=0 (local.get $a) (local.get $x))
            (f32.store offset=4 (local.get $a) (local.get $y))
            ;; A shell lands where it was aimed, not on whoever it touches on
            ;; the way. That is what makes the splash a placement decision the
            ;; player can read rather than a lottery — and it is why a mortar
            ;; misses a sprinter, which is the sprinter's whole job.
            (if (f32.le (call $dist (local.get $x) (local.get $y)
                                    (f32.load offset=16 (local.get $a))
                                    (f32.load offset=20 (local.get $a)))
                        (f32.const 14.0))
              (then
                (f32.store offset=24 (local.get $a) (f32.const 0.0))
                (call $detonate (local.get $x) (local.get $y)
                                (f32.load offset=28 (local.get $a)))))
            (if (i32.or
                  (i32.or (f32.lt (local.get $x) (f32.const -40.0))
                          (f32.gt (local.get $x) (f32.add (global.get $WORLD_W) (f32.const 40.0))))
                  (i32.or (f32.lt (local.get $y) (f32.const -40.0))
                          (f32.gt (local.get $y) (f32.add (global.get $WORLD_H) (f32.const 40.0)))))
              (then (f32.store offset=24 (local.get $a) (f32.const 0.0))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Total extra cooling this tower gets from vents in reach of it.
  (func $vent_cooling (param $x f32) (param $y f32) (result f32)
    (local $i i32) (local $a i32) (local $sum f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_TOWERS)))
        (local.set $a (call $tower_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                     (f32.eq (f32.load offset=8 (local.get $a)) (f32.const 2.0)))
          (then
            (if (f32.le (call $dist (local.get $x) (local.get $y)
                                    (f32.load offset=0 (local.get $a))
                                    (f32.load offset=4 (local.get $a)))
                        (global.get $VENT_RANGE))
              (then (local.set $sum (f32.add (local.get $sum) (global.get $VENT_COOL)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $sum))

  ;; Heat added this second by every damper currently in range of this tower.
  (func $damper_heat (param $x f32) (param $y f32) (result f32)
    (local $i i32) (local $a i32) (local $sum f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
                     (f32.eq (f32.load offset=16 (local.get $a)) (f32.const 3.0)))
          (then
            (if (f32.le (call $dist (local.get $x) (local.get $y)
                                    (f32.load offset=0 (local.get $a))
                                    (f32.load offset=4 (local.get $a)))
                        (global.get $DAMPER_RANGE))
              (then (local.set $sum (f32.add (local.get $sum) (global.get $DAMPER_HEAT)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $sum))

  (func $step_towers (param $dt f32)
    (local $i i32) (local $a i32) (local $kind i32) (local $heat f32)
    (local $x f32) (local $y f32) (local $target i32) (local $e i32)
    (local $range f32) (local $cd f32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_TOWERS)))
        (local.set $a (call $tower_addr (local.get $i)))
        (if (f32.gt (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (local.set $x (f32.load offset=0 (local.get $a)))
            (local.set $y (f32.load offset=4 (local.get $a)))
            (local.set $kind (i32.trunc_f32_s (f32.load offset=8 (local.get $a))))
            (local.set $heat (f32.load offset=12 (local.get $a)))

            (if (f32.gt (f32.load offset=32 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=32 (local.get $a)
                      (f32.sub (f32.load offset=32 (local.get $a)) (local.get $dt)))))

            ;; A vent has no heat of its own and nothing to shoot. It exists
            ;; entirely for what $vent_cooling reads off it.
            (if (i32.ne (local.get $kind) (i32.const 2))
              (then
                (local.set $heat (f32.add (local.get $heat)
                  (f32.mul (call $damper_heat (local.get $x) (local.get $y)) (local.get $dt))))
                (local.set $heat (f32.sub (local.get $heat)
                  (f32.mul (f32.add (global.get $HEAT_COOL)
                                    (call $vent_cooling (local.get $x) (local.get $y)))
                           (local.get $dt))))
                (local.set $heat (call $clampf (local.get $heat)
                                       (f32.const 0.0) (global.get $HEAT_MAX)))

                (if (f32.ge (local.get $heat) (global.get $HEAT_MAX))
                  (then
                    (if (f32.eq (f32.load offset=36 (local.get $a)) (f32.const 0.0))
                      (then (global.set $trips (i32.add (global.get $trips) (i32.const 1)))))
                    (f32.store offset=36 (local.get $a) (f32.const 1.0))))
                (if (i32.and (f32.ne (f32.load offset=36 (local.get $a)) (f32.const 0.0))
                             (f32.le (local.get $heat) (global.get $HEAT_RESET)))
                  (then (f32.store offset=36 (local.get $a) (f32.const 0.0))))

                (local.set $cd (f32.sub (f32.load offset=16 (local.get $a)) (local.get $dt)))

                (if (i32.and (f32.eq (f32.load offset=36 (local.get $a)) (f32.const 0.0))
                             (f32.le (local.get $cd) (f32.const 0.0)))
                  (then
                    (local.set $range (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
                      (then (global.get $MORTAR_RANGE)) (else (global.get $PYLON_RANGE))))
                    (local.set $target (call $find_target (local.get $x) (local.get $y)
                                                          (local.get $range)))
                    (if (i32.ge_s (local.get $target) (i32.const 0))
                      (then
                        (local.set $e (call $enemy_addr (local.get $target)))
                        (f32.store offset=24 (local.get $a) (f32.load offset=0 (local.get $e)))
                        (f32.store offset=28 (local.get $a) (f32.load offset=4 (local.get $e)))
                        (global.set $shots (i32.add (global.get $shots) (i32.const 1)))
                        (if (i32.eq (local.get $kind) (i32.const 1))
                          (then
                            (call $spawn_shell (local.get $x) (local.get $y)
                                  (f32.load offset=0 (local.get $e))
                                  (f32.load offset=4 (local.get $e))
                                  (global.get $MORTAR_DMG))
                            (local.set $cd (global.get $MORTAR_RELOAD))
                            (local.set $heat (f32.add (local.get $heat) (global.get $MORTAR_HEAT))))
                          (else
                            ;; The pylon is hitscan: at 132px of range and a
                            ;; quarter-second reload a travelling bullet would
                            ;; spend most of its life in the air and miss a
                            ;; sprinter that had already left, which reads as
                            ;; the tower being broken rather than outrun.
                            (call $hurt_enemy (local.get $e) (global.get $PYLON_DMG))
                            (f32.store offset=32 (local.get $a) (global.get $TRACER_TIME))
                            (local.set $cd (global.get $PYLON_RELOAD))
                            (local.set $heat (f32.add (local.get $heat) (global.get $PYLON_HEAT)))))))))

                (f32.store offset=12 (local.get $a)
                  (call $clampf (local.get $heat) (f32.const 0.0) (global.get $HEAT_MAX)))
                (f32.store offset=16 (local.get $a) (f32.max (local.get $cd) (f32.const -1.0)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; ---------------- waves ----------------

  (func $build_time (result f32)
    (call $clampf
      (f32.sub (global.get $BUILD_TIME)
               (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                        (f32.const 0.5)))
      (global.get $BUILD_TIME_MIN) (global.get $BUILD_TIME)))

  ;; How far apart the wave arrives. This is the number that decides whether
  ;; heat is a mechanic or a decoration.
  ;;
  ;; At the first draft's 1.05s falling to 0.42s, a wave of forty was strung
  ;; out over sixteen seconds along a fifty-square route, so any one gun had
  ;; something in range about eight percent of the time and tripped roughly
  ;; once a minute. Overheating was real, measurable, and completely beside the
  ;; point — the bench could not tell a board of guns from a board of guns and
  ;; vents. A wave has to arrive as a *wave* for a gun to be asked to fire
  ;; continuously, and until it is asked, cooling it is worth nothing.
  (func $spawn_gap (result f32)
    (call $clampf
      (f32.sub (f32.const 0.55)
               (f32.mul (f32.convert_i32_s (global.get $level)) (f32.const 0.014)))
      (f32.const 0.18) (f32.const 0.55)))

  (func $start_wave
    (global.set $phase (i32.const 1))
    (global.set $toSpawn (call $wave_size))
    (global.set $spawnT (f32.const 0.35))
    (global.set $waves (i32.add (global.get $waves) (i32.const 1))))

  ;; Calling the wave in early pays the unspent build time out as scrap. The
  ;; build phase is otherwise a timer with nothing happening in it, which is
  ;; the dead-time case this repository goes looking for; making the wait
  ;; purchasable turns it into the only economic decision in the loop that is
  ;; not about where to put a box.
  (func $call_wave
    (if (i32.ne (global.get $phase) (i32.const 0)) (then (return)))
    (global.set $scrap (f32.add (global.get $scrap)
      (f32.mul (f32.max (global.get $phaseT) (f32.const 0.0)) (global.get $EARLY_RATE))))
    (call $add_score (f32.mul (f32.max (global.get $phaseT) (f32.const 0.0)) (f32.const 6.0)))
    (call $start_wave))

  (func $finish_wave
    (global.set $phase (i32.const 0))
    (global.set $scrap (f32.add (global.get $scrap)
      (f32.add (global.get $WAVE_BOUNTY)
               (f32.mul (f32.convert_i32_s (global.get $level))
                        (global.get $WAVE_BOUNTY_PER_LEVEL)))))
    (call $add_score (global.get $SCORE_WAVE))
    (global.set $level (i32.add (global.get $level) (i32.const 1)))
    (global.set $phaseT (call $build_time)))

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
    (global.set $rng (i32.const 1145141919))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $scrap (global.get $START_SCRAP))
    (global.set $core (global.get $CORE_MAX))
    (global.set $level (i32.const 1))
    (global.set $phase (i32.const 0))
    (global.set $phaseT (global.get $BUILD_TIME))
    (global.set $toSpawn (i32.const 0))
    (global.set $spawnT (f32.const 0.0))
    (global.set $inC (i32.const -1))
    (global.set $inR (i32.const -1))
    (global.set $inAction (i32.const 0))
    (global.set $builds (i32.const 0))
    (global.set $sells (i32.const 0))
    (global.set $shots (i32.const 0))
    (global.set $booms (i32.const 0))
    (global.set $kills (i32.const 0))
    (global.set $leaks (i32.const 0))
    (global.set $trips (i32.const 0))
    (global.set $waves (i32.const 0))
    (global.set $refused (i32.const 0))
    (call $clear_pool (global.get $TOWERS_OFF) (global.get $TOWER_STRIDE)
                      (global.get $MAX_TOWERS) (i32.const 20))
    (call $clear_pool (global.get $ENEMIES_OFF) (global.get $ENEMY_STRIDE)
                      (global.get $MAX_ENEMIES) (i32.const 20))
    (call $clear_pool (global.get $SHELLS_OFF) (global.get $SHELL_STRIDE)
                      (global.get $MAX_SHELLS) (i32.const 24))
    (call $clear_grid)
    (call $lay_path))

  ;; `action`: 0 none, 1 build pylon, 2 build mortar, 3 build vent, 4 sell,
  ;; 5 call the wave in early. Edge-triggered by the widget and consumed here,
  ;; so holding a mouse button cannot lay a row of towers.
  (func $set_input (export "set_input") (param $c i32) (param $r i32) (param $action i32)
    (global.set $inC (local.get $c))
    (global.set $inR (local.get $r))
    (global.set $inAction (local.get $action)))

  (func $step (export "step") (param $dt f32)
    (local $d f32) (local $act i32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.05)))

    ;; ---- consume the input ----
    (local.set $act (global.get $inAction))
    (global.set $inAction (i32.const 0))
    (if (i32.and (i32.ge_s (local.get $act) (i32.const 1)) (i32.le_s (local.get $act) (i32.const 3)))
      (then (call $do_build (global.get $inC) (global.get $inR)
                            (i32.sub (local.get $act) (i32.const 1)))))
    (if (i32.eq (local.get $act) (i32.const 4))
      (then (call $do_sell (global.get $inC) (global.get $inR))))
    (if (i32.eq (local.get $act) (i32.const 5)) (then (call $call_wave)))

    ;; ---- the phase clock ----
    (if (i32.eqz (global.get $phase))
      (then
        (global.set $phaseT (f32.sub (global.get $phaseT) (local.get $d)))
        (if (f32.le (global.get $phaseT) (f32.const 0.0)) (then (call $start_wave))))
      (else
        (if (i32.gt_s (global.get $toSpawn) (i32.const 0))
          (then
            (global.set $spawnT (f32.sub (global.get $spawnT) (local.get $d)))
            (if (f32.le (global.get $spawnT) (f32.const 0.0))
              (then
                (call $spawn_enemy)
                (global.set $toSpawn (i32.sub (global.get $toSpawn) (i32.const 1)))
                (global.set $spawnT (call $spawn_gap))))))))

    (call $step_enemies (local.get $d))
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))
    (call $step_towers (local.get $d))
    (call $step_shells (local.get $d))

    ;; The wave is over when there is nothing left to send and nothing left
    ;; walking. Checked after the pools have stepped, so the kill that emptied
    ;; the board ends the wave on the same frame rather than the next one.
    (if (i32.and (i32.eq (global.get $phase) (i32.const 1))
                 (i32.and (i32.le_s (global.get $toSpawn) (i32.const 0))
                          (i32.eqz (call $enemies_alive))))
      (then (call $finish_wave))))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32)
    ;; The core you finished with is worth points. Without it there is no
    ;; difference between surviving a wave by ten and surviving it by one,
    ;; and defending well would score exactly the same as defending barely.
    (f32.add (global.get $score) (f32.mul (global.get $core) (global.get $SCORE_INTACT))))
  (func $get_scrap (export "get_scrap") (result f32) (global.get $scrap))
  (func $get_core (export "get_core") (result f32) (global.get $core))
  (func $get_core_max (export "get_core_max") (result f32) (global.get $CORE_MAX))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_phase (export "get_phase") (result i32) (global.get $phase))
  (func $get_phase_t (export "get_phase_t") (result f32) (global.get $phaseT))
  (func $get_build_time (export "get_build_time") (result f32) (call $build_time))
  (func $get_to_spawn (export "get_to_spawn") (result i32) (global.get $toSpawn))
  (func $get_wave_size (export "get_wave_size") (result i32) (call $wave_size))
  (func $get_cols (export "get_cols") (result i32) (global.get $COLS))
  (func $get_rows (export "get_rows") (result i32) (global.get $ROWS))
  (func $get_cell (export "get_cell") (result f32) (global.get $CELL))
  (func $get_path_len (export "get_path_len") (result i32) (global.get $pathLen))
  (func $get_cost (export "get_cost") (param $kind i32) (result f32)
    (call $tower_cost (local.get $kind)))
  (func $get_range (export "get_range") (param $kind i32) (result f32)
    (if (result f32) (i32.eq (local.get $kind) (i32.const 1))
      (then (global.get $MORTAR_RANGE))
      (else (if (result f32) (i32.eq (local.get $kind) (i32.const 2))
        (then (global.get $VENT_RANGE))
        (else (global.get $PYLON_RANGE))))))
  (func $get_splash (export "get_splash") (result f32) (global.get $MORTAR_SPLASH))
  (func $get_heat_max (export "get_heat_max") (result f32) (global.get $HEAT_MAX))
  (func $get_early_rate (export "get_early_rate") (result f32) (global.get $EARLY_RATE))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_builds (export "get_builds") (result i32) (global.get $builds))
  (func $get_sells (export "get_sells") (result i32) (global.get $sells))
  (func $get_shots (export "get_shots") (result i32) (global.get $shots))
  (func $get_booms (export "get_booms") (result i32) (global.get $booms))
  (func $get_kills (export "get_kills") (result i32) (global.get $kills))
  (func $get_leaks (export "get_leaks") (result i32) (global.get $leaks))
  (func $get_trips (export "get_trips") (result i32) (global.get $trips))
  (func $get_waves (export "get_waves") (result i32) (global.get $waves))
  (func $get_refused (export "get_refused") (result i32) (global.get $refused))
)
