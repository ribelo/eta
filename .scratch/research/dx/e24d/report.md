# DX-E24d Report — Retry cause alignment

## Recommendation

**PROMOTE.** `Effect.retry` should share the catchability boundary already used
by `bind_error`, `catch_some`, and `retry_or_else`, while preserving its full
source cause whenever no retry succeeds.

## Intentionality finding

The divergence was accidental, not load-bearing.

- Narrow `retry` predates the shared helpers and retained its direct
  `Cause.Fail` match through file splits and schedule refactors.
- `69adecfa` introduced `stripped_uncatchable` and `first_typed_failure` to fix
  composite typed recovery.
- `bbe54cd9` added `retry_or_else` after that fix and used the shared boundary
  from its first implementation.
- `02efcaa5` later colocated both implementations without an alignment decision.
- `365f7b01` documented the difference as a “Current limitation”; history and
  the E24 consultation preserve `retry_or_else` for its two-error fallback, not
  because `retry` needs a distinct idea of retryability.

The falsification searches and commit evidence are recorded in
`redteam/c-history-falsification.md` (V-DX-E24D-002).

## Semantic decision

Alignment lands with these rules:

1. Strip-test the whole cause for defects, interruption, and finalizer
   diagnostics using `stripped_uncatchable`.
2. For a typed-only cause, pass `first_typed_failure` to `while_` and the
   schedule.
3. If policy rejects or exhausts, return the original cause from that attempt.
4. If an uncatchable diagnostic exists, do not run policy and return the
   original cause unchanged.

The terminal choice is deliberate. `retry` keeps the same error type and has no
fallback result, so collapsing to one `Fail` would lose diagnostics. This
matches `catch_some`'s non-match path. `retry_or_else` is coherent: its terminal
paths intentionally run a replacement effect, and its changed error type means
uncatchable typed leaves cannot always be retained.

## Implementation and executable evidence

- `lib/eta/effect_schedule.ml`: `retry` now shares the two helpers and preserves
  the source cause on every terminal path.
- `lib/eta/effect.mli`: the bare-only limitation is replaced by the shared
  boundary and exact terminal-preservation contract.
- Five named shared-suite tests cover first-failure predicate/schedule input,
  buried uncatchables, rejection preservation, exhaustion preservation, and raw
  empty-composite passthrough.
- Existing bare-failure tests remain unchanged and green.

Focused red/green evidence (V-DX-E24D-003): before the implementation, the new
suite had three expected failures (composite retry plus both policy-observation
tests); after the implementation, `test/core_eio` passed all 570 tests.

## Blast-radius census

A scan of `lib/`, `test/`, `bench/`, and `examples/` found no production-library
caller outside the combinator implementation.

- The existing retry/repeat shared suite uses bare `Effect.fail` causes or
  explicitly uncatchable defect/interruption/finalizer exits. Those behaviors
  are unchanged; the only typed composites in that suite were the existing
  `retry_or_else` case and the five new `retry` cases.
- The generic property suite retries an always-successful effect. Stress suites
  generate bare typed failures. Both remain semantically unchanged.
- Three examples and two runtime benchmarks use ordinary bare typed failures.
- Fifty typecheck fixtures apply `retry` to `Effect.pure`, so they cannot observe
  cause matching.
- API-DX, adapter, and test-runtime call sites likewise use success or bare typed
  failures; full gates confirm they remain green.

A raw `Cause.Sequential []` or `Concurrent []` passes through unchanged,
matching the shared boundary's no-typed-failure rule. The public variants permit
this shape even though the smart constructors reject empty lists.

## E22 registration

R79–R81 now register the four named tests and exact source spans. The `retry`
half of CD-E22-006 is closed. CD-E22-006 remains as a narrower dated row only
for `retry_or_else` predicate, schedule-policy, and fallback
defect/interruption/finalizer failure paths; R82 continues to register its
existing success, typed fallback, composite, uncatchable, and delay matrix.

## Red-team and review packet

- V-DX-E24D-004: buried-defect, terminal-preservation, and history-falsification
  records under `redteam/` — all PASS.
- `review/before-after.md`: cause-shape behavior matrix.
- `review/QUESTIONS.md`: direct answers for uncatchable refusal and exhaustion.

## Prediction scoring

| Prediction | Result |
|---|---|
| Divergence is accidental | HIT |
| Shared boundary should align | HIT |
| Uncatchable composites skip policy and remain exact | HIT |
| Rejection/exhaustion preserve the original composite | HIT |
| Existing bare behavior is unchanged | HIT |
| Retry debt closes; narrower `retry_or_else` debt remains | HIT |
| All required gates pass | HIT |

Final score: **7/7 HIT**.

## Gates

V-DX-E24D-005, rerun after the final review adjustment:

| Gate | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force` | PASS |

The final focused `test/core_eio` rerun also passed all 570 tests.
