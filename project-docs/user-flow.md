# User Flow — arcade-library

## 1. Visitors
One kind of visitor, with no account: someone who wants to play, or to learn WebAssembly.

## 2. Stage by stage

### Arrive
- **Entry points:** the portfolio footer ("Arcade library"), old portfolio URLs (`/arcade/*`,
  `/library`, which 308 to the hub), a direct link to a game, a course chapter from search.
- **Screens:** `/` (hub).

### Pick a game
- **Screens:** hub `#play`. Each card shows logo, description, engine size and input tags, plus
  "BEST n" once a run has finished in this browser.
- **Moves on:** a card → `games/<slug>/index.html`.

### Play
- **Screens:** the game page. Bar: back to the library, the game's name, full screen.
- **Controls:** keyboard everywhere; touch controls appear when a finger is used; gamepad;
  pause (`P`/`Esc`, the PAUSE button, losing focus); difficulty button. Grid Breaker also steers
  with the mouse, anywhere in the window. Tower Defense is played with the mouse.
- **Edge cases:** blocked storage means no best score, never a broken game. A very short window
  drops the height allowance. Without the Fullscreen API (iPhone Safari), the button is hidden.
- **Moves on:** "Library" in the bar → hub, with the new best score on the card.

### Learn
- **Screens:** hub `#learn` → `docs/index.html` → chapters with prev/next.

## 3. Open questions
- Should a game page also link to the course chapter that explains its engine? (owner)
