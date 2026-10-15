/* ============================================================
 * ARCADE LIBRARY — best scores, kept in this browser
 *
 * The first piece of shared code in the repository, and it is shared on
 * purpose, which is why it lives at the root beside index.html and not in
 * games/.
 *
 * Invariant 1 says no game shares code with any other, because a change made
 * for one could break another. That holds here, because **no game uses this.**
 * No widget references it, knows it exists, or behaves differently without it.
 * The widgets already expose `getState()` with a `score` and a `gameOver` in
 * it — every one of the nine — and that is the entire interface. What calls
 * this file is the *page shell* around each widget (games/<slug>/index.html)
 * and the hub, which are hosting concerns, not game concerns.
 *
 * So it is deliberately small and deliberately forgiving:
 *
 * - **It polls rather than hooks.** Watching getState() every 400ms needs no
 *   change to any widget. A game over is a state that persists until restart,
 *   so a poll cannot miss one the way it could miss an instantaneous event.
 * - **It never throws.** localStorage is absent in some private modes, throws
 *   on access when a browser blocks site data, and is a quota away from full.
 *   Every access is wrapped, and a failure means no best score is shown, never
 *   a broken game.
 * - **A page shell that cannot load it still works.** The shells call it
 *   through `window.ArcadeScores && ...`, so copying a single game folder out
 *   of the repository — which the READMEs say you can — costs you the best
 *   score and nothing else.
 *
 * Scores live under `arcade-library:best:<key>` as `{ score, date }`. The key is
 * the game's slug, or whatever a page shell's watch() function picks from the
 * finished run: Pixel Wave files a Hard run under `pixel-wave:hard`. Only a
 * finished run is recorded: restarting mid-run does not bank the score, which
 * is what an arcade cabinet does too.
 *
 * One limit worth knowing. Under file:// the browser decides what counts as
 * one origin, and Firefox treats each file separately — so opening the hub
 * straight off disk there will not see scores set by the game pages. Serve the
 * repository (`npm run serve`) and it all shares one origin.
 * ============================================================ */
(function (global) {
  'use strict';

  var PREFIX = 'arcade-library:best:';
  var POLL_MS = 400;

  function storage() {
    try { return global.localStorage || null; } catch (e) { return null; }
  }

  function best(slug) {
    var s = storage();
    if (!s) return null;
    try {
      var raw = s.getItem(PREFIX + slug);
      if (!raw) return null;
      var rec = JSON.parse(raw);
      return (rec && typeof rec.score === 'number' && isFinite(rec.score)) ? rec : null;
    } catch (e) {
      return null;
    }
  }

  /** Record a finished run. Returns true if it is a new best. */
  function record(slug, score) {
    score = Math.floor(Number(score));
    if (!isFinite(score) || score <= 0) return false;
    var cur = best(slug);
    if (cur && cur.score >= score) return false;
    var s = storage();
    if (!s) return false;
    try {
      s.setItem(PREFIX + slug, JSON.stringify({
        score: score,
        date: new Date().toISOString().slice(0, 10),
      }));
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * Watch a mounted widget and record its score whenever a run ends. Returns a
   * function that stops watching. `onBest(score)` is called on a new best, if
   * given.
   *
   * `slug` may also be a function of the finished run's getState(), returning
   * the key to record under. That is how a title with difficulty settings keeps
   * one best per setting while this file still knows nothing about difficulty:
   * the page shell decides what a key means, and this only stores it.
   */
  function watch(slug, game, onBest) {
    if (!game || typeof game.getState !== 'function') return function () {};
    var wasOver = false;
    var id = global.setInterval(function () {
      var st;
      try { st = game.getState(); } catch (e) { return; }
      if (!st) return;                 // engine still loading
      var over = !!st.gameOver;
      if (over && !wasOver) {
        var key = slug;
        if (typeof slug === 'function') {
          try { key = slug(st); } catch (e) { key = null; }
        }
        if (key && record(key, st.score) && onBest) {
          try { onBest(Math.floor(st.score)); } catch (e) {}
        }
      }
      wasOver = over;
    }, POLL_MS);
    return function () { global.clearInterval(id); };
  }

  global.ArcadeScores = { best: best, record: record, watch: watch };

})(window);
