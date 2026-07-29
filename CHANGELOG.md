# Changelog

## Unreleased

### Added

- `Effect.with_supervised_background`, preserving the former supervised
  `with_background` behavior for lexical child work whose failure must not
  interrupt the body.
- OpenAI Responses encoding now projects mixed text and image function-call
  outputs using the provider's structured `function_call_output.output` content
  array; legacy Chat Completions continues to reject tool-result media with a
  typed unsupported error.
- `Effect.sync_option ~if_none` — thunk counterpart of `from_option`, completing
  the `from_result`/`from_option` × `sync_result`/`sync_option` construct family.
  `Some` succeeds, `None` is the typed `if_none` failure, ordinary exceptions
  stay defects (`Cause.Die`) and are not handled by `bind_error`.

### Changed

- **Breaking:** `Eta.Resource` moved to the optional cache package as
  `Eta_cache.Refreshable`. The runtime-owned `Resource.auto` constructor is
  deleted; use the lexical callback form
  `Eta_cache.Refreshable.with_auto ~load ~schedule body`. The refresh loop is
  cancelled and awaited when `body` exits. Use
  `with_auto_on_refresh_error ~on_refresh_error` only for immediate typed-refresh
  alerts. `manual`, `get`, `refresh`, and `failures` keep their behavior under
  the new module.
- **Breaking:** `Effect.all` now forks one fiber per input instead of applying
  an omitted cap of eight. Explicitly bounded calls move to the named sibling:

  ```text
  all ~max_concurrent:n effects  →  all_bounded ~max_concurrent:n effects
  all effects                    →  now forks one fiber per input (was: at
                                    most 8 admitted at once)
  ```
- **Breaking:** `Effect.with_background` is now fail-fast. A background typed
  failure or defect cancels and awaits the body and propagates its cause, like
  `Effect.par`; body completion still cancels and awaits the background. Move
  callers that require the old delayed-observation behavior to
  `Effect.with_supervised_background`.
- `Effect.retry` now retries catchable typed-failure composites using the first
  typed failure in cause order, matching `bind_error` and `retry_or_else`.
  Callers whose effects produce such composites may now see predicate and
  schedule steps where retry previously stopped silently; rejected or exhausted
  retries preserve the complete original cause so no sibling failure is lost.

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
