# Code Review Checklist — arcade-library

- [ ] `npm run check` passes; `node --check` passes on every widget.
- [ ] No game imports, copies at runtime, or styles another game's code or prefix (invariants 1–2).
- [ ] No game state in JavaScript; the engine imports nothing new (invariants 3–5).
- [ ] Committed `.wasm` / `docs/*.html` were rebuilt, not hand-edited (invariant 6).
- [ ] Comments say why, with the measurement where there was one (invariant 7).
- [ ] Layout constants and `FIELD` tables changed together with the engine's `@fields`.
- [ ] Page changes checked at 320px and desktop, both hub themes.
- [ ] Docs updated per `project-docs/CLAUDE.md` "Keeping the docs true".
