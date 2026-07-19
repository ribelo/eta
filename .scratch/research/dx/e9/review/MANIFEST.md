# DX-E9 Review packet manifest

Blinded materials for independent review. No verdicts in this directory.

| File | Purpose |
| --- | --- |
| `implicit.ml` | Baseline: realistic program using always-open `let open Syntax in let* … and* …` |
| `explicit-par.ml` | Same program with `open Syntax` + `open Syntax.Parallel` |
| `explicit-app.ml` | Order-sensitive writes with `open Syntax` + `open Syntax.Applicative` |
| `implicit-race.ml` | Wrong-under-old-shape twin of `explicit-app.ml` (always-open `and*`) |
| `QUESTIONS.md` | Reviewer prompts (do not lead toward a preferred answer) |
