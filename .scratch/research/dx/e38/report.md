# DX-E38 report — capture-time structured finalizer failures

Evidence ID: `V-DX-E38-F1-002`

This revision supersedes the deferred-printer design previously recorded here.
Follow-up review showed that storing the printer let exceptions escape Eta's
capture boundary and let stateful printers make equality non-reflexive.

## Verdict

Accept the replacement payload:

```ocaml
Cause.Finalizer.Fail : {
  error : 'err;
  rendered : string;
} -> Cause.Finalizer.t
```

At `finalizer_of_cause`, Eta invokes the supplied printer once, stores the
original value and produced string, and never stores the printer. Runtime call
sites perform this conversion inside ordinary defect capture.

This shape preserves strictly more information than the pre-E38 string payload
without moving user code beyond the runtime boundary.

## Review defects and repair

### Deferred exception escape

The rejected design deferred `error_pp` until `Cause.pp`, equality, squash, or
Portable conversion. A raising printer could therefore escape as a raw exception
instead of becoming `Cause.Die`.

The repair renders during runtime finalizer conversion. A raising `error_pp` now
produces `Cause.Die` for both registered releases and `Effect.finally` cleanup on:

- native Eio: `eta_error raising release renderer` and
  `eta_error raising finally renderer`;
- js_of_ocaml: `raising release error_pp becomes die at conversion` and
  `raising finally error_pp becomes die at conversion`.

These tests deliberately use `Effect.with_error_pp` without a tracing span, so
they prove conversion-time capture rather than a later telemetry render.

### Equality reflexivity

`Finalizer.equal` and `diagnostic_equal` now compare only stored `rendered`
strings. `Cause.equal` and `Cause.diagnostic_equal` delegate finalizer branches to
that same rule. No printer executes during comparison.

The stateful-printer counterexample now renders once at capture, remains
reflexive in both equality modes, and does not increment its render count during
comparison. This is exactly the pre-E38 string equality rule; hidden values do
not participate, and equal stored strings compare equal regardless of hidden
type.

## Value survival and rendering

The value-survival proof observes all repaired obligations together:

1. conversion invokes the printer exactly once;
2. the payload stores the expected capture-time string;
3. the existential contains the original value by physical identity;
4. the failure is outside the typed channel.

Consumers needing human diagnostics use `rendered`; consumers that need to
retain structure have the existential `error` value. Portable conversion drops
the same-domain value and copies `rendered` into the unchanged
`Cause.Portable.Finalizer.Fail of string` representation.

## Render and encoding parity

- The complete E4 `Cause.pretty` / `pp_compact` corpus passed unchanged.
- No-printer release output remains exactly
  `Finalizer(Fail("<typed failure>"))`.
- E7-derived release output remains exactly `Finalizer(Fail("db:7"))`.
- Portable finalizer output remains `"C:7"`.
- The OTel JSON golden corpus passed unchanged.
- `@examples` passes after the simpler `{ error; rendered }` migration.

There are no justified render or encoding deltas.

## Migration and implementation cleanup

All deferred `{ error; pp }` consumers in library code, tests, laws, benchmarks,
and examples now use `{ error; rendered }`. Expected string fixtures store that
same string directly; runtime consumers read `rendered` without invoking user
code.

The repair also:

- removed the dead `effect_core` render helper;
- centralized conversion as `capture_finalizer_cause` and kept it outside the
  cleanup-execution catch so conversion defects stay top-level `Cause.Die`;
- renamed runtime/effect conversion helpers to describe capture rather than a
  deferred render;
- made Portable conversion a direct stored-string copy;
- retained the QCheck migration away from polymorphic equality on existential
  payload records.

The follow-up baseline census was **113 direct references across 35 files**.
After helper consolidation and the added jsoo regression, the final tree has
**111 references across the same 35 files**. No deferred-printer field or consumer
remains.

## Census and footguns

| Follow-up prediction | Actual | Score |
| --- | --- | --- |
| Value + rendered-string payload | Exact shipped shape | Match |
| Printer runs once at capture | Direct count assertion and runtime behavior pass | Match |
| Raising release printer becomes `Cause.Die` | Native and jsoo regression tests pass | Match |
| Stored-string equality is reflexive | Stateful-printer counterexample passes without rerender | Match |
| Existing render/Portable/OTel output unchanged | All golden suites pass | Match |
| Pure-OCaml jsoo portability | Mainline jsoo gate passes | Match |
| Public values `+0`, constructors `+0` | Exactly `+0` and `+0`; one payload field replaced | Match |
| Footguns `+0` | Raw deferred exceptions and stateful equality are eliminated; no new footgun entry | Match |
| Ready for review | All required gates pass | Match |

Follow-up prediction score: **9/9**.

## Law registry

R154–R161 now describe the repaired capture-time value/string, stored-string
rendering/equality, default rendering, Portable conversion, and enclosing Cause
delegation with narrowed exact spans. R162 registers the restored runtime rule:
a raising finalizer `error_pp` becomes `Cause.Die`, with native and jsoo tests.

Registry totals are updated to nine `cause.mli` external rows and 272 covered
rows overall.

## Verification

All required commands passed on the repaired tree:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/otel_eio --force
```

`test/otel_eio` is the executable adapter for the objective's
`test/otel_common` library.

Focused evidence also passed:

```sh
nix develop -c dune runtest test/core_eio test/ppx_eio test/otel_eio test/laws --force
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
nix develop -c dune build @examples
```

## Recommendation

Ship the capture-time value + rendered-string GADT. It preserves typed structure,
restores E25's defect boundary, restores total/reflexive string equality, keeps
all existing output, and stores no executable printer in a finalizer cause.

## Follow-up 2 — registry completion

Evidence ID: `V-DX-E38-F2-002`

This appendix supersedes the registry totals in the earlier Law registry section;
the runtime design and implementation verdict remain unchanged.

Three previously uncovered public clauses now have direct named evidence:

- R163 covers structural equality for non-`Fail` finalizer nodes and physical
  exception identity for `Finalizer.Die` with a composite/identity matrix;
- R164 directly distinguishes materialized `Finalizer.Die` diagnostic equality
  from physical identity and checks message, span, and annotation differences;
- R165 invokes `Cause.finalizer_of_cause` directly with a raising printer and
  observes propagation of that same exception object.

R154 now cites both normative source locations, including
`lib/eta/cause.mli:12-14`. The introductory prose was reflowed without changing
its contract so R155 can cite only the Portable clause at line 15 and exclude the
typed-channel clause.

The `cause.mli` registry census is now **12 registered external rows** and the
overall registry is **275 covered rows**. No runtime implementation or jsoo test
changed.

The focused and prescribed native commands passed on the final tree:

```sh
nix develop -c dune runtest test/core_eio test/laws --force
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

Per Follow-up 2, the mainline jsoo gate was not rerun because no jsoo test moved.
All sealed Follow-up 2 predictions matched.
