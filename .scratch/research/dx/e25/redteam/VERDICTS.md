# DX-E25 Red-team verdicts

## (a) Raising `error_pp`

**Claim.** A raising `error_pp` becomes a defect through the ordinary capture
path; telemetry degrades honestly (span still closes) rather than swallowing
the raise into `"<error renderer raised>"` while preserving the original typed
failure.

**Probe.** Golden test
`error_pp raise becomes defect` in
`test/core_common/observability_common_suites.ml`:

- `Effect.named ~error_pp:(fun _ _ -> failwith "renderer exploded") "renderer-fails" (Effect.fail "original")`
- Exit is `Cause.Die` with the raised failure, not `Cause.Fail "original"`.
- Span closes with an error status derived from the defect path.

**Verdict: PASS.** Pre-E25 fallback string is gone from the public contract and
from the failing path.

## (b) `named` / `named_kind` guess-which-one

**Claim.** After absorbing `named_kind` into `named ?kind ?error_pp`, the old
choice between two verbs is unwriteable.

**Probe.**

- `named_kind` is deleted from `lib/eta/effect.mli` and implementations.
- Repository scan after migration finds no remaining `named_kind` outside
  uncommitted `objective.md` and sealed journal text.
- Erasure probe
  `named optional omission yields effects` compiles
  `named "x" eff`, `named ~kind:k "x" eff`, `named ~error_pp:pp "x" eff`, and
  `named ~kind ~error_pp "x" eff` as `Effect.t`.

**Verdict: PASS.** There is one span-naming verb; kind is an optional label.
