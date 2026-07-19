# DX-E6 Review Manifest

One matched A/B pair is provided for randomized independent review:

- `boot-old.ml` — nested `let@` / `Effect.with_resource` ladder.
- `boot-new.ml` — flat `Effect.Scoped.with_3` helper.
- `INFERRED.md` — normalized identical inferred `boot` signatures.

Both snippets bootstrap the same pool, cache, and metrics services and pass the
same record to `body`. Definitions are intentionally identical; only lifecycle
composition differs. Reviewers should evaluate the files before reading the
experiment report or recommendation.
