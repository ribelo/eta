# Changelog

## Unreleased

### Added

- `Effect.sync_option ~if_none` — thunk counterpart of `from_option`, completing
  the `from_result`/`from_option` × `sync_result`/`sync_option` construct family.
  `Some` succeeds, `None` is the typed `if_none` failure, ordinary exceptions
  stay defects (`Cause.Die`) and are not handled by `bind_error`.

## Idiom pass (2026-07-18) — breaking

One batched breaking pass over the public surface, aligning Eta with OCaml
mental models. Migration is compiler-guided: delete, build, fix. Rationale
and evidence: `docs/research/dx.md`, `.scratch/research/dx-journal.md`
(V-DX-E23/E24/E25).

### Error channel mirrors `Result` (E23)

| Before | After |
|---|---|
| `Effect.catch` | `Effect.bind_error` |
| `Effect.recover`, `Effect.or_else_succeed` | deleted — use `Effect.fold ~ok ~error` |
| `Effect.result` / `Effect.option` / `Effect.exit` | `Effect.to_result` / `Effect.to_option` / `Effect.to_exit` |

`Effect.catch_some` and `Effect.or_else` unchanged.

### Iteration mirrors `List` (E24)

| Before | After |
|---|---|
| `Effect.for_each_par xs f` | `Effect.map_par f xs` |
| `Effect.for_each_par_bounded ~max xs f` | `Effect.map_par ~max_concurrent:max f xs` |
| `Effect.retry sched pred eff` | `Effect.retry ~schedule:sched ~while_:pred eff` |
| `Effect.retry_or_else sched pred ~or_else eff` | `Effect.retry_or_else ~schedule:sched ~while_:pred ~or_else eff` |
| `Effect.repeat sched eff` | `Effect.repeat ~schedule:sched eff` |

`Effect.map_par` is function-first with input-order results and fail-fast
cancellation. Omitted `?max_concurrent` means a **default cap of 8** (the
previously hidden `for_each_par` behavior), not unbounded concurrency.
`retry_or_else` is retained: its two-error form (`'err1 -> 'err2`) is not
expressible via `map_error` composition. `retry` retries a bare
`Cause.Fail` only (documented current limitation vs. `retry_or_else`'s
composite-cause handling).

### Family consistency (E25)

| Before | After |
|---|---|
| `Effect.scoped` | `Effect.with_scope` |
| `Effect.named_kind ~kind n eff` | `Effect.named ~kind n eff` |
| `Effect.now` | `Effect.now_ms` |
| `Effect.with_error_renderer` / `?error_renderer : ('err -> string)` | `Effect.with_error_pp` / `?error_pp : (Format.formatter -> 'err -> unit)` |

A raising `error_pp` becomes a defect through the ordinary capture path;
the old silent `"<error renderer raised>"` fallback is removed.

### Handle honesty: `discard` / `ignore_errors` (E2)

| Before | After |
|---|---|
| `Effect.ignore` (discard value **and** suppress typed failures) | deleted |
| — | `Effect.discard` — discard success value; all causes propagate |
| `Effect.ignore_errors` on `(unit, _) t` only | `Effect.ignore_errors` on any success type (value discarded, typed failures suppressed) |

`Effect.ignore` was the most misleading name in the surface: it read like
`Stdlib.ignore` while swallowing typed failures. Call sites split into the two
honest meanings. Defects, interruption, and finalizer diagnostics remain
visible under both `discard` and `ignore_errors`.

*This entry extends with E9 (`Syntax.Parallel`/`Syntax.Applicative`) when it
lands.*
