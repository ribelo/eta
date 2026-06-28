# effet-stream package backlog

## Epic: effet-stream package — Stream/Sink/Channel

### Description

Create a new `effet-stream` package that adds lazy, typed, chunked streams on
top of Effet's existing `('env, 'err, 'a) Effect.t` runtime. The package must
preserve V-R10 object-row env inference, typed polymorphic-variant error rows,
slim `Cause.t` / `Exit.t`, Eio switch-owned concurrency, and runtime-parameter
tracing.

### Design

Use the V-S decisions in `journal.md` and the summarized contract in
`docs/research/evidence/stream_research/README.md`.

- Stream is the public core GADT.
- Sink is a fold/effectful-fold record.
- Channel is an internal implementation concept for v0, not a public type.
- Pull is chunked at the boundary; push appears only inside concurrent
  operators such as `merge` and `flat_map_par`.
- Resources are acquired through `Effect.acquire_release` and run under
  `Effect.scoped`; early termination, failure, and cancellation must all close.
- Concurrent operators fork under the interpreter's current `Eio.Switch`.

### Acceptance Criteria

- `packages/effet-stream/` builds as public package `effet-stream`.
- Public `.mli` matches the summarized contract in
  `docs/research/evidence/stream_research/README.md` unless the
  implementation session records a new V-S revision in `journal.md`.
- Tests include the curated Effect-TS Stream/Sink slice named in the journal.
- `nix develop -c dune runtest --force` passes.
- `git status` shows no unintended edits under `packages/effet/` or
  `packages/effet-otel/`.

## First-Slice Tasks

### 1. Package skeleton + Stream core

Description: Add `packages/effet-stream/` with a public package stanza, module
interface, minimal Stream GADT, and interpreter entry point returning
`Effect.t`.

Design: Implement constructors for `empty`, `from_chunk`, `from_iterable`,
`from_effect`, `fail`, `map`, and `take`. Do not expose Channel.

Acceptance Criteria:
- Package builds with `nix develop -c dune build packages/effet-stream/`.
- `run_collect (from_iterable [1;2;3])` returns `[1;2;3]`.
- `from_effect` preserves the original Effect env/error channels.

### 2. Core combinators

Description: Implement `map_effect`, `filter`, `drop`, `scan`, `concat`, and
sequential `flat_map`.

Design: Keep primitive constructors few; prefer combinators over adding GADT
nodes unless the interpreter needs to observe the operation for resource or
concurrency semantics.

Acceptance Criteria:
- Tests cover success and typed failure through `map_effect`.
- `take` and `drop` do not over-pull past the requested boundary.
- `scan` emits the initial state only if the final V-S contract says it should;
  document the choice in the test name.

### 3. Sink and runners

Description: Add `Sink.t`, `fold`, `fold_effect`, `collect_to_list`, `count`,
`drain`, `run`, `run_collect`, and `run_drain`.

Design: Sink is a fold record, not a Channel-reader in v0.

Acceptance Criteria:
- The A/B/C lab scenario is reproduced in package tests.
- Sink effect failures propagate through the stream run error channel.
- `collect_to_list`, `count`, and `drain` are covered.

### 4. Resource-scoped sources

Description: Implement `from_eio_stream` and file/byte sources.

Design: `from_eio_stream` consumes an existing queue without owning its
producer. File sources use `Effect.acquire_release` and run under
`Effect.scoped`.

Acceptance Criteria:
- Finalizers run on normal completion, early `take`, typed failure, defect, and
  cancellation.
- Tests use deterministic fake resources before touching real files.
- Ownership rules are documented in the `.mli`.

### 5. Concurrent operators

Description: Implement `merge` and `flat_map_par ~max_concurrency`.

Design: Fork fibers only inside the active Effet runtime switch. Fail fast on
first observed failure, cancel siblings, and preserve `Cause.Both` when multiple
failures are observed before cancellation wins.

Acceptance Criteria:
- `merge` interleaves two delayed streams without serialising either side.
- `flat_map_par` respects `max_concurrency`.
- Cancellation closes resources in losing or interrupted branches.
- Downstream completion explicitly cancels upstream producer fibers; the second
  research pass showed a chunked Eio queue pipeline can otherwise deadlock when
  `take` stops while a producer is blocked on a bounded queue.

### 6. Curated Effect-TS parity tests

Description: Port a small, high-value slice from `Stream.test.ts`,
`Sink.test.ts`, and `Channel.test.ts`.

Design: Test behaviours, not TypeScript names. Start with constructors,
map/filter/take/drop, sink fold/count/collect, resource cleanup, merge,
timeout/retry if schedule integration lands.

Acceptance Criteria:
- At least 12 tests reference the Effect-TS source behaviour they cover.
- Tests include both `Exit.Ok` and `Exit.Error` paths.
- `nix develop -c dune runtest --force` is the documented gate.
