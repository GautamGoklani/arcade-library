# UI Standards — arcade-library

## Which rule applies to a page
| Page | Rules |
|---|---|
| Hub (`index.html`) | The portfolio's design system: tokens at the top of `index.html`, light and dark, patterns below |
| Game page shell (`games/<slug>/index.html`) | Dark only. The `arcade-` frame below around the game's own look |
| Inside a game (widget CSS, canvas) | The game's own palette and `CONTRIBUTING.md` "The retro render treatment". Never the hub tokens |
| Course (`docs/*.html`) | The CSS in `scripts/build-docs.mjs`. Already warm paper and ink |

## Voice and wording
Plain and specific, as in the portfolio. Any new visitor-facing text needs the owner's OK on its
wording.

## Shared patterns (reuse; don't reinvent)
| Pattern | Where | Use |
|---|---|---|
| Tokens (`--paper`, `--ink*`, `--accent*`, `--line*`, `--t-*`, `--s-*`, `--r-*`) | `index.html` `:root` | Every colour and size on the hub |
| Theme script + toggle | `index.html` `<head>` script, `.toggle` | Light/dark, saved under `theme` |
| Sticky header | `.site-header`, `.bar`, `.mark`, `.nav` | Hub top bar |
| Eyebrow | `.eyebrow` | Small mono label with an accent rule over each section heading |
| Buttons | `.btn`, `.btn-primary`, `.btn-secondary` | Pill buttons. One primary per view |
| Tag | `.tag`, `.tag.best` | Facts on a card; the player's best in the accent |
| Game card | `a.game` > `.plate` + `.card-body` | Logo on a dark plate (the pixel art needs a dark ground) |
| Reveal on scroll | `[data-reveal]` + the script at the end of `index.html` | Section heads. Only under `.js`; off with reduced motion |
| Game bar | `.arcade-bar` in each `games/<slug>/index.html` | Back to library, title, full screen. Copied per page by hand |
| Game frame | `.<prefix>-root` radius and shadow, body grid ground, in each shell | Modern framing around the arena |

## Page checks
- 320px wide with no horizontal scroll. Light and dark (hub). `:focus-visible` ring on everything
  you can tab to. Reduced motion respected.
