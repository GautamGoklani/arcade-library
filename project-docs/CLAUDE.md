# Rules — arcade-library (library.gautamgoklani.com)

Read this file before any code, git, task-list or docs work. It overrides default behaviour.
Generated 2026-10-29 from the portfolio repo's `DOCS-REFERENCE.md`. Every "Settled" date is when
the owner decided it. Rules marked **Default** were picked by the agent that wrote this file,
copied from the portfolio's rulebook, and stand until the owner confirms or changes them.

## Where the project docs live
`docs/` is the course (22 chapters, rendered to committed HTML and served publicly), so the project
docs live in `project-docs/` instead. Two reasons, both checked in code: `scripts/build-docs.mjs`
fails on any `docs/*.md` not listed in `PARTS` (the orphan check), and Vercel serves the repo root
as-is (`vercel.json` `outputDirectory: "."`), so anything in `docs/` is part of the public course.

## Docs map
| Job | File |
|---|---|
| How the repo is built: invariants, conventions, adding a game | `CONTRIBUTING.md` (the engineering source of truth) |
| Task status / what's next | `project-docs/tasks.md` |
| Known gaps, open decisions | `project-docs/PROJECT-GAPS.md` |
| How the system fits together | `project-docs/architecture.md` |
| Visitor journeys | `project-docs/user-flow.md` |
| Page and UI rules | `project-docs/ui-standards.md` |
| Tests: strategy, cases, regression | `project-docs/testing/*.md` |
| Review / new game / release | `project-docs/checklists/*.md` |
| Run locally / deploy / incident | `project-docs/runbooks/*.md` |
| Per-game behaviour, tuning, memory layout | `games/<slug>/README.md` |

## Source priority
1. The owner's latest instruction in chat.
2. This rulebook.
3. `CONTRIBUTING.md`, the game READMEs and the "why" comments in the code.
4. Git history.

When two disagree, the higher one wins. Log the conflict in `PROJECT-GAPS.md` and don't quietly
"fix" the lower one.

## People
- Default: one owner (Gautam), working with AI agents. No client, no reviewers, no progress
  reports, no message formats.

## Git safety rules
- Default (mirrors the portfolio, settled there 2026-10-15): **the owner reviews and commits.**
  Agents don't run `git commit`, `push`, `merge`, `rebase`, `reset`, `stash` or branch
  create/switch/delete unless the owner asks for that command in that session.
- Agents leave work uncommitted and end with a summary: files changed, what was read and
  verified, check results, anything left undone.
- Before any change, run `git status` and say if the tree already has changes that are not yours.
- Never hand-edit a committed `.wasm` or `docs/*.html`. Rebuild them (`CONTRIBUTING.md`, invariant 6).
- `main` is what the live site serves. Treat anything that reaches `main` as live.

## Checks
- `npm run check` is the guard: engines match their `.wasm` and embedded base64, docs HTML
  matches its Markdown with every relative link resolving, and widget layout constants match
  their engines. Needs `npm install` first (pinned `wabt` and `marked`).
- `node --check` on every `games/*/*.js` and `hiscores.js`. Nothing else catches a syntax error
  in a widget, because there is no build step for them.
- CI: `.github/workflows/check.yml` runs both on every push and pull request.
- There is no browser test suite. UI changes are verified by loading the page (`npm run serve`)
  at 320px and desktop widths, in light and dark. See `testing/test-strategy.md`.
- A failing check blocks handing the work back.

## Definition of done
- [ ] `npm run check` passes and `node --check` passes on every widget.
- [ ] The code path the change touches has been read, not just the diff.
- [ ] Every doc the change affects is updated (see "Keeping the docs true").
- [ ] The matching `TC-` cases in `testing/test-cases.md` are added or updated.
- [ ] The change is left uncommitted with a summary for the owner (Default).

## Task tracking rules
- `tasks.md` wording is agreed scope. Change only the status marker, the trailing
  `- blocked (<reason>)` marker, the current-task pointer and the count table.
