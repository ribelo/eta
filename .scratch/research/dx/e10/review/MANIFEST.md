# DX-E10 Review packet manifest

Blinded materials for independent review. No verdicts in this directory.
Both sugar spellings are present for A/B; if promoted, only one form would ship.

| File | Purpose |
| --- | --- |
| `site-handwritten.ml` | Genuine repo site shape (`Effect.fn __POS__ __FUNCTION__`) from the observability suite |
| `site-let.ml` | Same site with `let%eta` |
| `site-attr.ml` | Same site with `[@@eta.trace]` |
| `module-handwritten.ml` | Small realistic module with 3 `fn`-wrapped definitions |
| `module-let.ml` | Same module with `let%eta` |
| `module-attr.ml` | Same module with `[@@eta.trace]` |
| `QUESTIONS.md` | Reviewer prompts (includes hold-gate frequency question) |
