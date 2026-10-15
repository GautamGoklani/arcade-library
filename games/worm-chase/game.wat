(module
  ;; ============================================================
  ;; WORM CHASE — hand-written WebAssembly Text engine
  ;;
  ;; Self-contained: this engine shares no code with any other title in
  ;; games/. It follows the same *conventions* as grid-breaker/game.wat and
  ;; pixel-wave/game.wat (globals block at the top, fixed offsets in linear
  ;; memory, xorshift RNG, an init/set_input/step/get_* export surface) and
  ;; nothing else. Every constant and every routine below is its own.
  ;;
  ;; It also has no imports at all. The engines that steer in continuous space —
  ;; pixel-wave, grid-breaker, asteroid-miner — import sinf/cosf;
  ;; nothing here turns through an angle. A worm occupies a cell or it does
  ;; not, and every decision in the simulation is an integer comparison on a
  ;; 32x24 grid.
  ;;
  ;; JavaScript owns no game state. It forwards a direction, calls step(dt),
  ;; and reads the grid straight out of the memory below to draw it.
  ;; ============================================================

  (memory (export "memory") 1)

  ;; ================= MEMORY LAYOUT =================
  ;; grid    @0     : stride 4, COLS*ROWS = 32*24 = 768 cells
  ;;                  byte 0  state   0 = open, 1 = owned, 2 = trail
  ;;                  byte 1  hazard  0 or 1
  ;;                  byte 2  mark    flood-fill scratch, meaningless between steps
  ;;                  byte 3  epoch   which capture claimed it, 1..6, for tinting
  ;;                  cell (c,r) is at (r*COLS + c)*4
  ;;                  ends at 768*4 = 3072
  ;; queue   @3072  : stride 4, one i32 cell index per slot, 768 slots
  ;;                  the flood fill's BFS frontier. Sized for the whole grid
  ;;                  because that is the worst case and there is no allocator
  ;;                  to ask for more.
  ;;                  ends at 3072 + 3072 = 6144
  ;; chasers @6144  : stride 32, MAX_CHASERS = 8
  ;;                  cx, cy, pcx, pcy, dx, dy, active, kind    — all i32
  ;;                  kind 0 = chaser, 1 = hunter
  ;;                  ends at 6144 + 8*32 = 6400
  ;; capsules @6400 : stride 24, MAX_CAPSULES = 2
  ;;                  col, row, kind, life, active, (pad)       — all f32
  ;;                  kind 0 = freeze, 1 = surge; life counts down in seconds
  ;;                  ends at 6400 + 2*24 = 6448
  ;;
  ;; Everything scalar lives in a global instead of memory. Grid Breaker puts
  ;; its score at a fixed address because its renderer was already walking
  ;; memory for the tile grid; here the readers at the bottom are the only
  ;; consumer, and a global is one instruction to read.
  ;;
  ;; The field lists above, once more, in the form scripts/check-layout.mjs
  ;; reads. It fails if any line here disagrees with the prose, overflows
  ;; its stride, or disagrees with the FIELD table at the top of the widget
  ;; — so a field that moves has to move in all three places at once.
  ;; @fields cell   u8 CELL_STRIDE: state hazard mark epoch
  ;; @fields chaser i32 CHASER_STRIDE: cx cy pcx pcy dx dy active kind
  ;; @fields capsule f32 CAPSULE_STRIDE: col row kind life active pad
  ;; ===================================================

  (global $COLS i32 (i32.const 32))
  (global $ROWS i32 (i32.const 24))
  (global $CELLS i32 (i32.const 768))
  (global $GRID_OFF i32 (i32.const 0))
  (global $CELL_STRIDE i32 (i32.const 4))
  (global $QUEUE_OFF i32 (i32.const 3072))
  (global $CHASER_OFF i32 (i32.const 6144))
  (global $CHASER_STRIDE i32 (i32.const 32))
  (global $MAX_CHASERS i32 (i32.const 8))
  (global $CAPSULE_OFF i32 (i32.const 6400))
  (global $CAPSULE_STRIDE i32 (i32.const 24))
  (global $MAX_CAPSULES i32 (i32.const 2))

  ;; cell states
  (global $OPEN i32 (i32.const 0))
  (global $OWNED i32 (i32.const 1))
  (global $TRAIL i32 (i32.const 2))

  ;; The worm advances one whole cell per tick and the renderer interpolates
  ;; between the previous cell and the current one. Shortening the tick is the
  ;; only difficulty knob that matters: it cuts the time available to read the
  ;; board and commit to a turn.
  (global $TICK_BASE f32 (f32.const 0.140))
  (global $TICK_STEP f32 (f32.const 0.005))
  (global $TICK_MIN f32 (f32.const 0.072))
  ;; Chasers move on their own clock. At level 1 they are close to half the
  ;; worm's speed — slow enough that the first level teaches the loop-and-claim
  ;; rule instead of punishing it — and they reach the worm's own pace around
  ;; level 15. A chaser ticking in lockstep with the worm would be either
  ;; always catchable or never, depending on parity, which is why the two
  ;; clocks are separate numbers rather than one.
  ;; Mutable because the difficulty table writes them — see $apply_difficulty.
  ;; The initialisers are Normal's values, which is what makes a Normal run
  ;; identical to the engine that had no settings at all.
  (global $CHASE_BASE (mut f32) (f32.const 0.260))
  (global $CHASE_STEP (mut f32) (f32.const 0.011))
  (global $CHASE_MIN (mut f32) (f32.const 0.105))

  (global $START_LIVES (mut f32) (f32.const 5.0))

  ;; ---- difficulty ---------------------------------------------------------
  ;; Easy / Normal / Hard. The widget calls set_difficulty(d) and then init();
  ;; init() copies one column of this table into the globals below, and the rest
  ;; of the engine reads only those.
  ;;
  ;;                           easy      normal     hard
  ;;   starting lives            7          5         3
  ;;   chaser step (s)         0.34       0.26      0.20
  ;;   ... faster per level    0.009      0.011     0.014
  ;;   ... floor               0.14       0.105     0.085
  ;;   a new chaser every     3 levels   2 levels  1.5 levels
  ;;   hazards                 2 + 4/lvl  2 + 6/lvl 4 + 8/lvl
  ;;   land to clear a level  26% + 3/lvl 30% + 4  34% + 5
  ;;   ... capped at            60%        72%       80%
  ;;
  ;; The worm's own clock ($TICK_*) is *not* in the table. It is the feel of the
  ;; controls rather than the challenge, and a worm that crawls on Easy would be
  ;; a different game to learn on rather than an easier one.
  ;;
  ;; $difficulty is not reset by init: it is a choice about the next run, so a
  ;; restart has to carry it rather than wipe it — chapter 8's argument for $rng.
  (global $difficulty (mut i32) (i32.const 1))   ;; 0 easy, 1 normal, 2 hard
  ;; In *half*-levels, so Hard can sit between one and two: the count is
  ;; 1 + 2(level-1)/CHASER_EVERY, which for 6 and 4 is exactly the old
  ;; every-3 and every-2. Hard was 1 — a chaser every level — and benching a
  ;; pilot that plays properly found the wall that made: from level 6 (six
  ;; chasers) it cleared nothing and spent 25-75% of each level waiting at home
  ;; for a loop the pack could not reach first. See "Past level 1" in the README.
  (global $CHASER_EVERY (mut i32) (i32.const 4))
  (global $HAZ_BASE (mut i32) (i32.const 2))
  (global $HAZ_STEP (mut i32) (i32.const 6))
  (global $TARGET_BASE (mut i32) (i32.const 30))
  (global $TARGET_STEP (mut i32) (i32.const 4))
  (global $TARGET_CAP (mut i32) (i32.const 72))
  (global $HOME_HALF i32 (i32.const 2))     ;; starting block is 5x5 cells

  ;; Scoring.
  (global $SCORE_CELL f32 (f32.const 4.0))
  (global $SCORE_HAZARD f32 (f32.const 20.0))
  (global $SCORE_CHASER f32 (f32.const 150.0))

  ;; ---- the hunter ----
  ;; Every HUNTER_EVERY-th level one of the pack is a hunter. It is this game's
  ;; boss, and it asks the question the rest of the pack does not. A chaser
  ;; homes on the worm's head, so it is beaten by being quick. The hunter homes
  ;; on the trail — the trail cell nearest itself — so it is beaten by being
  ;; *short*: a long, lazy loop is exactly what it punishes, and a chaser's
  ;; answer (run for home) does not help when the trail it is heading for is
  ;; behind you. At home it roams like the rest.
  ;;
  ;; It is beaten the way this game beats anything: fence it in. That pays
  ;; SCORE_HUNTER rather than a chaser's 150. It lives in the chaser record's
  ;; last field, which used to be padding, so no layout moved; and the extra
  ;; slot it takes is placed from $rng like any chaser, which is why levels
  ;; without one replay the engine before it byte for byte.
  (global $HUNTER_EVERY i32 (i32.const 4))
  (global $SCORE_HUNTER f32 (f32.const 500.0))
  (global $tgtX (mut i32) (i32.const 0))
  (global $tgtY (mut i32) (i32.const 0))
  (global $SCORE_LEVEL f32 (f32.const 250.0))

  (global $rng (mut i32) (i32.const 2463534242))
  (global $level (mut i32) (i32.const 1))
  (global $gameOver (mut i32) (i32.const 0))
  (global $score (mut f32) (f32.const 0.0))
  (global $lives (mut f32) (f32.const 5.0))
  (global $owned (mut i32) (i32.const 0))
  (global $target (mut i32) (i32.const 0))  ;; cells needed to clear the level
  (global $epoch (mut i32) (i32.const 1))

  ;; worm
  (global $px (mut i32) (i32.const 0))
  (global $py (mut i32) (i32.const 0))
  (global $ppx (mut i32) (i32.const 0))
  (global $ppy (mut i32) (i32.const 0))
  (global $dirX (mut i32) (i32.const 0))
  (global $dirY (mut i32) (i32.const 0))
  (global $wantX (mut i32) (i32.const 0))
  (global $wantY (mut i32) (i32.const 0))
  (global $trailLen (mut i32) (i32.const 0))

  ;; clocks
  (global $acc (mut f32) (f32.const 0.0))
  (global $chaseAcc (mut f32) (f32.const 0.0))

  ;; flood-fill queue cursors
  (global $qh (mut i32) (i32.const 0))
  (global $qt (mut i32) (i32.const 0))

  ;; Event counters. JavaScript diffs these between frames to decide what to
  ;; play and what to shake — the engine never calls out, so a counter is the
  ;; whole notification channel. They only ever increase.
  (global $capCount (mut i32) (i32.const 0))
  (global $capCells (mut i32) (i32.const 0))  ;; cells taken by the last capture
  (global $deaths (mut i32) (i32.const 0))
  (global $kills (mut i32) (i32.const 0))
  (global $drops (mut i32) (i32.const 0))        ;; a capsule appeared
  (global $grabs (mut i32) (i32.const 0))        ;; a capsule was collected
  (global $hunters (mut i32) (i32.const 0))      ;; a hunter joined the pack
  (global $hunterKills (mut i32) (i32.const 0))  ;; a hunter fenced in

  ;; ---- power-ups ----------------------------------------------------------
  ;; Capsules appear on open ground on a timer, and last CAPSULE_LIFE seconds.
  ;; The worm takes one by driving over it — which means laying trail out to
  ;; it — or by **enclosing it**, which is how this game already pays for
  ;; hazards and chasers: whatever a capture seals off is yours. So a capsule
  ;; is a lure. It sits on the open board, where every loop is a risk, and it
  ;; asks the question the whole game asks: how far out are you willing to go?
  ;;
  ;;   freeze   the chasers' clock stops for FREEZE_TIME. A frozen chaser is
  ;;            still deadly to touch; it just stops closing on the trail.
  ;;   surge    the worm ticks SURGE_TICK times as long — faster — for
  ;;            SURGE_TIME, so a loop closes before the pack can reach it.
  ;;
  ;; Both are the same answer in two shapes: more worm-time per chaser-time.
  ;; Neither is a shield or a life, because this game's lives are not the thing
  ;; a good player runs short of; time outside territory is.
  ;;
  ;; **Capsules draw from their own random stream, $dropRng** — chapter 8's
  ;; argument, the same one Pixel Wave's drops made first. Everything else here
  ;; draws from $rng in an order the simulation fixes; placing a capsule from it
  ;; would shift every chaser's roam after the first drop, and a run that never
  ;; touched a capsule would still be a different run. On their own stream it is
  ;; not, and the check that this change is only what it says is that such a
  ;; run replays the previous engine byte for byte. See the README.
  (global $DROP_FIRST f32 (f32.const 6.0))       ;; seconds into a level
  (global $DROP_GAP_MIN f32 (f32.const 9.0))
  (global $DROP_GAP_MAX f32 (f32.const 15.0))
  (global $CAPSULE_LIFE f32 (f32.const 12.0))
  (global $FREEZE_SHARE f32 (f32.const 0.55))
  (global $FREEZE_TIME f32 (f32.const 4.0))
  (global $SURGE_TIME f32 (f32.const 5.0))
  (global $SURGE_TICK f32 (f32.const 0.6))
  (global $dropRng (mut i32) (i32.const 1234567891))
  (global $dropT (mut f32) (f32.const 6.0))
  (global $freezeT (mut f32) (f32.const 0.0))
  (global $surgeT (mut f32) (f32.const 0.0))

  ;; ---------------- helpers ----------------

  (func $cell_addr (param $c i32) (param $r i32) (result i32)
    (i32.add (global.get $GRID_OFF)
      (i32.mul (i32.add (i32.mul (local.get $r) (global.get $COLS)) (local.get $c))
               (global.get $CELL_STRIDE))))

  (func $idx_addr (param $i i32) (result i32)
    (i32.add (global.get $GRID_OFF) (i32.mul (local.get $i) (global.get $CELL_STRIDE))))

  (func $chaser_addr (param $i i32) (result i32)
    (i32.add (global.get $CHASER_OFF) (i32.mul (local.get $i) (global.get $CHASER_STRIDE))))

  (func $abs_i (param $v i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $v) (i32.const 0))
      (then (i32.sub (i32.const 0) (local.get $v)))
      (else (local.get $v))))

  (func $in_bounds (param $c i32) (param $r i32) (result i32)
    (i32.and
      (i32.and (i32.ge_s (local.get $c) (i32.const 0)) (i32.lt_s (local.get $c) (global.get $COLS)))
      (i32.and (i32.ge_s (local.get $r) (i32.const 0)) (i32.lt_s (local.get $r) (global.get $ROWS)))))

  (func $state_at (param $c i32) (param $r i32) (result i32)
    (i32.load8_u offset=0 (call $cell_addr (local.get $c) (local.get $r))))

  (func $hazard_at (param $c i32) (param $r i32) (result i32)
    (i32.load8_u offset=1 (call $cell_addr (local.get $c) (local.get $r))))

  ;; Manhattan distance from the middle of the board, where home is.
  (func $home_dist (param $c i32) (param $r i32) (result i32)
    (i32.add
      (call $abs_i (i32.sub (local.get $c) (i32.div_s (global.get $COLS) (i32.const 2))))
      (call $abs_i (i32.sub (local.get $r) (i32.div_s (global.get $ROWS) (i32.const 2))))))

  (func $rand_u (result i32)
    (local $x i32)
    (local.set $x (global.get $rng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng (local.get $x))
    (i32.and (local.get $x) (i32.const 2147483647)))

  (func $rand_below (param $n i32) (result i32)
    (i32.rem_u (call $rand_u) (local.get $n)))

  ;; The capsule stream: the same xorshift as $rand_u on its own state, so
  ;; placing a capsule never moves anything $rng decides. See "power-ups".
  (func $drop_u (result i32)
    (local $x i32)
    (local.set $x (global.get $dropRng))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $dropRng (local.get $x))
    (i32.and (local.get $x) (i32.const 2147483647)))

  (func $drop_frac (result f32)
    (f32.div (f32.convert_i32_u (call $drop_u)) (f32.const 2147483648.0)))

  (func $drop_gap (result f32)
    (f32.add (global.get $DROP_GAP_MIN)
      (f32.mul (call $drop_frac) (f32.sub (global.get $DROP_GAP_MAX) (global.get $DROP_GAP_MIN)))))

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

  (func $tick_len (result f32)
    (local $t f32)
    (local.set $t (call $clampf
      (f32.sub (global.get $TICK_BASE)
        (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                 (global.get $TICK_STEP)))
      (global.get $TICK_MIN) (global.get $TICK_BASE)))
    ;; a surge shortens the tick; behind a branch, not a multiply by 1.0, so a
    ;; run without one computes exactly what the engine before capsules did
    (if (f32.gt (global.get $surgeT) (f32.const 0.0))
      (then (local.set $t (f32.mul (local.get $t) (global.get $SURGE_TICK)))))
    (local.get $t))

  (func $chase_len (result f32)
    (call $clampf
      (f32.sub (global.get $CHASE_BASE)
        (f32.mul (f32.convert_i32_s (i32.sub (global.get $level) (i32.const 1)))
                 (global.get $CHASE_STEP)))
      (global.get $CHASE_MIN) (global.get $CHASE_BASE)))

  ;; How much of the board a level asks for, as a cell count: TARGET_BASE plus
  ;; TARGET_STEP a level, so Normal asks 34% on level 1 (it opened at 45%
  ;; before the opening was retuned) and climbs to 72%; past that the last few cells are a search problem
  ;; rather than a driving problem, and the level stops being fun well before
  ;; it stops being possible.
  (func $target_cells (result i32)
    (local $pct i32)
    (local.set $pct
      (call $clampi (i32.add (global.get $TARGET_BASE) (i32.mul (global.get $level) (global.get $TARGET_STEP)))
                    (global.get $TARGET_BASE) (global.get $TARGET_CAP)))
    (i32.div_s (i32.mul (global.get $CELLS) (local.get $pct)) (i32.const 100)))

  (func $add_score (param $n f32)
    (global.set $score (f32.add (global.get $score) (local.get $n))))

  ;; ---------------- level construction ----------------

  (func $clear_grid
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $CELLS)))
        (i32.store (call $idx_addr (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; The home block: a 5x5 patch of owned cells in the middle. It is the only
  ;; territory handed out for free, and because a capture can never take owned
  ;; cells away it is also the guarantee that $respawn always has somewhere to
  ;; put the worm.
  (func $build_home
    (local $c i32) (local $r i32) (local $cx i32) (local $cy i32) (local $a i32)
    (local.set $cx (i32.div_s (global.get $COLS) (i32.const 2)))
    (local.set $cy (i32.div_s (global.get $ROWS) (i32.const 2)))
    (local.set $r (i32.sub (local.get $cy) (global.get $HOME_HALF)))
    (block $rdone
      (loop $rlp
        (br_if $rdone (i32.gt_s (local.get $r) (i32.add (local.get $cy) (global.get $HOME_HALF))))
        (local.set $c (i32.sub (local.get $cx) (global.get $HOME_HALF)))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.gt_s (local.get $c) (i32.add (local.get $cx) (global.get $HOME_HALF))))
            (local.set $a (call $cell_addr (local.get $c) (local.get $r)))
            (i32.store8 offset=0 (local.get $a) (global.get $OWNED))
            (i32.store8 offset=3 (local.get $a) (i32.const 1))
            (global.set $owned (i32.add (global.get $owned) (i32.const 1)))
            (local.set $c (i32.add (local.get $c) (i32.const 1)))
            (br $clp)))
        (local.set $r (i32.add (local.get $r) (i32.const 1)))
        (br $rlp))))

  ;; Hazards scatter into open cells only, and never near the home block — a
  ;; spike touching the one safe patch would kill a worm that had not yet been
  ;; given a chance to steer.
  (func $scatter_hazards
    (local $n i32) (local $tries i32) (local $c i32) (local $r i32) (local $a i32)
    (local.set $n
      (call $clampi
        (i32.add (global.get $HAZ_BASE) (i32.mul (i32.sub (global.get $level) (i32.const 1)) (global.get $HAZ_STEP)))
        (global.get $HAZ_BASE) (i32.const 96)))
    (local.set $tries (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))
        ;; A bounded number of attempts. On a crowded late level the grid can
        ;; simply run out of room, and a loop that insisted would never return.
        (br_if $done (i32.gt_s (local.get $tries) (i32.const 4000)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        (local.set $c (call $rand_below (global.get $COLS)))
        (local.set $r (call $rand_below (global.get $ROWS)))
        (local.set $a (call $cell_addr (local.get $c) (local.get $r)))
        (if (i32.and
              (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $OPEN))
              (i32.and
                (i32.eqz (i32.load8_u offset=1 (local.get $a)))
                (i32.gt_s (call $home_dist (local.get $c) (local.get $r)) (i32.const 5))))
          (then
            (i32.store8 offset=1 (local.get $a) (i32.const 1))
            (local.set $n (i32.sub (local.get $n) (i32.const 1)))))
        (br $lp))))

  (func $spawn_chasers
    (local $i i32) (local $n i32) (local $a i32) (local $c i32) (local $r i32) (local $tries i32)
    (local $hunt i32)
    ;; One chaser on level 1, then one more every second level. Two at the
    ;; start read as a pack rather than a hazard, and the first level has to
    ;; teach the loop-and-claim rule before it starts punishing it.
    (local.set $n
      (call $clampi
        (i32.add (i32.const 1) (i32.div_s (i32.mul (i32.sub (global.get $level) (i32.const 1)) (i32.const 2)) (global.get $CHASER_EVERY)))
        (i32.const 1) (global.get $MAX_CHASERS)))
    ;; a hunter level adds one to the pack, and the last of it is the hunter
    (local.set $hunt (i32.eqz (i32.rem_s (global.get $level) (global.get $HUNTER_EVERY))))
    (if (local.get $hunt)
      (then
        (local.set $n (call $clampi (i32.add (local.get $n) (i32.const 1)) (i32.const 1) (global.get $MAX_CHASERS)))
        (global.set $hunters (i32.add (global.get $hunters) (i32.const 1)))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHASERS)))
        (local.set $a (call $chaser_addr (local.get $i)))
        (i32.store offset=24 (local.get $a) (i32.const 0))
        (i32.store offset=28 (local.get $a)
          (i32.and (local.get $hunt) (i32.eq (local.get $i) (i32.sub (local.get $n) (i32.const 1)))))
        (if (i32.lt_s (local.get $i) (local.get $n))
          (then
            (local.set $tries (i32.const 0))
            (block $placed
              (loop $plp
                (br_if $placed (i32.gt_s (local.get $tries) (i32.const 500)))
                (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
                (local.set $c (call $rand_below (global.get $COLS)))
                (local.set $r (call $rand_below (global.get $ROWS)))
                ;; open, unspiked, and well clear of home, so nothing is
                ;; already breathing down the worm's neck at the instant the
                ;; level starts.
                (br_if $plp (i32.ne (call $state_at (local.get $c) (local.get $r)) (global.get $OPEN)))
                (br_if $plp (i32.ne (call $hazard_at (local.get $c) (local.get $r)) (i32.const 0)))
                (br_if $plp (i32.lt_s (call $home_dist (local.get $c) (local.get $r)) (i32.const 9)))
                (i32.store offset=0 (local.get $a) (local.get $c))
                (i32.store offset=4 (local.get $a) (local.get $r))
                (i32.store offset=8 (local.get $a) (local.get $c))
                (i32.store offset=12 (local.get $a) (local.get $r))
                (i32.store offset=16 (local.get $a) (i32.const 0))
                (i32.store offset=20 (local.get $a) (i32.const 0))
                (i32.store offset=24 (local.get $a) (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Put the worm on an owned cell and stop it. A worm that resumed moving the
  ;; instant it respawned would be steered by whatever key was held when it
  ;; died, which is never the key the player wanted.
  (func $respawn
    (local $i i32) (local $seen i32)
    (local.set $i (call $rand_below (global.get $CELLS)))
    (local.set $seen (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $seen) (global.get $CELLS)))
        (if (i32.eq (i32.load8_u offset=0 (call $idx_addr (local.get $i))) (global.get $OWNED))
          (then
            (global.set $px (i32.rem_u (local.get $i) (global.get $COLS)))
            (global.set $py (i32.div_u (local.get $i) (global.get $COLS)))
            (br $done)))
        (local.set $i (i32.rem_u (i32.add (local.get $i) (i32.const 1)) (global.get $CELLS)))
        (local.set $seen (i32.add (local.get $seen) (i32.const 1)))
        (br $lp)))
    (global.set $ppx (global.get $px))
    (global.set $ppy (global.get $py))
    (global.set $dirX (i32.const 0))
    (global.set $dirY (i32.const 0))
    (global.set $wantX (i32.const 0))
    (global.set $wantY (i32.const 0))
    (global.set $acc (f32.const 0.0))
    (global.set $chaseAcc (f32.const 0.0)))

  ;; ---------------- capsules ----------------

  (func $capsule_addr (param $i i32) (result i32)
    (i32.add (global.get $CAPSULE_OFF) (i32.mul (local.get $i) (global.get $CAPSULE_STRIDE))))

  (func $clear_capsules
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)))
        (f32.store offset=16 (call $capsule_addr (local.get $i)) (f32.const 0.0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Which capsule, if any, sits on (c, r): its slot, or -1.
  (func $capsule_on (param $c i32) (param $r i32) (result i32)
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)))
        (local.set $a (call $capsule_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
              (i32.and (i32.eq (i32.trunc_f32_s (f32.load offset=0 (local.get $a))) (local.get $c))
                       (i32.eq (i32.trunc_f32_s (f32.load offset=4 (local.get $a))) (local.get $r))))
          (then (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const -1))

  ;; Open ground only: not owned (it would be free), not trail, not a hazard,
  ;; not under a chaser, not on another capsule, and at least four cells from
  ;; the head, so it is something to go out for rather than a step sideways.
  (func $spawn_capsule
    (local $i i32) (local $a i32) (local $c i32) (local $r i32) (local $tries i32)
    (local $j i32) (local $ca i32) (local $ok i32)
    (local.set $i (i32.const 0))
    (block $found
      (loop $lp
        (br_if $found (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)))
        (br_if $found (f32.eq (f32.load offset=16 (call $capsule_addr (local.get $i))) (f32.const 0.0)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (if (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)) (then (return)))
    (local.set $tries (i32.const 0))
    (block $placed
      (loop $plp
        (br_if $placed (i32.gt_s (local.get $tries) (i32.const 60)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        (local.set $c (i32.rem_u (call $drop_u) (global.get $COLS)))
        (local.set $r (i32.rem_u (call $drop_u) (global.get $ROWS)))
        (br_if $plp (i32.ne (call $state_at (local.get $c) (local.get $r)) (global.get $OPEN)))
        (br_if $plp (i32.ne (call $hazard_at (local.get $c) (local.get $r)) (i32.const 0)))
        (br_if $plp (i32.ge_s (call $capsule_on (local.get $c) (local.get $r)) (i32.const 0)))
        (br_if $plp (i32.lt_s
          (i32.add (call $abs_i (i32.sub (local.get $c) (global.get $px)))
                   (call $abs_i (i32.sub (local.get $r) (global.get $py))))
          (i32.const 4)))
        (local.set $ok (i32.const 1))
        (local.set $j (i32.const 0))
        (block $cdone
          (loop $clp
            (br_if $cdone (i32.ge_s (local.get $j) (global.get $MAX_CHASERS)))
            (local.set $ca (call $chaser_addr (local.get $j)))
            (if (i32.and (i32.ne (i32.load offset=24 (local.get $ca)) (i32.const 0))
                  (i32.and (i32.eq (i32.load offset=0 (local.get $ca)) (local.get $c))
                           (i32.eq (i32.load offset=4 (local.get $ca)) (local.get $r))))
              (then (local.set $ok (i32.const 0))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $clp)))
        (br_if $plp (i32.eqz (local.get $ok)))
        (local.set $a (call $capsule_addr (local.get $i)))
        (f32.store offset=0 (local.get $a) (f32.convert_i32_s (local.get $c)))
        (f32.store offset=4 (local.get $a) (f32.convert_i32_s (local.get $r)))
        (f32.store offset=8 (local.get $a)
          (if (result f32) (f32.lt (call $drop_frac) (global.get $FREEZE_SHARE))
            (then (f32.const 0.0)) (else (f32.const 1.0))))
        (f32.store offset=12 (local.get $a) (global.get $CAPSULE_LIFE))
        (f32.store offset=16 (local.get $a) (f32.const 1.0))
        (global.set $drops (i32.add (global.get $drops) (i32.const 1))))))

  ;; Taking a kind already in force restarts its clock rather than stacking it.
  (func $collect_capsule (param $i i32)
    (local $a i32)
    (local.set $a (call $capsule_addr (local.get $i)))
    (if (f32.eq (f32.load offset=8 (local.get $a)) (f32.const 0.0))
      (then (global.set $freezeT (global.get $FREEZE_TIME)))
      (else (global.set $surgeT (global.get $SURGE_TIME))))
    (f32.store offset=16 (local.get $a) (f32.const 0.0))
    (global.set $grabs (i32.add (global.get $grabs) (i32.const 1))))

  ;; After a capture: a capsule whose cell is owned now was just sealed off.
  (func $collect_enclosed
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)))
        (local.set $a (call $capsule_addr (local.get $i)))
        (if (i32.and (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
              (i32.eq (call $state_at (i32.trunc_f32_s (f32.load offset=0 (local.get $a)))
                                      (i32.trunc_f32_s (f32.load offset=4 (local.get $a))))
                      (global.get $OWNED)))
          (then (call $collect_capsule (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Clocks: capsules fade, effects run down, and the next drop comes due.
  (func $step_capsules (param $d f32)
    (local $i i32) (local $a i32)
    (global.set $freezeT (f32.max (f32.sub (global.get $freezeT) (local.get $d)) (f32.const 0.0)))
    (global.set $surgeT (f32.max (f32.sub (global.get $surgeT) (local.get $d)) (f32.const 0.0)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CAPSULES)))
        (local.set $a (call $capsule_addr (local.get $i)))
        (if (f32.gt (f32.load offset=16 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=12 (local.get $a) (f32.sub (f32.load offset=12 (local.get $a)) (local.get $d)))
            (if (f32.le (f32.load offset=12 (local.get $a)) (f32.const 0.0))
              (then (f32.store offset=16 (local.get $a) (f32.const 0.0))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (global.set $dropT (f32.sub (global.get $dropT) (local.get $d)))
    (if (f32.le (global.get $dropT) (f32.const 0.0))
      (then
        (call $spawn_capsule)
        (global.set $dropT (call $drop_gap)))))

  (func $build_level
    (global.set $owned (i32.const 0))
    (global.set $trailLen (i32.const 0))
    (global.set $epoch (i32.const 1))
    (call $clear_grid)
    (call $build_home)
    (call $scatter_hazards)
    (call $spawn_chasers)
    (global.set $target (call $target_cells))
    ;; a fresh board starts with no capsules and nothing in force
    (call $clear_capsules)
    (global.set $freezeT (f32.const 0.0))
    (global.set $surgeT (f32.const 0.0))
    (global.set $dropT (global.get $DROP_FIRST))
    (call $respawn))

  ;; Copy one column of the difficulty table into the globals the rest of the
  ;; engine reads. Called only from init, so a run never changes balance halfway
  ;; through. Normal restates the initialisers, because a restart after an Easy
  ;; or Hard run has to put them back.
  (func $apply_difficulty
    (if (i32.eqz (global.get $difficulty))
      (then   ;; easy
        (global.set $START_LIVES (f32.const 7.0))
        (global.set $CHASE_BASE (f32.const 0.340))
        (global.set $CHASE_STEP (f32.const 0.009))
        (global.set $CHASE_MIN (f32.const 0.140))
        (global.set $CHASER_EVERY (i32.const 6))
        (global.set $HAZ_BASE (i32.const 2))
        (global.set $HAZ_STEP (i32.const 4))
        (global.set $TARGET_BASE (i32.const 26))
        (global.set $TARGET_STEP (i32.const 3))
        (global.set $TARGET_CAP (i32.const 60)))
      (else
        (if (i32.eq (global.get $difficulty) (i32.const 2))
          (then   ;; hard
            (global.set $START_LIVES (f32.const 3.0))
            (global.set $CHASE_BASE (f32.const 0.200))
            (global.set $CHASE_STEP (f32.const 0.014))
            (global.set $CHASE_MIN (f32.const 0.085))
            (global.set $CHASER_EVERY (i32.const 3))
            (global.set $HAZ_BASE (i32.const 4))
            (global.set $HAZ_STEP (i32.const 8))
            (global.set $TARGET_BASE (i32.const 34))
            (global.set $TARGET_STEP (i32.const 5))
            (global.set $TARGET_CAP (i32.const 80)))
          (else   ;; normal
            (global.set $START_LIVES (f32.const 5.0))
            (global.set $CHASE_BASE (f32.const 0.260))
            (global.set $CHASE_STEP (f32.const 0.011))
            (global.set $CHASE_MIN (f32.const 0.105))
            (global.set $CHASER_EVERY (i32.const 4))
            (global.set $HAZ_BASE (i32.const 2))
            (global.set $HAZ_STEP (i32.const 6))
            (global.set $TARGET_BASE (i32.const 30))
            (global.set $TARGET_STEP (i32.const 4))
            (global.set $TARGET_CAP (i32.const 72)))))))

  ;; 0 easy, 1 normal, 2 hard; anything else is clamped rather than trusted, and
  ;; a JavaScript call with no argument arrives as 0. Takes effect at the next
  ;; init().
  (func $set_difficulty (export "set_difficulty") (param $d i32)
    (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.const 0))))
    (if (i32.gt_s (local.get $d) (i32.const 2)) (then (local.set $d (i32.const 2))))
    (global.set $difficulty (local.get $d)))
  (func $get_difficulty (export "get_difficulty") (result i32) (global.get $difficulty))

  (func $init (export "init")
    ;; first, because the lives and the level built below all read it
    (call $apply_difficulty)
    (global.set $rng (i32.const 2463534242))
    (global.set $level (i32.const 1))
    (global.set $gameOver (i32.const 0))
    (global.set $score (f32.const 0.0))
    (global.set $lives (global.get $START_LIVES))
    (global.set $capCount (i32.const 0))
    (global.set $capCells (i32.const 0))
    (global.set $deaths (i32.const 0))
    (global.set $kills (i32.const 0))
    (global.set $drops (i32.const 0))
    (global.set $grabs (i32.const 0))
    (global.set $hunters (i32.const 0))
    (global.set $hunterKills (i32.const 0))
    (call $build_level))

  ;; ---------------- input ----------------

  ;; The worm moves while a direction is held and stops when it is let go, so
  ;; set_input reports the direction *currently* being asked for, and (0, 0)
  ;; means "nothing held".
  ;;
  ;; A held direction is still stored as a request rather than written straight
  ;; onto the heading: that is what makes a turn typed mid-cell land on the cell
  ;; boundary instead of a frame later, and it is why holding two keys cannot
  ;; wedge the worm diagonally — there is one slot, and the last press wins.
  (func $set_input (export "set_input") (param $dx i32) (param $dy i32)
    ;; Let go: stop where you are. The worm's clock stops with it (see $step),
    ;; so releasing mid-cell does not bank progress toward the next tick.
    (if (i32.and (i32.eqz (local.get $dx)) (i32.eqz (local.get $dy)))
      (then
        (global.set $dirX (i32.const 0))
        (global.set $dirY (i32.const 0))
        (global.set $wantX (i32.const 0))
        (global.set $wantY (i32.const 0))
        (return)))
    (global.set $wantX (call $clampi (local.get $dx) (i32.const -1) (i32.const 1)))
    (global.set $wantY (call $clampi (local.get $dy) (i32.const -1) (i32.const 1)))
    ;; One axis at a time. A diagonal request resolves onto whichever axis the
    ;; worm is not already travelling along.
    (if (i32.and (i32.ne (global.get $wantX) (i32.const 0)) (i32.ne (global.get $wantY) (i32.const 0)))
      (then
        (if (i32.ne (global.get $dirX) (i32.const 0))
          (then (global.set $wantX (i32.const 0)))
          (else (global.set $wantY (i32.const 0))))))
    ;; Setting off from a standstill takes the heading immediately rather than
    ;; waiting for the next tick to read the request, so a press is felt on the
    ;; very next frame. Whether it *moves* on that frame is the accumulator's
    ;; business, and $step keeps that honest — see the note there about tapping.
    (if (i32.and (i32.eqz (global.get $dirX)) (i32.eqz (global.get $dirY)))
      (then
        (global.set $dirX (global.get $wantX))
        (global.set $dirY (global.get $wantY)))))

  ;; ---------------- capture ----------------

  (func $qpush (param $idx i32)
    (i32.store (i32.add (global.get $QUEUE_OFF) (i32.mul (global.get $qt) (i32.const 4)))
               (local.get $idx))
    (global.set $qt (i32.add (global.get $qt) (i32.const 1))))

  ;; Mark one cell as reachable from outside, if it is not owned and not
  ;; already marked, and queue it.
  (func $seed (param $c i32) (param $r i32)
    (local $a i32)
    (local.set $a (call $cell_addr (local.get $c) (local.get $r)))
    (if (i32.and
          (i32.ne (i32.load8_u offset=0 (local.get $a)) (global.get $OWNED))
          (i32.eqz (i32.load8_u offset=2 (local.get $a))))
      (then
        (i32.store8 offset=2 (local.get $a) (i32.const 1))
        (call $qpush (i32.add (i32.mul (local.get $r) (global.get $COLS)) (local.get $c))))))

  (func $visit (param $c i32) (param $r i32)
    (if (call $in_bounds (local.get $c) (local.get $r))
      (then (call $seed (local.get $c) (local.get $r)))))

  ;; Everything the outside can reach gets marked. What is left unmarked and
  ;; unowned is, by definition, sealed in by the loop just closed — that is
  ;; the whole rule of the game, and it is a breadth-first search rather than
  ;; any kind of polygon test.
  (func $flood_outside
    (local $i i32) (local $idx i32) (local $c i32) (local $r i32)
    (local.set $i (i32.const 0))
    (block $cleared
      (loop $clp
        (br_if $cleared (i32.ge_s (local.get $i) (global.get $CELLS)))
        (i32.store8 offset=2 (call $idx_addr (local.get $i)) (i32.const 0))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $clp)))

    (global.set $qh (i32.const 0))
    (global.set $qt (i32.const 0))

    (local.set $c (i32.const 0))
    (block $cdone
      (loop $clp2
        (br_if $cdone (i32.ge_s (local.get $c) (global.get $COLS)))
        (call $seed (local.get $c) (i32.const 0))
        (call $seed (local.get $c) (i32.sub (global.get $ROWS) (i32.const 1)))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br $clp2)))
    (local.set $r (i32.const 0))
    (block $rdone
      (loop $rlp2
        (br_if $rdone (i32.ge_s (local.get $r) (global.get $ROWS)))
        (call $seed (i32.const 0) (local.get $r))
        (call $seed (i32.sub (global.get $COLS) (i32.const 1)) (local.get $r))
        (local.set $r (i32.add (local.get $r) (i32.const 1)))
        (br $rlp2)))

    (block $bfs
      (loop $blp
        (br_if $bfs (i32.ge_s (global.get $qh) (global.get $qt)))
        (local.set $idx
          (i32.load (i32.add (global.get $QUEUE_OFF) (i32.mul (global.get $qh) (i32.const 4)))))
        (global.set $qh (i32.add (global.get $qh) (i32.const 1)))
        (local.set $c (i32.rem_u (local.get $idx) (global.get $COLS)))
        (local.set $r (i32.div_u (local.get $idx) (global.get $COLS)))
        (call $visit (i32.sub (local.get $c) (i32.const 1)) (local.get $r))
        (call $visit (i32.add (local.get $c) (i32.const 1)) (local.get $r))
        (call $visit (local.get $c) (i32.sub (local.get $r) (i32.const 1)))
        (call $visit (local.get $c) (i32.add (local.get $r) (i32.const 1)))
        (br $blp))))

  ;; Turn the closed trail into territory: the trail itself, plus everything
  ;; the flood fill could not reach. Hazards inside are cleared and chasers
  ;; inside are destroyed — enclosing something is the reward, and a spike
  ;; left inside your own territory would turn every later crossing of it into
  ;; a coin flip.
  (func $capture
    (local $i i32) (local $a i32) (local $gained i32) (local $j i32) (local $ca i32)
    (local.set $i (i32.const 0))
    (block $tdone
      (loop $tlp
        (br_if $tdone (i32.ge_s (local.get $i) (global.get $CELLS)))
        (local.set $a (call $idx_addr (local.get $i)))
        (if (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $TRAIL))
          (then (i32.store8 offset=0 (local.get $a) (global.get $OWNED))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $tlp)))

    (call $flood_outside)

    (global.set $epoch (i32.add (i32.rem_u (global.get $epoch) (i32.const 6)) (i32.const 1)))
    (local.set $gained (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $CELLS)))
        (local.set $a (call $idx_addr (local.get $i)))
        (if (i32.and
              (i32.ne (i32.load8_u offset=0 (local.get $a)) (global.get $OWNED))
              (i32.eqz (i32.load8_u offset=2 (local.get $a))))
          (then
            (i32.store8 offset=0 (local.get $a) (global.get $OWNED))
            (if (i32.load8_u offset=1 (local.get $a))
              (then
                (i32.store8 offset=1 (local.get $a) (i32.const 0))
                (call $add_score (global.get $SCORE_HAZARD))))))
        ;; A cell owned by this pass — trail or enclosed — still has epoch 0,
        ;; so stamping the ones that do is exactly the set that was just won.
        (if (i32.and (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $OWNED))
                     (i32.eqz (i32.load8_u offset=3 (local.get $a))))
          (then
            (i32.store8 offset=3 (local.get $a) (global.get $epoch))
            (local.set $gained (i32.add (local.get $gained) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))

    (global.set $owned (i32.add (global.get $owned) (local.get $gained)))
    (call $collect_enclosed)
    (global.set $capCells (local.get $gained))
    (global.set $capCount (i32.add (global.get $capCount) (i32.const 1)))
    (global.set $trailLen (i32.const 0))
    (call $add_score (f32.mul (f32.convert_i32_s (local.get $gained)) (global.get $SCORE_CELL)))

    ;; Chasers can never stand on owned territory, so any chaser whose cell is
    ;; owned now is one that was just fenced in.
    (local.set $j (i32.const 0))
    (block $cdone
      (loop $clp
        (br_if $cdone (i32.ge_s (local.get $j) (global.get $MAX_CHASERS)))
        (local.set $ca (call $chaser_addr (local.get $j)))
        (if (i32.ne (i32.load offset=24 (local.get $ca)) (i32.const 0))
          (then
            (if (i32.eq (call $state_at (i32.load offset=0 (local.get $ca))
                                        (i32.load offset=4 (local.get $ca)))
                        (global.get $OWNED))
              (then
                (i32.store offset=24 (local.get $ca) (i32.const 0))
                (global.set $kills (i32.add (global.get $kills) (i32.const 1)))
                (call $add_score (global.get $SCORE_CHASER))
                (if (i32.load offset=28 (local.get $ca))
                  (then
                    (global.set $hunterKills (i32.add (global.get $hunterKills) (i32.const 1)))
                    (call $add_score (f32.sub (global.get $SCORE_HUNTER) (global.get $SCORE_CHASER)))))))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $clp))))

  ;; ---------------- death ----------------

  (func $clear_trail
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $CELLS)))
        (local.set $a (call $idx_addr (local.get $i)))
        (if (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $TRAIL))
          (then (i32.store8 offset=0 (local.get $a) (global.get $OPEN))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (global.set $trailLen (i32.const 0)))

  ;; Throw every chaser back out to a random far cell. Without this a death
  ;; puts the worm back on owned ground with the pack still pressed against
  ;; the boundary it died on, and the next life is spent before the player has
  ;; touched a key — three deaths in four seconds, in the run that found it.
  (func $scatter_chasers
    (local $i i32) (local $a i32) (local $c i32) (local $r i32) (local $tries i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHASERS)))
        (local.set $a (call $chaser_addr (local.get $i)))
        (if (i32.ne (i32.load offset=24 (local.get $a)) (i32.const 0))
          (then
            (local.set $tries (i32.const 0))
            (block $placed
              (loop $plp
                (br_if $placed (i32.gt_s (local.get $tries) (i32.const 500)))
                (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
                (local.set $c (call $rand_below (global.get $COLS)))
                (local.set $r (call $rand_below (global.get $ROWS)))
                (br_if $plp (i32.eq (call $state_at (local.get $c) (local.get $r))
                                    (global.get $OWNED)))
                (br_if $plp (i32.lt_s
                  (i32.add (call $abs_i (i32.sub (local.get $c) (global.get $px)))
                           (call $abs_i (i32.sub (local.get $r) (global.get $py))))
                  (i32.const 11)))
                (i32.store offset=0 (local.get $a) (local.get $c))
                (i32.store offset=4 (local.get $a) (local.get $r))
                (i32.store offset=8 (local.get $a) (local.get $c))
                (i32.store offset=12 (local.get $a) (local.get $r))
                (i32.store offset=16 (local.get $a) (i32.const 0))
                (i32.store offset=20 (local.get $a) (i32.const 0))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $die
    (global.set $deaths (i32.add (global.get $deaths) (i32.const 1)))
    ;; a new life starts with nothing in force; capsules on the board stay
    (global.set $freezeT (f32.const 0.0))
    (global.set $surgeT (f32.const 0.0))
    (call $clear_trail)
    (global.set $lives (f32.sub (global.get $lives) (f32.const 1.0)))
    (if (f32.le (global.get $lives) (f32.const 0.0))
      (then
        (global.set $lives (f32.const 0.0))
        (global.set $gameOver (i32.const 1)))
      (else
        (call $respawn)
        (call $scatter_chasers))))

  (func $next_level
    (global.set $level (i32.add (global.get $level) (i32.const 1)))
    (call $add_score (global.get $SCORE_LEVEL))
    (call $build_level))

  ;; ---------------- simulation ----------------

  (func $tick_worm
    (local $nc i32) (local $nr i32) (local $a i32) (local $k i32)
    ;; Take the queued direction unless it is a straight reversal, which would
    ;; drive the head into the cell the worm just left.
    (if (i32.or (i32.ne (global.get $wantX) (i32.const 0)) (i32.ne (global.get $wantY) (i32.const 0)))
      (then
        (if (i32.eqz (i32.and
              (i32.eq (global.get $wantX) (i32.sub (i32.const 0) (global.get $dirX)))
              (i32.eq (global.get $wantY) (i32.sub (i32.const 0) (global.get $dirY)))))
          (then
            (global.set $dirX (global.get $wantX))
            (global.set $dirY (global.get $wantY))))))

    (if (i32.and (i32.eqz (global.get $dirX)) (i32.eqz (global.get $dirY))) (then (return)))

    (global.set $ppx (global.get $px))
    (global.set $ppy (global.get $py))
    (local.set $nc (i32.add (global.get $px) (global.get $dirX)))
    (local.set $nr (i32.add (global.get $py) (global.get $dirY)))

    (if (i32.eqz (call $in_bounds (local.get $nc) (local.get $nr)))
      (then (call $die) (return)))

    (local.set $a (call $cell_addr (local.get $nc) (local.get $nr)))
    (if (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $TRAIL))
      (then (call $die) (return)))
    (if (i32.load8_u offset=1 (local.get $a))
      (then (call $die) (return)))

    (global.set $px (local.get $nc))
    (global.set $py (local.get $nr))
    (local.set $k (call $capsule_on (local.get $nc) (local.get $nr)))
    (if (i32.ge_s (local.get $k) (i32.const 0)) (then (call $collect_capsule (local.get $k))))

    (if (i32.eq (i32.load8_u offset=0 (local.get $a)) (global.get $OWNED))
      (then
        (if (i32.gt_s (global.get $trailLen) (i32.const 0))
          (then (call $capture))))
      (else
        (i32.store8 offset=0 (local.get $a) (global.get $TRAIL))
        (global.set $trailLen (i32.add (global.get $trailLen) (i32.const 1))))))

  ;; Can a chaser stand here? Owned territory is closed to them, which is what
  ;; makes captured ground worth having and gives a cornered player somewhere
  ;; to run to.
  ;; The hunter's target: the trail cell nearest (c, r), into $tgtX/$tgtY. MVP
  ;; functions return one value, so the pair travels in two globals. With no
  ;; trail it falls back to the head, which only happens on the tick a loop
  ;; closes.
  (func $nearest_trail (param $c i32) (param $r i32)
    (local $i i32) (local $best i32) (local $d i32) (local $x i32) (local $y i32)
    (global.set $tgtX (global.get $px))
    (global.set $tgtY (global.get $py))
    (local.set $best (i32.const 100000))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $CELLS)))
        (if (i32.eq (i32.load8_u offset=0 (call $idx_addr (local.get $i))) (global.get $TRAIL))
          (then
            (local.set $x (i32.rem_u (local.get $i) (global.get $COLS)))
            (local.set $y (i32.div_u (local.get $i) (global.get $COLS)))
            (local.set $d (i32.add (call $abs_i (i32.sub (local.get $x) (local.get $c)))
                                   (call $abs_i (i32.sub (local.get $y) (local.get $r)))))
            (if (i32.lt_s (local.get $d) (local.get $best))
              (then
                (local.set $best (local.get $d))
                (global.set $tgtX (local.get $x))
                (global.set $tgtY (local.get $y))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $chaser_can (param $c i32) (param $r i32) (result i32)
    (if (i32.eqz (call $in_bounds (local.get $c) (local.get $r))) (then (return (i32.const 0))))
    (i32.ne (call $state_at (local.get $c) (local.get $r)) (global.get $OWNED)))

  (func $tick_chasers
    (local $i i32) (local $a i32) (local $c i32) (local $r i32)
    (local $dx i32) (local $dy i32) (local $sx i32) (local $sy i32) (local $tries i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHASERS)))
        (local.set $a (call $chaser_addr (local.get $i)))
        (if (i32.ne (i32.load offset=24 (local.get $a)) (i32.const 0))
          (then
            (local.set $c (i32.load offset=0 (local.get $a)))
            (local.set $r (i32.load offset=4 (local.get $a)))
            (i32.store offset=8 (local.get $a) (local.get $c))
            (i32.store offset=12 (local.get $a) (local.get $r))

            ;; Two behaviours, switched on whether the worm is out on a trail.
            ;;
            ;; While it is safe at home, chasers roam. They must not home in on
            ;; it: greedy chasers all converge on the nearest boundary cell to
            ;; the head, park there, and kill the worm on the tick it steps
            ;; out. That was the first build, and it made leaving home a coin
            ;; flip rather than a decision. Roaming also keeps them spread out,
            ;; because identical AI on identical targets stacks them into a
            ;; single blob.
            (if (i32.eqz (global.get $trailLen))
              (then
                (local.set $sx (i32.load offset=16 (local.get $a)))
                (local.set $sy (i32.load offset=20 (local.get $a)))
                ;; Newly spawned, or a 1-in-8 change of heart, so a roamer
                ;; does not simply bounce between two walls forever.
                (if (i32.or
                      (i32.and (i32.eqz (local.get $sx)) (i32.eqz (local.get $sy)))
                      (i32.eqz (call $rand_below (i32.const 8))))
                  (then
                    (local.set $sx (i32.sub (call $rand_below (i32.const 3)) (i32.const 1)))
                    (local.set $sy (if (result i32) (i32.ne (local.get $sx) (i32.const 0))
                      (then (i32.const 0))
                      (else (i32.sub (i32.mul (call $rand_below (i32.const 2)) (i32.const 2))
                                     (i32.const 1)))))))
                (local.set $tries (i32.const 0))
                (block $roamed
                  (loop $rlp
                    (br_if $roamed (call $chaser_can (i32.add (local.get $c) (local.get $sx))
                                                     (i32.add (local.get $r) (local.get $sy))))
                    (br_if $roamed (i32.gt_s (local.get $tries) (i32.const 8)))
                    (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
                    (local.set $sx (i32.sub (call $rand_below (i32.const 3)) (i32.const 1)))
                    (local.set $sy (if (result i32) (i32.ne (local.get $sx) (i32.const 0))
                      (then (i32.const 0))
                      (else (i32.sub (i32.mul (call $rand_below (i32.const 2)) (i32.const 2))
                                     (i32.const 1)))))
                    (br $rlp))))
              (else

            ;; Chase the head, one axis at a time, greedily. There is no
            ;; pathfinder here and there should not be: the board fills with
            ;; dead ends as territory grows, and a chaser that solved it
            ;; perfectly would make leaving home pointless.
            (local.set $dx (i32.sub (global.get $px) (local.get $c)))
            (local.set $dy (i32.sub (global.get $py) (local.get $r)))
            ;; the hunter goes for the trail, not the head
            (if (i32.load offset=28 (local.get $a))
              (then
                (call $nearest_trail (local.get $c) (local.get $r))
                (local.set $dx (i32.sub (global.get $tgtX) (local.get $c)))
                (local.set $dy (i32.sub (global.get $tgtY) (local.get $r)))))
            (local.set $sx (i32.const 0))
            (local.set $sy (i32.const 0))
            (if (i32.gt_s (call $abs_i (local.get $dx)) (call $abs_i (local.get $dy)))
              (then
                (local.set $sx (if (result i32) (i32.gt_s (local.get $dx) (i32.const 0))
                  (then (i32.const 1)) (else (i32.const -1)))))
              (else
                (if (i32.ne (local.get $dy) (i32.const 0))
                  (then
                    (local.set $sy (if (result i32) (i32.gt_s (local.get $dy) (i32.const 0))
                      (then (i32.const 1)) (else (i32.const -1)))))
                  (else
                    (if (i32.ne (local.get $dx) (i32.const 0))
                      (then
                        (local.set $sx (if (result i32) (i32.gt_s (local.get $dx) (i32.const 0))
                          (then (i32.const 1)) (else (i32.const -1))))))))))

            ;; Preferred axis blocked? Try the other one, then anything at all.
            (if (i32.eqz (call $chaser_can (i32.add (local.get $c) (local.get $sx))
                                           (i32.add (local.get $r) (local.get $sy))))
              (then
                (if (i32.ne (local.get $sx) (i32.const 0))
                  (then
                    (local.set $sx (i32.const 0))
                    (local.set $sy (if (result i32) (i32.ge_s (local.get $dy) (i32.const 0))
                      (then (i32.const 1)) (else (i32.const -1)))))
                  (else
                    (local.set $sy (i32.const 0))
                    (local.set $sx (if (result i32) (i32.ge_s (local.get $dx) (i32.const 0))
                      (then (i32.const 1)) (else (i32.const -1))))))
                (local.set $tries (i32.const 0))
                (block $picked
                  (loop $plp
                    (br_if $picked (call $chaser_can (i32.add (local.get $c) (local.get $sx))
                                                     (i32.add (local.get $r) (local.get $sy))))
                    (br_if $picked (i32.gt_s (local.get $tries) (i32.const 8)))
                    (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
                    (local.set $sx (i32.sub (call $rand_below (i32.const 3)) (i32.const 1)))
                    (local.set $sy (if (result i32) (i32.ne (local.get $sx) (i32.const 0))
                      (then (i32.const 0))
                      (else (i32.sub (i32.mul (call $rand_below (i32.const 2)) (i32.const 2))
                                     (i32.const 1)))))
                    (br $plp)))))))

            (if (call $chaser_can (i32.add (local.get $c) (local.get $sx))
                                  (i32.add (local.get $r) (local.get $sy)))
              (then
                (i32.store offset=0 (local.get $a) (i32.add (local.get $c) (local.get $sx)))
                (i32.store offset=4 (local.get $a) (i32.add (local.get $r) (local.get $sy)))
                (i32.store offset=16 (local.get $a) (local.get $sx))
                (i32.store offset=20 (local.get $a) (local.get $sy))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; A chaser kills by standing on the head or by cutting the trail. Both are
  ;; checked after every tick of either clock: a chaser crossing a trail cell
  ;; on the same tick the worm laid it is the most common way to lose, and it
  ;; would be invisible if it were only tested on the worm's clock.
  (func $check_chaser_hits (result i32)
    (local $i i32) (local $a i32) (local $c i32) (local $r i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHASERS)))
        (local.set $a (call $chaser_addr (local.get $i)))
        (if (i32.ne (i32.load offset=24 (local.get $a)) (i32.const 0))
          (then
            (local.set $c (i32.load offset=0 (local.get $a)))
            (local.set $r (i32.load offset=4 (local.get $a)))
            (if (i32.or
                  (i32.and (i32.eq (local.get $c) (global.get $px))
                           (i32.eq (local.get $r) (global.get $py)))
                  (i32.eq (call $state_at (local.get $c) (local.get $r)) (global.get $TRAIL)))
              (then (call $die) (return (i32.const 1))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))

  (func $step (export "step") (param $dt f32)
    (local $d f32) (local $guard i32)
    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))

    ;; A backgrounded tab hands back one enormous dt. Clamping it here means
    ;; returning to the tab costs a couple of ticks instead of replaying a
    ;; minute of movement into the nearest wall.
    (local.set $d (call $clampf (local.get $dt) (f32.const 0.0) (f32.const 0.1)))

    ;; The worm's clock keeps running while it stands still, but banks at most
    ;; one tick's worth. Both halves matter:
    ;;
    ;;   • capped, so letting go for ten seconds and pressing again is worth one
    ;;     step, not ten;
    ;;   • still running, so a player cannot out-run the tick rate by tapping.
    ;;     Zeroing it on release and refilling it on press would make a mashed
    ;;     key the fastest way to travel, which is the classic bug in every
    ;;     hold-to-move grid game.
    ;;
    ;; Together: pause as long as you like and set off instantly; tap as fast as
    ;; you like and move at exactly the same speed as holding.
    (if (i32.or (i32.ne (global.get $dirX) (i32.const 0)) (i32.ne (global.get $dirY) (i32.const 0)))
      (then
        (global.set $acc (f32.add (global.get $acc) (local.get $d)))
        (local.set $guard (i32.const 0))
        (block $wdone
          (loop $wlp
            (br_if $wdone (f32.lt (global.get $acc) (call $tick_len)))
            (br_if $wdone (i32.gt_s (local.get $guard) (i32.const 4)))
            (local.set $guard (i32.add (local.get $guard) (i32.const 1)))
            (global.set $acc (f32.sub (global.get $acc) (call $tick_len)))
            (call $tick_worm)
            (br_if $wdone (i32.ne (global.get $gameOver) (i32.const 0)))
            (br_if $wdone (call $check_chaser_hits))
            (br $wlp))))
      (else
        (global.set $acc
          (call $clampf (f32.add (global.get $acc) (local.get $d))
                        (f32.const 0.0) (call $tick_len)))))

    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))

    ;; The chasers' clock always runs. Standing still is a decision the player
    ;; is allowed to make, not a pause button — and a worm that stops halfway
    ;; round a loop should feel the pack closing on the trail it left behind.
    ;; Frozen, the chasers' clock does not run at all, so they resume from
    ;; exactly where they stopped rather than catching up on the lost time.
    (if (f32.le (global.get $freezeT) (f32.const 0.0))
      (then (global.set $chaseAcc (f32.add (global.get $chaseAcc) (local.get $d)))))
    (local.set $guard (i32.const 0))
    (block $cdone
      (loop $clp
        (br_if $cdone (f32.lt (global.get $chaseAcc) (call $chase_len)))
        (br_if $cdone (i32.gt_s (local.get $guard) (i32.const 4)))
        (local.set $guard (i32.add (local.get $guard) (i32.const 1)))
        (global.set $chaseAcc (f32.sub (global.get $chaseAcc) (call $chase_len)))
        (call $tick_chasers)
        (br_if $cdone (i32.ne (global.get $gameOver) (i32.const 0)))
        (br_if $cdone (call $check_chaser_hits))
        (br $clp)))

    (if (i32.ne (global.get $gameOver) (i32.const 0)) (then (return)))

    (call $step_capsules (local.get $d))

    (if (i32.ge_s (global.get $owned) (global.get $target))
      (then (call $next_level))))

  ;; ---------------- readers ----------------

  (func $get_score (export "get_score") (result f32) (global.get $score))
  (func $get_lives (export "get_lives") (result f32) (global.get $lives))
  (func $get_level (export "get_level") (result i32) (global.get $level))
  (func $get_owned (export "get_owned") (result i32) (global.get $owned))
  (func $get_target (export "get_target") (result i32) (global.get $target))
  (func $get_total (export "get_total") (result i32) (global.get $CELLS))
  (func $get_trail_len (export "get_trail_len") (result i32) (global.get $trailLen))
  (func $is_game_over (export "is_game_over") (result i32) (global.get $gameOver))
  (func $get_head_x (export "get_head_x") (result i32) (global.get $px))
  (func $get_head_y (export "get_head_y") (result i32) (global.get $py))
  (func $get_prev_x (export "get_prev_x") (result i32) (global.get $ppx))
  (func $get_prev_y (export "get_prev_y") (result i32) (global.get $ppy))
  (func $get_dir_x (export "get_dir_x") (result i32) (global.get $dirX))
  (func $get_dir_y (export "get_dir_y") (result i32) (global.get $dirY))
  ;; How far through the current tick the worm is, for the renderer to
  ;; interpolate with. Without it the worm moves at 8 fps on a 60 fps canvas.
  (func $get_tick_frac (export "get_tick_frac") (result f32)
    (call $clampf (f32.div (global.get $acc) (call $tick_len)) (f32.const 0.0) (f32.const 1.0)))
  (func $get_chase_frac (export "get_chase_frac") (result f32)
    (call $clampf (f32.div (global.get $chaseAcc) (call $chase_len)) (f32.const 0.0) (f32.const 1.0)))
  (func $get_capture_count (export "get_capture_count") (result i32) (global.get $capCount))
  (func $get_capture_cells (export "get_capture_cells") (result i32) (global.get $capCells))
  (func $get_deaths (export "get_deaths") (result i32) (global.get $deaths))
  (func $get_kills (export "get_kills") (result i32) (global.get $kills))
  (func $get_drops (export "get_drops") (result i32) (global.get $drops))
  (func $get_grabs (export "get_grabs") (result i32) (global.get $grabs))
  (func $get_hunters (export "get_hunters") (result i32) (global.get $hunters))
  (func $get_hunter_kills (export "get_hunter_kills") (result i32) (global.get $hunterKills))
  ;; seconds of each effect left, zero when not in force
  (func $get_freeze_t (export "get_freeze_t") (result f32) (global.get $freezeT))
  (func $get_surge_t (export "get_surge_t") (result f32) (global.get $surgeT))
)
