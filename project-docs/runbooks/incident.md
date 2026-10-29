# Incident — arcade-library

| Symptom | First checks |
|---|---|
| A game shows a blank stage | Console error? `node --check` the widget. Is `game.wasm` served as `application/wasm`? (The base64 fallback should still load) |
| Every engine "stale" in CI | Line endings (`.gitattributes`) or a toolchain version drift. `CONTRIBUTING.md` "Gotchas" |
| The hub 404s on library.gautamgoklani.com | Vercel domain setting and DNS (GAP-2) |
| `/arcade` on the portfolio errors | The library host is down or not connected. The redirect itself lives in the portfolio's `next.config.ts` |

Fix forward on a branch, run the regression suite, merge. Roll back in Vercel if play is broken
and the fix isn't quick.
