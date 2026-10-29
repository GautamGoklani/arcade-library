# Test Cases — arcade-library

Priority: P1 = breaks play or the site, P2 = visible defect, P3 = polish.

## Hub — task M1·1, M1·4
| ID | Case | Steps / expected | P | Type |
|---|---|---|---|---|
| TC-HUB-001 | No horizontal scroll | Load `/` at 320px → `scrollWidth` equals the viewport width | P1 | Layout |
| TC-HUB-002 | Theme follows the system, toggle overrides | Dark OS → dark hub. Click toggle → light, `localStorage.theme = "light"`, survives reload with no flash | P2 | Functional |
| TC-HUB-003 | Best score tag | Finish a Pulse run on Normal, return → Pulse card shows "BEST n" first | P2 | Functional |
| TC-HUB-004 | Links to the portfolio | Header "Gautam Goklani ↗" (≥40rem wide) and footer "Gautam Goklani" → `https://www.gautamgoklani.com/` | P2 | Functional |
| TC-HUB-005 | Works without JavaScript | Disable JS → every section is visible, the toggle is hidden | P2 | Accessibility |
| TC-HUB-006 | Reduced motion | Reduced motion on → no reveal movement, sections visible | P3 | Accessibility |

## Game page shells — task M1·2
| ID | Case | Steps / expected | P | Type |
|---|---|---|---|---|
| TC-SHELL-001 | Fits the window | Each of the nine at 1440×900 and 375×740 → no scroll, no console error | P1 | Layout |
| TC-SHELL-002 | Back to library | Bar "Library" → hub | P2 | Functional |
| TC-SHELL-003 | Full screen | Click "Full screen" → page fills the screen, label reads "Exit full screen". Space then acts on the game, not the button. Esc exits | P2 | Functional |
| TC-SHELL-004 | No Fullscreen API | iPhone Safari → the button isn't shown | P3 | Functional |

## Grid Breaker steering — task M1·3
| ID | Case | Steps / expected | P | Type |
|---|---|---|---|---|
| TC-GB-001 | Steering past the arena edge | 1920px-wide window, move the cursor into the right margin → paddle sits against the right wall and follows back when the cursor returns | P1 | Regression |
| TC-GB-002 | Leaving the window | Move the cursor out of the browser window → paddle stops following; keys steer | P2 | Functional |
| TC-GB-003 | Touch unchanged | On a phone, the stick steers; the margin doesn't | P1 | Regression |
