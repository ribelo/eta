# P0-T2 Eio Wrapper Probe

Status: final for Effet-OxCaml-07e.

Question: what mode-annotated wrapper surface should Effet put around raw Eio handles while keeping Eio as the local fiber and IO substrate?

## Artifacts

- eio_wrap_positive.ml: scoped Eio switch wrapper, local Eio fiber fork, local cancellation, portable-payload stream add, and Parallel fork_join through the portable wrapper.
- parallel_inside_eio_positive.ml: Parallel.fork_join2 running inside an Eio fiber.
- switch_local_fork_negative.ml: attempted @ local switch handle cannot call Eio.Fiber.fork.
- switch_escape_wrapped_negative.ml: @ local switch handle cannot be stored past the scope.
- fiber_portable_ref_capture_negative.ml: portable Parallel fork wrapper rejects int ref capture.
- stream_payload_negative.ml: stream add wrapper rejects nonportable closure payloads.
- stream_parallel_wrapped_negative.ml: raw Eio.Stream wrapper cannot be shared into Parallel workers.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/eio_wrap_probe/run.sh

Last result:

    summary: pass=8 fail=0

## Evidence

A small scoped/forked/cancelled Eio program compiles and runs through wrappers when Eio handles remain lexical wrappers over raw Eio values. The positive fixture uses Eio.Switch.run, Eio.Fiber.fork, Eio.Cancel.sub/cancel/check, Eio.Stream.add/take, and a portable Parallel.fork_join2 wrapper.

Parallel composes inside Eio fibers. The positive fixture starts an Eio fiber, creates a Parallel scheduler inside that fiber, runs fork_join2 with portable closures, resolves an Eio.Promise, and returns 42.

A truly local switch handle proves escape safety but cannot call Eio.Fiber.fork. The local-fork negative fails because the local switch is expected to be global at the raw Eio.Fiber.fork call. The switch-escape negative also fails when code tries to store the local switch in a ref.
The real runtime create shape has the same limitation: `runtime_create_local_switch_negative.ml` fails because a local `Eio.Switch.t` cannot be stored in the runtime record that later owns daemon forks and drain semantics.

Portable domain forks should wrap Parallel, not Eio.Fiber. The portable fork wrapper rejects a closure that captures int ref, matching the desired domain-boundary safety.

Stream_portable can enforce portable payloads for local Eio streams, but raw Eio.Stream is not a portable cross-domain queue. A closure payload that reads int ref is rejected by the wrapper's portable item argument. Capturing the wrapped Eio stream into Parallel is rejected because the stream operation is nonportable/shareability fails.

## Decision diary

- V-P0T2-1 - Keep raw Eio as the same-domain substrate.
  Decision: Effet should wrap Eio lexically, but not claim raw Eio.Switch.t, Eio.Cancel.t, Eio.Promise.t, or Eio.Stream.t are portable.
  Rationale: the positive Eio wrapper fixture runs, while stream_parallel_wrapped_negative preserves the existing Eio.Stream nonportability boundary.

- V-P0T2-2 - Do not use a single @ local Switch_local handle for Eio fiber/resource creation.
  Decision: Phase 3 should expose a lexical Switch_scope wrapper around Eio.Switch.run for runtime code, plus local-only borrow APIs only where the borrowed handle is not passed to raw Eio functions.
  Rationale: switch_escape_wrapped_negative proves @ local prevents leaking, but switch_local_fork_negative proves the same annotation cannot call Eio.Fiber.fork because Eio expects a global Switch.t.

- V-P0T2-3 - Split local Eio fibers from portable domain forks.
  Decision: Fiber_local wraps Eio.Fiber.fork for same-domain runtime fibers. Fiber_portable wraps Parallel.fork_join / domain execution and requires portable closures.
  Rationale: Eio fiber bodies naturally capture Eio promises, streams, switches, and cancellation contexts. Portable closure enforcement belongs at the Parallel boundary, where the ref-capture negative fails as desired.

- V-P0T2-4 - Stream_portable is payload-checked, not cross-domain transport.
  Decision: Phase 8 should use Stream_portable only as an Eio-local stream facade with portable payload checks; cross-domain producer handoff uses the P0-T6 Portable.Atomic wrapper before re-entering Eio.
  Rationale: stream_payload_negative proves payload checking works, and stream_parallel_wrapped_negative proves raw Eio.Stream still cannot cross Parallel.

## Adopted wrapper surface

- Switch_scope.run : (t -> 'a) -> 'a, where t hides raw Eio.Switch.t and remains same-domain.
- Fiber_local.fork : Switch_scope.t -> (unit -> unit) -> unit, directly backed by Eio.Fiber.fork.
- Cancel_scope.sub/cancel/check : lexical wrappers over Eio.Cancel for same-domain cancellation protocols.
- Fiber_portable.fork_join2 : Parallel.t -> portable closures -> result, backed by Parallel.fork_join2.
- Stream_portable.create/add/take : local Eio.Stream wrapper whose add argument is @ portable.
- Phase 8 Portable_queue : the P0-T6 Portable.Atomic handoff wrapper, used before local Stream_portable when values arrive from domains.

## Deferred

- Production Phase 3 should avoid exporting raw switch/cancel handles from the wrapper modules.
- If upstream Eio gains mode annotations, re-test whether Switch_local can replace Switch_scope.
- Phase 8 still needs a real wake/backpressure protocol around the Portable.Atomic handoff.
