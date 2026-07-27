# DX-E38 report — structured finalizer failures

Evidence ID: `V-DX-E38-002`

## Verdict

Accept the existential finalizer payload. Same-domain cleanup failures now keep
the concrete error value and its printer; only `Cause.Portable.of_cause`
materializes that pair to the existing portable string.

## Shipped shape

`Cause.Finalizer.Fail` is the bare GADT form predicted in the sealed journal:

```ocaml
Fail : {
  error : 'err;
  pp : Format.formatter -> 'err -> unit;
} -> t
```

`finalizer_of_cause` pairs each typed `Cause.Fail` value with the active error
printer without invoking it. The value-survival test proves conversion is not an
eager render, then unpacks the existential, applies its paired typed printer, and
observes the original concrete value by physical identity.

`Cause.Portable.Finalizer.Fail` remains `string`. `Portable.of_cause` is the
materialization boundary, and OTel JSON remains unchanged.

## Equality decision

`Cause.Finalizer.equal` and `diagnostic_equal` render each hidden failure with
its own printer and compare the resulting strings. Same-domain `Cause.equal` and
`Cause.diagnostic_equal` delegate finalizer branches to those rules.

This is diagnostic equality, not hidden-value identity. Two different values —
including values of different concrete types — compare equal when their printer
outputs collide. The red-team tests pin that result and also prove that a
different rendering compares unequal. This limit is explicit in `cause.mli` and
the law registry.

A total but deliberately stateful printer can make comparisons across separate
invocations unstable. Eta's printer contracts require total printers; callers
that use equality also need stable diagnostic output. This is a limit of the
upstream rendered-form rule, not a reason to recover erased values unsafely.

## Render and encoding parity

- The complete E4 `Cause.pretty` / `pp_compact` corpus passed unchanged.
- A release failure with no `error_pp` still renders exactly
  `Finalizer(Fail("<typed failure>"))`.
- An E7-derived `pp_err` on a release failure renders exactly
  `Finalizer(Fail("db:7"))`.
- A raising derived printer used by finalizer span telemetry becomes
  `Cause.Die`, preserving the public observability contract.
- `Cause.Portable` materializes the stored printer to `"C:7"` in the focused
  boundary test.
- The OTel JSON golden corpus passed with no shape or string changes.

No E4 or OTel parity delta required justification.

## Migration

The migration covered `Cause` rendering/equality/squash/portable conversion,
runtime finalizer assembly, async/background/supervisor paths, observability,
signal cleanup, tests, laws, benchmarks, and examples. String-valued expected
finalizers now carry `Format.pp_print_string`; tests that inspect runtime-created
failures unpack and render the existential instead of matching a string payload.
QCheck properties stopped using polymorphic equality on function-bearing values
and use `Cause.equal` instead.

The sealed direct-site census was incomplete: it predicted 91 occurrences in 28
files because the initial command omitted `examples/`. Independent review found
three additional example consumers. Corrected baseline: **94 occurrences in 31
files**. All three examples were migrated and `@examples` passes. Wildcard-only
patterns remained source-compatible.

## Census and footguns: prediction score

| Prediction | Actual | Score |
| --- | --- | --- |
| Bare existential record | Exact shipped shape | Match |
| Rendered-form equality and honest collision limit | Implemented, documented, and tested through both Finalizer and Cause equality APIs | Match |
| No E4 render delta | Full E4 corpus unchanged | Match |
| E7/E25 meaningful release rendering | Derived `pp_err` produces `db:7` end to end | Match |
| Concrete value survives | Non-eager conversion plus original-value identity proven | Match |
| Portable materializes; pure-OCaml jsoo | Portable test, OTel corpus, and mainline jsoo gate pass | Match |
| Public values `+0`, constructors `+0`, one payload-shape change | Exactly `+0`, `+0`, one changed constructor payload | Match |
| 91 direct sites / 28 files | Corrected to 94 / 31 after examples review | Miss: 3 sites / 3 files |
| Footgun delta `+0` | No new public footgun registry entry; rendered-equality collision/stability limits are documented semantics | Match |
| Ready for review | All required gates and adversarial follow-ups pass | Match |

Overall sealed-prediction score: **9/10 exact; one census miss corrected before
handoff**.

## Law registry

Eight new `cause.mli` claims are registered as R154–R161 with exact normative
spans and named executable tests. Existing `effect.mli` R74/R75 rows continue to
cover preservation of finalizer branches after wording was corrected from
"rendered" to "outside the typed channel".

## Red-team outcome

The required attacks are preserved under `.scratch/research/dx/e38/redteam/`:

1. no printer: default output unchanged;
2. E7-derived printer: kind and payload survive release conversion;
3. colliding printers: both equality modes follow the documented diagnostic rule.

Independent review additionally found and closed:

- three example consumers omitted from the initial census;
- a value-survival assertion that needed an explicit pre-render check;
- missing release-finalizer coverage for a raising telemetry printer.

The review's remaining stateful-printer caveat is documented above and does not
change the upstream equality decision.

## Verification

All commands passed:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/otel_eio --force
```

`test/otel_eio` is the real executable adapter for the objective's
`test/otel_common` library target.

Additional focused/adversarial gates passed:

```sh
nix develop -c dune runtest test/core_eio test/ppx_eio test/otel_eio test/laws --force
nix develop -c dune runtest test/ppx_eio --force
nix develop -c dune build @examples
```

## Recommendation

Ship the GADT payload. It removes eager string flattening, preserves current
human and portable output, makes registered printers meaningful for cleanup
failures, and adds no compatibility path or new public value surface.
