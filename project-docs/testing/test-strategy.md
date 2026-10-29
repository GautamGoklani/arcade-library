# Test Strategy — arcade-library

## Layers
| Layer | Tool | Runs |
|---|---|---|
| Build integrity | `npm run check` (`build.mjs --check`, `build-docs.mjs --check`, `check-layout.mjs`) | Locally and in CI on every push |
| Widget syntax | `node --check games/*/*.js hiscores.js` | Locally and in CI |
| Engine behaviour | Headless bench in Node against the compiled engine (`CONTRIBUTING.md` "Bench the engine headlessly") | By hand when tuning; harness goes in `tmp/` |
| Pages and input | Manual in a browser via `npm run serve`, or a Playwright script (Chromium is in the cloud dev container) | By hand before a release |

## Rules
- Engines are deterministic (seeded xorshift), so a bench replays exactly. Use that, not luck.
- A UI change is checked at 320px and desktop widths, in both hub themes.
- Every bug fix gets a `TC-` case in `test-cases.md`.

## Coverage
No automated browser tests exist. The `TC-` cases below are manual until someone adds them.
