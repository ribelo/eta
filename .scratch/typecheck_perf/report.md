# Effet-na0 typecheck performance report

## Fixture

Generated 50-module app under `scratch/typecheck_perf/`.

Each module composes the previous module with a 12-step effect chain using:

- `Effect.bind`, `map`, `thunk`, `fail`, `catch`-compatible typed errors
- object-row env requirements over 25 capability methods
- polymorphic-variant errors including `Validation`, `Cache`, `External`, `Timeout`
- `par`, `all`, `all_settled`, `for_each_par_bounded`, `race`
- `retry`, timeout-shaped code, scoped `acquire_release`
- `Supervisor.scoped` with child start/await
- `named` and `annotate`

Runtime smoke result:

```text
typecheck_perf smoke passed: 3741715390752970850
```

## Build Measurements

Single local run through `scratch/typecheck_perf/measure.sh`.

Peak RSS is unavailable in this environment because `/usr/bin/time` is not installed;
the script records `max_rss_kb=unavailable` and still captures wall-clock time.

| Measurement | Wall time |
| --- | ---: |
| Clean build of 50-module fixture | 977 ms |
| No-op rebuild | 203 ms |
| Touch middle module (`tp_m25.ml`) rebuild | 210 ms |

## Diagnostic Probes

| Probe | Lines | Bytes | Result |
| --- | ---: | ---: | --- |
| Missing env method | 35 | 1979 | Correctly points to missing `billing_charge` after row dump |
| Too-narrow error row | 20 | 1038 | Correctly names disallowed tags `External`, `Validation` |
| Supervisor handle escape | 11 | 519 | Correct rank-2 generality error |
| Value-restriction-style reusable effect | 0 | 0 | No error reproduced with current abstract `Effect.t` shape |

## Verbatim Diagnostic Excerpts

### Missing env method

```text
The second object type has no method billing_charge
```

The full message is 35 lines. It is noisy but actionable; the last line identifies the
missing method.

### Too-narrow error row

```text
The second variant type does not allow tag(s) `External, `Validation
```

This is acceptable. It names the rejected tags directly.

### Supervisor handle escape

```text
This field value has type
  ('a, 'b) Supervisor.t ->
  ('a, 'c, 'b, ('a, 'b, int) Supervisor.child) Effect.supervisor_scope
which is less general than
  's. ('s, 'd) Supervisor.t -> ('s, 'e, 'd, 'f) Effect.supervisor_scope
```

This is less beginner-friendly but expected for the rank-2 scope invariant. It remains
short and points at the escaping body.

## Interpretation

No compile-time performance concern surfaced. A clean build under one second for this
heavy synthetic fixture is acceptable, and no-op/touch rebuilds are close to 200 ms.

Error quality is acceptable with one known cost: object-row missing-capability errors
still dump a large row before the useful final line. This matches prior R-DX findings
but does not cross the task's concern threshold of cryptic or 200-line diagnostics.

The value-restriction probe did not reproduce under the current abstract `Effect.t`
public shape. That is a positive change relative to older R-DX evidence, where reusable
open-row module values needed thunks more often.

## Recommendation

No package code change is required.

Keep the current design. Documented mitigations from earlier R-DX work still stand:
prefer explicit `unit -> ...` for exported reusable env-row effects, use named capability
profiles in `.mli` files when signatures get dense, and keep application service graphs
as ordinary OCaml values/functions.

No follow-up task is needed from this measurement. Reopen only if a real application or a
larger generated fixture shows multi-second incremental builds, errors above roughly 200
lines, or misleading diagnostics that do not identify the failing method/tag/scope.
