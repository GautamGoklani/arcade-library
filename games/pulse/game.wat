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
  ;;                  byte 3  lead   seg + 1 of the melody note on this step, or 0
  ;;                  ends at 64
  ;; enemies  @64   : stride 32, MAX_ENEMIES = 32
  ;;                  seg, depth, hp, maxHp, kind, active, flash, hopT
  ;;                  ends at 64 + 32*32 = 1088
  ;; bolts    @1088 : stride 24, MAX_BOLTS = 24
  ;;                  seg, depth, dmg, active, onBeat, speed
  ;;                  ends at 1088 + 24*24 = 1664
  ;; chimes   @1664 : stride 12, MAX_CHIMES = 8
  ;;                  seg, depth, active
  ;;                  ends at 1664 + 8*12 = 1760
  ;;
  ;; enemy kinds: 0 = drone, 1 = skipper, 2 = hulk, 3 = mirror, 4 = conductor
  ;; (the conductor is never written into the bar plan; it is the boss, and the
  ;; plan's kinds stay 0-3)
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
  ;;
  ;; The field lists above, once more, in the form scripts/check-layout.mjs
  ;; reads. It fails if any line here disagrees with the prose, overflows
  ;; its stride, or disagrees with the FIELD table at the top of the widget
  ;; — so a field that moves has to move in all three places at once.
  ;; @fields bar   u8 BAR_STRIDE: seg kind spent lead
  ;; @fields enemy f32 ENEMY_STRIDE: seg depth hp maxHp kind active flash hopT
  ;; @fields bolt  f32 BOLT_STRIDE: seg depth dmg active onBeat speed
  ;; @fields chime f32 CHIME_STRIDE: seg depth active
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
  ;; The lead line's chimes have a pool of their own. They lived in the enemy
  ;; pool at first, and the bench caught it: a chime holding a slot moved where
  ;; the next enemy landed, which changed which of two overlapping enemies a
  ;; bolt found first, and the bass line's kills came out one different by
  ;; level 2. A pool of their own leaves the enemy song bit for bit alone.
  ;; Eight is plenty: a chime lives four steps and a bar holds at most three.
  (global $CHIMES_OFF i32 (i32.const 1664))
  (global $CHIME_STRIDE i32 (i32.const 12))
  (global $MAX_CHIMES i32 (i32.const 8))

  ;; Twelve segments. Not sixteen: the player has to be able to cross the tube
  ;; inside a bar, and at the move rate below twelve is about three quarters of
  ;; a bar the long way round. Not eight: with eight, a bar of four spawns can
  ;; cover half the ring and there is no reading to do.
  (global $SEGMENTS i32 (i32.const 12))

  ;; ---- the song ----
  ;; Tempo. It rises with groove rather than with the level, which is the whole
  ;; reward loop in one line: play in time and the track speeds up.
  ;; Mutable because the difficulty table writes them — see $apply_difficulty.
  ;; The initialisers are Normal's values, which is what makes a Normal run
  ;; identical to the engine that had no settings at all.
  (global $BPM_BASE (mut f32) (f32.const 96.0))
  (global $BPM_GROOVE (mut f32) (f32.const 54.0))    ;; added at full groove
  (global $BPM_PER_LEVEL f32 (f32.const 2.2))
  (global $BPM_CAP (mut f32) (f32.const 168.0))
  ;; How close to an eighth-note boundary a shot has to be. The window is a
  ;; fixed number of *seconds*, not a fraction of a beat, so it is the same in
  ;; feel at every tempo: a player timing deliberately needs the same precision
  ;; at 96bpm as at 168.
  ;;
  ;; This comment used to go on to say that made it "strictly harder as the
  ;; track speeds up". The difficulty bench measured the opposite, for the case
  ;; that matters: a fixed window is a *larger* share of a shorter beat, so the
  ;; faster the track the more of a masher's shots land in it by accident — 35%
  ;; at Easy's tempos, 39% at Normal's, 52% at Hard's. What gets harder as the
  ;; track speeds up is everything else (more arrivals a second, less time to
  ;; cross the ring), not the window. That 52% is why Hard now narrows it — see
  ;; the difficulty table, and "Difficulty" in the README.
  ;;
  ;; 0.058 rather than the first draft's 0.075 because of what the bench found
  ;; about mashing. Two windows per eighth note at 96bpm is 2*0.075/0.3125,
  ;; which is 48% of the bar spent inside one, and a pilot that simply fired as
  ;; fast as it was allowed to landed 70% of its shots on the beat by accident.
  ;; A rhythm mechanic that pays out to a button-masher is a decoration. At
  ;; 0.058 the accidental rate is 37% and the metronome still clears it easily.
  (global $BEAT_WINDOW (mut f32) (f32.const 0.058))   ;; mutable: Hard narrows it

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
  (global $LEAK_COST (mut f32) (f32.const 20.0))
  ;; A bar in which nothing reached the rim pays shield back. It is the only
  ;; repair there is, and it is deliberately a *bar* rather than a kill: the
  ;; unit of play here is the pattern, so the unit of reward is too.
  (global $PERFECT_BAR_HEAL f32 (f32.const 12.0))

  ;; ---- the lead line ----
  ;; The second instrument. Until now the song had one line — every spawn is
  ;; a bass note on its segment — and the melody was the player's own shots.
  ;; From level 2 each bar also carries a short **lead** phrase on steps the
  ;; bass left empty, and every lead note releases a **chime** up its segment.
  ;; A chime climbs a quarter of the tube a step, so it reaches the rim exactly
  ;; one beat after its note sounded. Be in that segment when it lands and it
  ;; is caught: groove, and score at the multiplier.
  ;;
  ;; TASKS.md ruled power-ups out for this title because a faster gun is a way
  ;; to stop listening. A chime is the opposite: it is only catchable by
  ;; listening to a second line and moving to it on time, while the first line
  ;; is still asking you to shoot. Missing one costs nothing. And catching one
  ;; is a double-edged prize, because groove is what raises the tempo.
  ;;
  ;; The phrase is written from a random stream of its own, $rng2, so the bass
  ;; line — every spawn, every kind, every segment — is exactly the song the
  ;; engine without a lead line played. Chimes live in a pool of their own
  ;; (see $CHIMES_OFF), cannot be shot and never leak.
  (global $LEAD_FROM_LEVEL i32 (i32.const 2))
  (global $LEAD_NOTES i32 (i32.const 2))        ;; per bar, +1 from level 5
  (global $CHIME_RISE f32 (f32.const 0.25))     ;; depth per step: rim in one beat
  (global $CHIME_GROOVE f32 (f32.const 0.06))
  (global $SCORE_CHIME f32 (f32.const 40.0))

  ;; ---- the drop ----
  ;; Every fourth level opens on a **drop**, and the drop has a boss in it:
  ;; the **conductor**. The bar before is written empty — the build-up, a bar
  ;; of nothing but the beat, which is the one warning a song can give that
  ;; everyone already knows how to hear. Then the conductor appears inside the
  ;; tube, and for the next four bars it plays them: every spawn comes out of
  ;; its segment, and it moves there on the note. The bar ring the HUD already
  ;; draws is therefore its route — the plan says where it will be on every
  ;; step, so a player reading the ring knows where to wait.
  ;;
  ;; It is hurt only by shots on the beat, as the mirror is, and for the same
  ;; reason: it is the test of the one thing the game is about. Break it inside
  ;; the four bars and it pays a large score and shield back. Survive to the
  ;; end of the drop with it still standing and it leaves the way a drop ends —
  ;; with a hit, one and a half leaks' worth to the shield.
  (global $DROP_EVERY i32 (i32.const 4))
  (global $DROP_BARS i32 (i32.const 4))
  ;;
  ;; **The beat alone was not enough, so it is hurt by the groove as well.** An
  ;; on-beat shot does its 3 times the multiplier, 1 to 5. The first draft took
  ;; plain on-beat damage, and the bench found a button-masher landing 4.9
  ;; on-beat hits a drop against the metronome's 5.8. The notes it plays come
  ;; out of its own segment and soak up bolts, so the limit was reaching it,
  ;; not timing, and a masher's accidental 40% reached it nearly as often.
  ;; Groove is the one number here that only playing in time raises. A
  ;; masher's is near zero, so at 45 the masher broke none of twelve while the
  ;; metronome broke ten and a player with a normal 35ms spread broke eight.
  ;; (30 let the masher through twice; 60 left the human at three.)
  (global $CONDUCTOR_HP f32 (f32.const 45.0))
  (global $CONDUCTOR_DEPTH f32 (f32.const 0.3))
  (global $SLAM_MUL f32 (f32.const 1.5))       ;; times $LEAK_COST
  (global $DROP_HEAL f32 (f32.const 25.0))
  (global $SCORE_CONDUCTOR f32 (f32.const 600.0))

  ;; ---- scoring ----
  (global $SCORE_KILL f32 (f32.const 25.0))
  (global $SCORE_BEAT_KILL f32 (f32.const 60.0))
  (global $SCORE_PERFECT_BAR f32 (f32.const 200.0))

  ;; ---- difficulty ---------------------------------------------------------
  ;; Easy / Normal / Hard. The widget calls set_difficulty(d) and then init();
  ;; init() copies one column of this table into the globals below, and the rest
  ;; of the engine reads only those.
  ;;
  ;;                              easy       normal      hard
  ;;   tempo floor                 84          96         108
  ;;   tempo added at full groove  40          54          62
  ;;   tempo cap                  150         168         184
  ;;   spawns in a bar, level 1     2           3           3
  ;;   ... one more every        2 levels    2 levels    1 level
  ;;   ... capped at                9          11          12
  ;;   shield lost to a leak       14          20          26
  ;;   beat window               58ms        58ms        48ms
  ;;
  ;; The two knobs TASKS.md named are **the tempo floor and how full each bar
  ;; is**, and both belong to the sequencer, which is the point: in this title
  ;; the difficulty is written into the music. A setting is a different
  ;; arrangement of the same song — slower and sparser, or faster and busier —
  ;; rather than a multiplier applied to a game the music merely accompanies.
  ;;
  ;; The groove row is the one the named knobs would have missed. Groove raises
  ;; the tempo, so a player who is in time is asking for a faster track — the
  ;; README's finding 1 is that the metronome dies *before* the masher, because
  ;; playing well is what speeds the song up. A lower floor alone would not
  ;; change that: on Easy a good player would still be carried up to 150 by
  ;; their own groove inside a minute. So Easy also takes less tempo from
  ;; groove, which keeps the reward for playing in time from burying the
  ;; player who has only just found it. Hard takes more.
  ;;
  ;; **Hard opens on Normal's bar, and fills it twice as fast.** The first
  ;; draft of this table gave Hard four spawns from the first bar, and the
  ;; bench's loose pilot — the one that aims at the beat and mostly misses — died
  ;; at level 2 in thirty-one seconds. Every other title's Hard lets that pilot
  ;; reach level 3, and CLAUDE.md is plain that level 1 must be gentle and the
  ;; difficulty must come from the level number. Cutting the leak cost instead
  ;; changed nothing (22 against 26: the same 31s), because it was the opening
  ;; density that was killing it, not the shield. Dropping Hard's base to three
  ;; fixed the opening but made its bars identical to Normal's for the whole
  ;; run, since the cap of twelve is never reached — the knob would have stopped
  ;; doing anything. So the table carries the rate, $BAR_EVERY, rather than
  ;; only the start: Hard's level 1 is Normal's, and by level 6 it holds two
  ;; more spawns a bar.
  ;;
  ;; The leak cost is this game's lives, and every other title's table moves
  ;; that number. The shield *maximum* stays at 100, because the HUD draws it as
  ;; a fraction and a larger number would be the same bar.
  ;;
  ;; **$BEAT_WINDOW moves in one direction only.** It is the knob a rhythm
  ;; game usually reaches for first, and Easy does not touch it. The note
  ;; above it records why: at 75ms a pilot that simply fired as fast as it
  ;; could landed 70% of its shots on the beat by accident, and a rhythm
  ;; mechanic that pays a button-masher is a decoration. Widening it on Easy
  ;; would make Easy exactly that — TASKS.md ruled out power-ups for this title
  ;; for the same reason, and a wider window is the same thing with a kinder
  ;; name.
  ;;
  ;; Hard narrows it, for the mirror-image reason. The window is fixed in
  ;; seconds, so at Hard's faster tempos it is a larger share of each beat, and
  ;; the first version of this table — 58ms on every column — let a masher land
  ;; 52% of its shots on the beat on Hard against 39% on Normal. Precision was
  ;; worth least on the setting that should ask the most of it. Narrowing it
  ;; restores the ratio Normal has, and the sweep is what picked 48:
  ;;
  ;;                      masher on beat   a sigma-35ms player's score
  ;;                                        per second over a masher's
  ;;   Normal, 58ms            39%               4.1x
  ;;   Hard,   58ms            52%               3.6x
  ;;   Hard,   52ms            43%               3.7x
  ;;   Hard,   48ms            36%               4.2x
  ;;   Hard,   44ms            33%               3.4x
  ;;
  ;; 52 did not go far enough. At 44 the masher barely moves but the human
  ;; pilot — aiming at every eighth and missing by a normal spread of 35ms —
  ;; loses more than the masher does, so the window starts taxing honest
  ;; timing rather than mashing. 48 is the one value that puts both numbers back
  ;; where Normal has them. It is still Hard: that player lands 78% on the beat
  ;; there against 85% on Normal, which is the precision the setting asks for.
  ;;
  ;; The enemy climb rate stays put: the note above $enemy_speed says two ramps
  ;; on the same axis is how a game becomes unplayable at level 6 without
  ;; anyone deciding it should.
  ;;
  ;; $difficulty is not reset by init: it is a choice about the next run, so a
  ;; restart has to carry it rather than wipe it — chapter 8's argument for $rng.
  (global $difficulty (mut i32) (i32.const 1))   ;; 0 easy, 1 normal, 2 hard
  (global $BAR_BASE (mut i32) (i32.const 3))
  (global $BAR_CAP (mut i32) (i32.const 11))
  (global $BAR_EVERY (mut i32) (i32.const 2))    ;; levels per extra spawn

  (global $rng (mut i32) (i32.const 707406378))
  (global $rng2 (mut i32) (i32.const 1234567891))   ;; the lead line only
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
  ;; 0 = no drop, 1 = the build-up bar, 2 = the drop. $dropEnd is the bar
  ;; index at which a drop that is still running ends; $cond is the pool
  ;; address of the live conductor, or -1.
  (global $dropState (mut i32) (i32.const 0))
  (global $dropEnd (mut i32) (i32.const 0))
  (global $cond (mut i32) (i32.const -1))

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
  (global $drops (mut i32) (i32.const 0))       ;; a conductor walked on
  (global $condHits (mut i32) (i32.const 0))    ;; an on-beat shot into it
  (global $condKills (mut i32) (i32.const 0))
  (global $slams (mut i32) (i32.const 0))       ;; a drop ended with it standing
  (global $leadNotes (mut i32) (i32.const 0))   ;; a lead note played (a chime released)
  (global $chimes (mut i32) (i32.const 0))      ;; a chime caught

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

  ;; The same, on the lead line's own stream.
  (func $rand2_below (param $n i32) (result i32)
    (local $x i32)
    (local.set $x (global.get $rng2))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (global.set $rng2 (local.get $x))
    (i32.rem_u (i32.and (local.get $x) (i32.const 2147483647)) (local.get $n)))

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
      (i32.add (global.get $BAR_BASE) (i32.div_s (global.get $level) (global.get $BAR_EVERY)))
      (global.get $BAR_BASE) (global.get $BAR_CAP)))

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
    ;; the build-up: a bar of nothing but the beat
    (if (i32.eq (global.get $dropState) (i32.const 1)) (then (local.set $n (i32.const 0))))
    (local.set $i (i32.const 0))
    (local.set $tries (i32.const 0))
    (local.set $lastSeg (global.get $pseg))
    ;; During the drop the route starts where the conductor stands, so the
    ;; plan is one continuous walk rather than a jump at the barline.
    (if (i32.ge_s (global.get $cond) (i32.const 0))
      (then (local.set $lastSeg (i32.trunc_f32_s (f32.load offset=0 (global.get $cond))))))

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
        (br $lp)))
    (call $plan_lead))

  ;; The lead phrase: a few notes on steps the bass left empty, preferring the
  ;; off-eighths so it answers the bass rather than doubling it, on segments
  ;; that step by one or two from the last — a melody, not a scatter, and
  ;; one a player can follow round the ring.
  (func $plan_lead
    (local $n i32) (local $i i32) (local $tries i32) (local $st i32) (local $a i32)
    (local $seg i32)
    (if (i32.lt_s (global.get $level) (global.get $LEAD_FROM_LEVEL)) (then (return)))
    (local.set $n (i32.add (global.get $LEAD_NOTES)
      (if (result i32) (i32.ge_s (global.get $level) (i32.const 5)) (then (i32.const 1)) (else (i32.const 0)))))
    (local.set $seg (global.get $pseg))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (br_if $done (i32.gt_s (local.get $tries) (i32.const 60)))
        (local.set $tries (i32.add (local.get $tries) (i32.const 1)))
        (local.set $st (call $rand2_below (global.get $STEPS_PER_BAR)))
        ;; off-eighths (2, 6, 10, 14) three times as likely as the rest
        (br_if $lp (i32.and (i32.ne (i32.rem_u (local.get $st) (i32.const 4)) (i32.const 2))
                            (i32.ne (call $rand2_below (i32.const 3)) (i32.const 0))))
        (local.set $a (call $bar_addr (local.get $st)))
        (br_if $lp (i32.ne (i32.load8_u (local.get $a)) (i32.const 0)))
        (br_if $lp (i32.ne (i32.load8_u offset=3 (local.get $a)) (i32.const 0)))
        (local.set $seg (call $wrap_seg (i32.add (local.get $seg)
          (i32.sub (call $rand2_below (i32.const 5)) (i32.const 2)))))
        (i32.store8 offset=3 (local.get $a) (i32.add (local.get $seg) (i32.const 1)))
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

  ;; The conductor goes into the enemy pool like anything else, so bolts find
  ;; it, the widget draws it and a restart clears it with no new code. It is
  ;; placed opposite the player, so the first thing the drop asks is to cross.
  (func $spawn_conductor
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_ENEMIES)))
        (local.set $a (call $enemy_addr (local.get $i)))
        (if (f32.eq (f32.load offset=20 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (f32.convert_i32_s
              (call $wrap_seg (i32.add (global.get $pseg) (i32.const 6)))))
            (f32.store offset=4 (local.get $a) (global.get $CONDUCTOR_DEPTH))
            (f32.store offset=8 (local.get $a) (global.get $CONDUCTOR_HP))
            (f32.store offset=12 (local.get $a) (global.get $CONDUCTOR_HP))
            (f32.store offset=16 (local.get $a) (f32.const 4.0))
            (f32.store offset=20 (local.get $a) (f32.const 1.0))
            (f32.store offset=24 (local.get $a) (f32.const 0.0))
            (f32.store offset=28 (local.get $a) (f32.const 0.0))
            (global.set $cond (local.get $a))
            (global.set $drops (i32.add (global.get $drops) (i32.const 1)))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  (func $chime_addr (param $i i32) (result i32)
    (i32.add (global.get $CHIMES_OFF) (i32.mul (local.get $i) (global.get $CHIME_STRIDE))))

  (func $spawn_chime (param $seg i32)
    (local $i i32) (local $a i32)
    (global.set $leadNotes (i32.add (global.get $leadNotes) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHIMES)))
        (local.set $a (call $chime_addr (local.get $i)))
        (if (f32.eq (f32.load offset=8 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=0 (local.get $a) (f32.convert_i32_s (local.get $seg)))
            (f32.store offset=4 (local.get $a) (f32.const 0.0))
            (f32.store offset=8 (local.get $a) (f32.const 1.0))
            (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp))))

  ;; Every chime climbs a quarter-tube on the step and lands on the beat: in
  ;; the player's segment it is caught, anywhere else it is gone.
  (func $on_step_chimes
    (local $i i32) (local $a i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (global.get $MAX_CHIMES)))
        (local.set $a (call $chime_addr (local.get $i)))
        (if (f32.gt (f32.load offset=8 (local.get $a)) (f32.const 0.0))
          (then
            (f32.store offset=4 (local.get $a)
              (f32.add (f32.load offset=4 (local.get $a)) (global.get $CHIME_RISE)))
            (if (f32.ge (f32.load offset=4 (local.get $a)) (f32.const 0.999))
              (then
                (f32.store offset=8 (local.get $a) (f32.const 0.0))
                (if (i32.eq (i32.trunc_f32_s (f32.load offset=0 (local.get $a))) (global.get $pseg))
                  (then
                    (global.set $chimes (i32.add (global.get $chimes) (i32.const 1)))
                    (global.set $groove (call $clampf
                      (f32.add (global.get $groove) (global.get $CHIME_GROOVE))
                      (f32.const 0.0) (global.get $GROOVE_MAX)))
                    (call $add_score (f32.mul (global.get $SCORE_CHIME) (call $mult)))))))))
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
    (if (i32.eq (local.get $a) (global.get $cond))
      (then
        (global.set $condKills (i32.add (global.get $condKills) (i32.const 1)))
        (global.set $cond (i32.const -1))
        (global.set $dropState (i32.const 0))
        (global.set $shield (call $clampf
          (f32.add (global.get $shield) (global.get $DROP_HEAL))
          (f32.const 0.0) (global.get $SHIELD_MAX)))
        (call $add_score (f32.mul (global.get $SCORE_CONDUCTOR) (call $mult)))))
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
            ;; A skipper moves only on the step, in $on_step_enemies, and the
            ;; conductor only when it plays a note, in $on_step.
            (if (i32.and (i32.ne (local.get $kind) (i32.const 1))
                         (i32.ne (local.get $kind) (i32.const 4)))
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
    (local $d f32) (local $seg i32) (local $onBeat i32) (local $kind i32) (local $dmg f32)
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
                        ;; The conductor is the same rule, as a boss.
                        (if (i32.and (i32.ge_s (local.get $kind) (i32.const 3))
                                     (i32.eqz (local.get $onBeat)))
                          (then (br $hit)))
                        (local.set $dmg (f32.load offset=8 (local.get $a)))
                        ;; ... and hurt by the groove, not only by the beat.
                        ;; See $CONDUCTOR_HP for why the beat alone was not
                        ;; enough.
                        (if (i32.eq (local.get $kind) (i32.const 4))
                          (then
                            (global.set $condHits (i32.add (global.get $condHits) (i32.const 1)))
                            (local.set $dmg (f32.mul (local.get $dmg) (call $mult)))))
                        (f32.store offset=8 (local.get $e)
                          (f32.sub (f32.load offset=8 (local.get $e)) (local.get $dmg)))
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
        ;; the conductor steps to the note it is about to play
        (if (i32.ge_s (global.get $cond) (i32.const 0))
          (then (f32.store offset=0 (global.get $cond)
                  (f32.convert_i32_s (i32.sub (local.get $seg) (i32.const 1))))))
        (call $spawn_enemy (i32.sub (local.get $seg) (i32.const 1))
                           (i32.load8_u offset=1 (local.get $a)))))
    (call $on_step_chimes)
    ;; the lead line's note on this step, if the phrase has one
    (local.set $seg (i32.load8_u offset=3 (local.get $a)))
    (if (i32.ne (local.get $seg) (i32.const 0))
      (then (call $spawn_chime (i32.sub (local.get $seg) (i32.const 1)))))
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

    ;; ---- the drop ----
    ;; The drop ran its four bars and the conductor is still standing: it
    ;; leaves on the barline, and the barline is where it hits.
    (if (i32.and (i32.eq (global.get $dropState) (i32.const 2))
                 (i32.ge_s (global.get $barIdx) (global.get $dropEnd)))
      (then
        (if (i32.ge_s (global.get $cond) (i32.const 0))
          (then
            (f32.store offset=20 (global.get $cond) (f32.const 0.0))
            (global.set $cond (i32.const -1))
            (global.set $slams (i32.add (global.get $slams) (i32.const 1)))
            (global.set $groove (f32.mul (global.get $groove) (f32.const 0.4)))
            (global.set $shield (f32.sub (global.get $shield)
              (f32.mul (global.get $LEAK_COST) (global.get $SLAM_MUL))))
            (if (f32.le (global.get $shield) (f32.const 0.0))
              (then
                (global.set $shield (f32.const 0.0))
                (global.set $gameOver (i32.const 1))))))
        (global.set $dropState (i32.const 0))))
    ;; the last bar before a drop level is the build-up
    (if (i32.and (i32.eq (i32.rem_u (global.get $barIdx) (i32.const 8)) (i32.const 7))
                 (i32.eqz (i32.rem_u (i32.add (global.get $level) (i32.const 1))
                                     (global.get $DROP_EVERY))))
      (then (global.set $dropState (i32.const 1))))
    ;; and the first bar of it is the drop
    (if (i32.and (i32.eqz (i32.rem_u (global.get $barIdx) (i32.const 8)))
                 (i32.eqz (i32.rem_u (global.get $level) (global.get $DROP_EVERY))))
      (then
        (global.set $dropState (i32.const 2))
        (global.set $dropEnd (i32.add (global.get $barIdx) (global.get $DROP_BARS)))
        (call $spawn_conductor)))
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

  ;; Copy one column of the difficulty table into the globals the rest of the
  ;; engine reads. Called only from init, so a run never changes balance halfway
  ;; through — which matters more here than anywhere: a song whose arrangement
  ;; changed mid-bar would be heard doing it. Normal restates the initialisers,
  ;; because a restart after an Easy or Hard run has to put them back.
  (func $apply_difficulty
    (if (i32.eqz (global.get $difficulty))
      (then   ;; easy
        (global.set $BPM_BASE (f32.const 84.0))
        (global.set $BPM_GROOVE (f32.const 40.0))
        (global.set $BPM_CAP (f32.const 150.0))
        (global.set $BAR_BASE (i32.const 2))
        (global.set $BAR_EVERY (i32.const 2))
        (global.set $BAR_CAP (i32.const 9))
        (global.set $LEAK_COST (f32.const 14.0))
        (global.set $BEAT_WINDOW (f32.const 0.058)))
      (else
        (if (i32.eq (global.get $difficulty) (i32.const 2))
          (then   ;; hard
            (global.set $BPM_BASE (f32.const 108.0))
            (global.set $BPM_GROOVE (f32.const 62.0))
            (global.set $BPM_CAP (f32.const 184.0))
            (global.set $BAR_BASE (i32.const 2))
            (global.set $BAR_EVERY (i32.const 1))
            (global.set $BAR_CAP (i32.const 12))
            (global.set $LEAK_COST (f32.const 26.0))
            (global.set $BEAT_WINDOW (f32.const 0.048)))
          (else   ;; normal
            (global.set $BPM_BASE (f32.const 96.0))
            (global.set $BPM_GROOVE (f32.const 54.0))
            (global.set $BPM_CAP (f32.const 168.0))
            (global.set $BAR_BASE (i32.const 3))
            (global.set $BAR_EVERY (i32.const 2))
            (global.set $BAR_CAP (i32.const 11))
            (global.set $LEAK_COST (f32.const 20.0))
            (global.set $BEAT_WINDOW (f32.const 0.058)))))))

  ;; 0 easy, 1 normal, 2 hard; anything else is clamped rather than trusted, and
  ;; a JavaScript call with no argument arrives as 0. Takes effect at the next
  ;; init().
  (func $set_difficulty (export "set_difficulty") (param $d i32)
    (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.const 0))))
    (if (i32.gt_s (local.get $d) (i32.const 2)) (then (local.set $d (i32.const 2))))
    (global.set $difficulty (local.get $d)))
  (func $get_difficulty (export "get_difficulty") (result i32) (global.get $difficulty))

  (func $init (export "init")
    ;; first, because the first bar planned below reads it
    (call $apply_difficulty)
    (global.set $rng (i32.const 707406378))
    (global.set $rng2 (i32.const 1234567891))
    (global.set $leadNotes (i32.const 0))
    (global.set $chimes (i32.const 0))
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
    (global.set $drops (i32.const 0))
    (global.set $condHits (i32.const 0))
    (global.set $condKills (i32.const 0))
    (global.set $slams (i32.const 0))
    (global.set $dropState (i32.const 0))
    (global.set $dropEnd (i32.const 0))
    (global.set $cond (i32.const -1))
    (call $clear_pool (global.get $ENEMIES_OFF) (global.get $ENEMY_STRIDE)
                      (global.get $MAX_ENEMIES) (i32.const 20))
    (call $clear_pool (global.get $BOLTS_OFF) (global.get $BOLT_STRIDE)
                      (global.get $MAX_BOLTS) (i32.const 12))
    (call $clear_pool (global.get $CHIMES_OFF) (global.get $CHIME_STRIDE)
                      (global.get $MAX_CHIMES) (i32.const 8))
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
  (func $get_drops (export "get_drops") (result i32) (global.get $drops))
  (func $get_cond_hits (export "get_cond_hits") (result i32) (global.get $condHits))
  (func $get_cond_kills (export "get_cond_kills") (result i32) (global.get $condKills))
  (func $get_slams (export "get_slams") (result i32) (global.get $slams))
  (func $get_lead_notes (export "get_lead_notes") (result i32) (global.get $leadNotes))
  (func $get_chimes (export "get_chimes") (result i32) (global.get $chimes))
  ;; 0 none, 1 the build-up bar, 2 the drop — so the widget can play the
  ;; riser and light the HUD from the engine's idea of the song, not its own.
  (func $get_drop_state (export "get_drop_state") (result i32) (global.get $dropState))
  ;; Bars left in the drop, counting the one playing.
  (func $get_drop_bars_left (export "get_drop_bars_left") (result i32)
    (if (result i32) (i32.eq (global.get $dropState) (i32.const 2))
      (then (i32.sub (global.get $dropEnd) (global.get $barIdx)))
      (else (i32.const 0))))
)