- Never reword, renumber, split, merge or add entries. Work that maps to no entry is flagged to
  the owner and logged as a gap. The current-task pointer only moves forward.

## Scope rules
- **The documentation is the deliverable; the games are the excuse** (`CONTRIBUTING.md`). When a
  change would improve the code but weaken the explanation, the explanation wins.
- Settled 2026-10-29: the library is served at `https://library.gautamgoklani.com`. The portfolio
  (`https://www.gautamgoklani.com`, repo `portfolio`) links to it from its footer and 308s
  `/arcade`, `/arcade/:slug` and `/library` to the hub. The hub and every game page link back.
- Settled 2026-10-29: the hub and the game page shells share the portfolio's look (warm paper and
  ink, one rust accent, light and dark). The games themselves stay retro. Owner's words: "looks
  nostalgic as needed but it should also feel modern".

## Architecture rules
These restate `CONTRIBUTING.md`. If one changes, change it there and here together.
- No game shares code with another game. The exceptions are tooling (`scripts/`) and the hosting
  layer: `hiscores.js`, the hub `index.html`, and each game's page shell (`games/<slug>/index.html`).
- Every game owns a CSS prefix (`ss- gb- wc- am- sd- cr- sr- td- pl-`), and every rule sits under
  `.<prefix>-root`. Hosting styles in a page shell use the `arcade-` prefix, never a game's.
- JavaScript owns no game state. The engine never calls out (event counters only).
- Strict MVP WebAssembly: four value types, one 64 KiB page, at most two imports (`sinf`/`cosf`).
- Static site with no server code and no runtime dependency. External scripts and fonts are not
  loaded. The hub uses the system font stack, not the portfolio's self-hosted Inter.

## Frontend rules
- Hub and page-shell colours are the tokens at the top of `index.html`, copied by hand from the
  portfolio's `src/app/globals.css`. Change them there and here together, or the sites drift.
- Light and dark must both work on the hub. The theme script stays a blocking inline script in
  `<head>`. The game pages are dark only: the games are drawn for a dark ground.
- Smallest supported width is 320px, with no horizontal scroll.
- WCAG 2.2 AA target. Respect `prefers-reduced-motion`: the hub's reveal and the games' scanlines
  already do.
- Inside a game: no glow (`shadowBlur`), everything snapped to the low-res grid, scanlines in CSS
  (`CONTRIBUTING.md`, "The retro render treatment").

## Markdown / docs rules
- Don't create new Markdown files unless asked. Put durable facts in the doc that owns them.
- A new course chapter needs a `PARTS` entry in `scripts/build-docs.mjs` and a rebuild.
- Code comments explain *why*, usually with the measurement that settled it. Match that density.

## Keeping the docs true
| When you change… | Also update… |
|---|---|
| A task's state | `tasks.md` status marker + count table |
| A rule or decision from the owner | This rulebook, as a dated settled rule |
| A game is added | Every step in `CONTRIBUTING.md` "Adding a game", plus `checklists/new-game.md` ticked |
| The hub or a page shell | `ui-standards.md`, `test-cases.md` (TC-HUB / TC-SHELL) |
| A design token | Both repos' tokens together (see "Frontend rules") |
| The domain or hosting | `runbooks/deploy.md`, `architecture.md`, the portfolio's redirects and `SITE.libraryUrl` |
| A check or CI step | "Checks" above, `CONTRIBUTING.md` "Commands" |
| A bug fix | A `TC-` case; add it to `regression-suite.md` if it was P1 |
| Something that doesn't match the plan | New `GAP-n` in `PROJECT-GAPS.md` (never a new task) |
| A gap closes | Delete the entry; move its substance into code comments or the owning doc |

### Session start checklist (for agents)
1. Read this file and `CONTRIBUTING.md`.
2. Read the current task in `tasks.md` and any blocked marker on it.
3. Skim the headline in `PROJECT-GAPS.md`.
4. Run `git status` and note any changes that are not yours.
