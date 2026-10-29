# Task List — arcade-library

Legend: `[ ]` not started · `[partial]` started, not complete · `[x]` done ·
trailing `- blocked (<reason>)` = stuck on something outside the code.

Entry format: `[status] - **<n>\. <title>** - blocked (<reason>)`

**Current task:** [Milestone 1 · 5\. Point library.gautamgoklani.com at this repo](#current-task)

Rules in `project-docs/CLAUDE.md` → "Task tracking rules". Milestone 1 records the owner's
request of 2026-10-29. Its wording is the agent's reading of that request and needs the owner's
OK before it counts as agreed scope (GAP-1). Future games are tracked in
`games/plans-for-other-games.md`, not here.

# Milestone 1 — One site with the portfolio
*Done when: the library looks like part of gautamgoklani.com, both sites link to each other, and
the library is live on its own subdomain.*

---

[x] - **1\. Give the hub the portfolio's design system**

Platform: `index.html`

Details:
* Warm paper and ink tokens, one accent, light and dark with a toggle that remembers the choice.
* Sticky header, eyebrow headings, pill buttons, game cards on dark plates, reveal on scroll.
* Keep the best-score tags, which `hiscores.js` writes into `.tags` on each `a.game`.

Deliverable: the hub renders at 320px and 1280px with no horizontal scroll, in both themes, and
`npm run check` passes.

---

[x] - **2\. Modern frame around each game, retro inside it**

Platform: `games/*/index.html` (page shells only)

Details:
* A bar with a link back to the library, the game's name and a full-screen button.
* Grid ground, rounded arena with depth. Nothing inside a widget changes.
* The bar's height comes out of each shell's height budget, so the arena stays above the fold.

Deliverable: all nine pages load with no console error and no scroll at 1440×900 and 375×740.

---

[x] - **3\. Grid Breaker keeps steering when the cursor leaves the arena**

Platform: `games/grid-breaker/grid-breaker.js`, `games/grid-breaker/README.md`

Details:
* Full screen, the arena is letterboxed and a touchpad swipe overshoots it, and the paddle froze.
* Track the mouse across the window, clamp to the arena, and drop steering only when the cursor
  leaves the window.

Deliverable: TC-GB-001 passes.

---

[x] - **4\. Link the two sites**

Platform: this repo (hub header and footer, game bars) and the `portfolio` repo (footer,
`next.config.ts` redirects, `SITE.libraryUrl`)

Deliverable: TC-HUB-004 and the portfolio's TC-WEB-007 pass.

---

[ ] - **5\. Point library.gautamgoklani.com at this repo** <a id="current-task"></a> - blocked (needs the owner's Vercel and DNS access)

Platform: Vercel dashboard, DNS

Details:
* Add `library.gautamgoklani.com` as the domain of this repo's Vercel project, with the DNS
  record Vercel asks for. See `runbooks/deploy.md`.

Deliverable: `https://library.gautamgoklani.com/` serves the hub and a game page plays.

---

## Task count by status
| Milestone | Total | [x] | [partial] | [ ] | blocked |
|---|---|---|---|---|---|
| 1 — One site with the portfolio | 5 | 4 | 0 | 1 | 1 |
| **All** | **5** | **4** | **0** | **1** | **1** |
