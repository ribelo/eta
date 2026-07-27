# DX-E38 follow-up 1 sealed micro-predictions

Evidence ID: `V-DX-E38-F1-001`

This note was sealed before follow-up implementation. The original
`journal.md` remains immutable; actual repair results belong in `report.md`.

## Replacement decision

The orchestrator has replaced the deferred-printer payload with:

```ocaml
Fail : { error : 'err; rendered : string } -> t
```

The serious alternatives are closed by the review: string-only loses the value,
and value-plus-printer moves rendering outside Eta's capture boundary.

## Predictions

- `finalizer_of_cause` will invoke the supplied printer exactly once for each
  typed failure at conversion and store both the original value and that string.
- A raising release-error printer will be caught by the ordinary runtime path as
  `Cause.Die` on native Eio and js_of_ocaml; no deferred public operation will
  invoke that printer later.
- `Finalizer.equal`, `diagnostic_equal`, and the enclosing Cause equality APIs
  will compare only stored strings. Equality will be total and reflexive even
  when the original printer was stateful.
- E4 pretty/compact output, printer-less `"<typed failure>"`, derived E7 output,
  Portable output, and OTel JSON will remain byte-identical.
- The same-domain value-survival test will classify the concrete `error` field
  directly after existential unpacking while also observing the stored string.
- Pure-OCaml GADT portability will remain unchanged on js_of_ocaml.
- Baseline follow-up census: 113 direct references across 35 consumer/source
  files. Public value delta `+0`, constructor delta `+0`, one existing payload
  field changes from `pp` to `rendered`; footgun delta `+0` because neither raw
  deferred exceptions nor stateful-printer equality remain possible.
- Expected outcome: `E38 READY FOR REVIEW` after all native/mainline gates and
  the repaired adversarial cases pass.
