# Local Setup — arcade-library

Node 22 (what CI uses).

```bash
npm install        # wabt + marked, pinned exactly
npm run serve      # http://localhost:8080 (PORT to change)
npm run check      # the guard, before handing work back
```

Each `games/<slug>/index.html` also opens straight from disk, because the engine is embedded as
base64. Best scores only show up on the hub across pages when served (see `hiscores.js`).
