# Project Gaps — arcade-library

## How to read this
Each gap is something found that doesn't match the plan, or a decision nobody has made yet. It is
never a task. Fields: **Kind** (`decision-needed`, `doc-overclaims`, `doc-understates`, `risk`,
`missing`), **Tag** (the area), **Where** (file or setting). When a gap closes, delete it and
move its substance into code comments or the doc that owns the subject.

## Headline
The site is ready to go live on `library.gautamgoklani.com`. What's left is the owner's: the
domain setting (GAP-2) and confirming the rules this repo inherited by default (GAP-1).

## High

### GAP-2 — The subdomain isn't confirmed as connected
- **Kind:** missing · **Tag:** hosting · **Where:** Vercel dashboard, DNS
- The portfolio now redirects `/arcade` and `/library` to `https://library.gautamgoklani.com`.
  Until that host serves this repo, those redirects land on an error. Nothing in either repo can
  show whether the domain is attached. Tracked as task M1·5.

## Medium

### GAP-1 — Default rules and task wording need the owner's OK
- **Kind:** decision-needed · **Tag:** process · **Where:** `project-docs/CLAUDE.md`, `tasks.md`
- The rulebook's **Default** rules (git safety, people) were copied from the portfolio, where
  the owner settled them on 2026-10-15. They haven't been settled for this repo. The Milestone 1
  wording in `tasks.md` is the agent's reading of the 2026-10-29 request.

### GAP-3 — Comments say GitHub Pages; the repo deploys with Vercel
- **Kind:** doc-overclaims · **Tag:** hosting · **Where:** `scripts/build-docs.mjs` header comment
- The comment names "GitHub Pages" as the static host, but `vercel.json` exists and the owner
  said the library lives on a gautamgoklani.com subdomain. The reasoning (commit the HTML, no
  build step on the host) holds for both. Which host is real needs the owner. Then reword the
  comment.

## Low

### GAP-4 — No security headers on the static site
- **Kind:** missing · **Tag:** security · **Where:** `vercel.json`
- The portfolio sets its security headers in its own `vercel.json`. This one sets none. Nothing
  here takes input or stores secrets, but `X-Content-Type-Options`, `Referrer-Policy` and a
  frame policy would cost a few lines. A CSP would need `'unsafe-inline'` for the inline scripts.

### GAP-5 — The theme choice isn't shared with the portfolio
- **Kind:** risk · **Tag:** UI · **Where:** `index.html` theme script
- Both sites store the choice under `localStorage.theme`, but `localStorage` is per origin, so a
  visitor who picks dark on www has to pick it again on the library. Sharing it needs a cookie on
  `.gautamgoklani.com`, which needs the owner's OK.

### GAP-6 — Grid Breaker can't be served (launched) from the letterbox
- **Kind:** decision-needed · **Tag:** games · **Where:** `games/grid-breaker/grid-breaker.js`
- Steering now follows the cursor anywhere in the window, but a click only launches the ball
  over the arena. Clicks elsewhere are left alone so an embedding page keeps its own. Space
  launches from anywhere.

## Open decisions still blocking work
- GAP-2 (domain) blocks task M1·5.
