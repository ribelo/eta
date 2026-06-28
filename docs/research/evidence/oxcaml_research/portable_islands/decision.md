# Effet-OxCaml-9vo - Portable Islands Decision

Date: 2026-05-22

## Decision

Choose decision gate 2: portable islands.

Effet should keep the normal same-domain Eio runtime as the mainline model and
add, at most, an optional OxCaml-only Effect.Island module for explicit finite
CPU offload. Do not reopen the full H3 rewrite path from the current evidence.

Design A remains the baseline and is viable. Design B earns its place only
because it gives real compiler-enforced safety against bad captures. Design C,
the portable Effect AST, is not justified by the evidence and was not attempted.

## Apples-To-Apples Controls

The comparison controls what can be controlled:

- same three workloads: parse/validate, schema decode, hash/checksum/compress;
- same item count: 128 per workload;
- same bounded parallelism: 2 worker domains;
- same finite-batch result contract: output order is input order;
- same typed-error behavior: result-returning callbacks with one typed error
  exercised per workload;
- same no-Eio-worker rule.

The substrate is intentionally not identical:

- Design A uses a normal OCaml domain pool, because it is the no-OxCaml
  baseline.
- Design B uses OxCaml Parallel_scheduler, because that is the portable island
  substrate.

Therefore wall time is directional only. The decision does not claim that
OxCaml islands are faster. The deciding evidence is the compiler safety delta.

Timing hygiene note: an earlier run appeared to make islands about 50ms slower
on schema/hash. diagnose_island_timing.ml isolated that to repeated
Parallel_scheduler.create calls: first create was hundreds of microseconds;
second and third creates were about 50ms; the parallel work itself stayed in the
hundreds of microseconds. The workload fixture now reuses one island scheduler,
which is the implementation shape a real CPU island facility should use.

## Candidate Verdicts

| Candidate | Status | Evidence |
| --- | --- | --- |
| A. Mainline OCaml CPU pool | Viable baseline | Runs all three workloads with bounded parallelism, input-order results, typed errors, and no Eio worker contamination. It cannot reject bad captures. |
| B. OxCaml portable callback island | Accepted | Runs the same workload class and mechanically rejects ref, Eio.Stream, Runtime.run, Logger, and raw Cause captures. |
| C. Small Effect.Portable.t island DSL | Deferred / not attempted | B covers typed results, all_settled, worker diagnostics, and ergonomics without nested portable composition. |
| Full H3 rewrite | Rejected for now | No evidence from this epic forces portable Resource, Supervisor, Stream/OTel bridge, full Runtime replacement, or a portable Effect AST. |

## H1-H10 Ledger

| Hypothesis | Verdict | Evidence |
| --- | --- | --- |
| H1 mainline CPU pool baseline | Holds | baseline_ocaml_pool/cpu_pool_smoke.ml, ordered_results_positive.ml, bad_capture_policy_note.md. |
| H2 portable callback island | Holds | Positive and negative fixtures under oxcaml_callback_island/; gate summary pass=15 fail=0. |
| H3 avoid full Effect.t split | Holds | Design C was not attempted because B covered the first useful island use cases. |
| H4 reduced invariant checklist | Holds | use_cases/invariants.md lists the seven v1 invariants. |
| H5 explicit API stance | Holds | Island is opt-in; existing Effect.t and Runtime.run behavior is unchanged. |
| H6 batch-only boundary | Holds | Finite batch fixtures pass; streams/exporters remain out of scope. |
| H7 honest cancellation/timeout | Holds with v1 no-timeout | Busy-loop callback compiles but is not run; arbitrary callbacks are not preemptible. |
| H8 error boundary | Holds with tiny diagnostic | Typed result callbacks plus worker_die diagnostic cover the workloads; Cause.Portable is deferred. |
| H9 ergonomics without PPX | Holds | use_cases/ergonomics_examples.ml runs with three manual annotations. |
| H10 complexity budget | Holds | Forbidden full-H3 concepts remain absent. |

## Complexity Budget

Introduced concepts:

- Island scheduler;
- portable callback;
- portable input/output payloads;
- indexed finite batch results;
- materialized worker failure diagnostic.

Forbidden in the first pass and still absent:

- portable Resource;
- portable Supervisor;
- portable Stream transport;
- portable OTel exporter transport;
- full public Effect.Portable.t DSL;
- full H3 Runtime.run replacement;
- capsule runtime state;
- H4 telemetry.

## Consequence For Effet-OxCaml-1z1

Effet-OxCaml-1z1 Stage B should not reopen as written. S1-S11 are superseded by
a smaller optional island implementation path. The H3 research remains useful as
boundary evidence, especially the negative capture sheet and finite-batch
invariants, but it is not the implementation target.

Stage A recovery evidence is absorbed as follows:

- R1 cancellation: island v1 exposes no timeout; cooperative polling is a future
  extension only if real island users need it.
- R2 env/error: island v1 uses typed result callbacks plus worker_die
  diagnostics; no portable env or full Cause.Portable channel is needed.
- R3 online queue: out of scope for finite batch islands; stream/exporter
  bridges remain deferred.

## Verification

Command:

    nix develop -c bash scratch/oxcaml_research/portable_islands/run.sh

Result:

    summary: pass=15 fail=0

Diagnostic command:

    nix develop -c ocamlfind ocamlopt -extension-universe alpha -package portable,parallel,parallel.scheduler,unix -linkpkg scratch/oxcaml_research/portable_islands/diagnose_island_timing.ml -o /tmp/diagnose_island_timing.exe
    nix develop -c /tmp/diagnose_island_timing.exe

Diagnostic result:

    decode.create_us=49920
    hash.create_us=49968
    decode.parallel_reused_us=226
    hash.parallel_reused_us=164
