# DX-E38 sealed predictions

Evidence ID: `V-DX-E38-001-executor`

This entry was sealed before implementation and is intentionally immutable.
Actual results belong in `report.md`.

## Decision and proof obligations

The upstream shape decision is fixed: same-domain finalizer typed failures keep
their value and printer, while `Cause.Portable` remains string-materialized.
The implementation must prove:

1. the typed value survives same-domain finalizer conversion;
2. all existing `Cause.pp`, `pretty`, and `pp_compact` output remains byte-for-byte
   identical for the E4 corpus;
3. `equal` and `diagnostic_equal` compare finalizer failures by their rendered
   printer output, including the honest collision limit;
4. E25 `error_pp` and E7-derived `pp_err` reach release-failure diagnostics;
5. no-printer behavior remains `"<typed failure>"`;
6. portable conversion materializes the traveling printer to the existing string
   payload before JSON encoding.

## Sealed predictions

- **Final GADT form:** `Cause.Finalizer.Fail` will be a bare existential GADT
  constructor carrying a small inline record with the concrete error value and
  its `Format.formatter -> error -> unit` printer. No third error taxonomy or
  public helper value will be added.
- **Equality rule:** both same-domain `Finalizer.equal` and
  `Finalizer.diagnostic_equal` will render each `Fail` with its own printer and
  compare the resulting strings. Therefore different values and even different
  hidden types compare equal when their rendered forms collide. This is a
  deliberate diagnostic equality boundary, not value identity.
- **Render parity:** all existing E4 golden strings will remain unchanged. The
  old stored string becomes the output of the stored printer at observation
  time. With no registered `error_pp`, the existing default printer still emits
  `"<typed failure>"`.
- **Meaningful-printer outcome:** a release typed failure under an E7-derived
  `pp_err` will render its variant kind and payload instead of
  `"<typed failure>"`.
- **Value-survival outcome:** a producing site retaining the concrete error type
  will be able to classify the original payload through the existential's paired
  typed printer; no pre-rendered replacement string will intervene.
- **Portable/jsoo outcome:** `Portable.of_cause` will render the existential once
  into the unchanged portable `Finalizer.Fail of string`; the implementation is
  pure OCaml GADT code and should require no js_of_ocaml substrate accommodation.
- **Census prediction:** public value count delta `+0`; public cause/finalizer
  constructor count delta `+0`; one existing constructor changes payload shape.
  The baseline direct-site census is 91 occurrences across 28 source/test/bench
  files, expected to migrate mechanically. Footgun delta: `+0`.
- **Parity prediction:** no E4 corpus delta and no OTel JSON shape delta.
- **Review prediction:** `E38 READY FOR REVIEW`, with the rendered-form collision
  limit explicitly tested and reported rather than hidden.

## Hypothesis status

| Candidate | Status | Reason |
| --- | --- | --- |
| Existential value plus paired printer; portable materialization at boundary | Accepted upstream; to prove | It preserves same-domain structure and keeps string construction at the portable boundary. |
| Existing eager `string` payload | Rejected by mission | It destroys the typed value at finalizer conversion. |
| Diagnostic record (`kind`/`message`/`attrs`) | Rejected upstream | It flattens at construction and retains string kinds. |

The strongest counterexample is two distinct values whose printers collide. It
must pass according to the documented equality rule and be reported as that
rule's limit, not mistaken for structural value equality.
