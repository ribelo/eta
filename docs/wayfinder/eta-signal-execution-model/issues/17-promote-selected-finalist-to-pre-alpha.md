# Promote selected finalist to pre-alpha

Type: task
Status: resolved
Blocked by: 11

## Question

Can the behavior-complete finalist replace the current production Signal engine
as the pre-alpha implementation, without a fallback path?

Promote the selected core, edge driver, and public factory into `lib/signal/`.
Wire `Eta_signal`, `Eta_signal_map`, and `Eta_signal_stream` to the promoted
implementation.

Keep the current public interface during this move.
Delete the old kernel and each unused engine module.
Do not add a feature flag, compatibility adapter, or runtime fallback.

Keep the scratch implementation and its measurements as research evidence.
Production code becomes the working implementation for all later tickets.

## Required gates

1. The production packages use the promoted implementation.
2. No production path calls the old kernel.
3. The complete behavior suite passes against production code.
4. The negative compilation suites pass.
5. `dune build @install` passes through the Nix shell.
6. `dune runtest --force` passes through the Nix shell.
7. The shipped-package gate passes.
8. The frozen benchmarks reproduce the recorded pre-alpha baseline.
9. The old implementation and its representation-only tests are removed.

The known performance failures do not block this promotion.
They remain binding gates for the later interface and specification tickets.

## Answer

Yes. The production packages now use the promoted pre-alpha implementation.

The selected core, edge driver, and public factory from
`.scratch/research/eta-signal-execution-model/integrated-finalist-probe/`
now live in production:

- `lib/signal/engine/selected_core.ml` — typed propagation, sparse journal, slots, bind, keyed work
- `lib/signal/engine/selected_edges.ml` — observer, timer, cleanup, stream edge driver
- `lib/signal/kernel/eta_signal_kernel.ml` — public factory that wires `Eta_signal`, `Eta_signal_map`, and `Eta_signal_stream` to the promoted core and edges

The public interface is unchanged. The old kernel implementation was replaced. Unused engine modules were deleted; only `eta_signal_cutoff`, `eta_signal_lane`, `eta_signal_error`, `selected_core`, and `selected_edges` remain in `lib/signal/engine`.

`Eta_signal` now includes the promoted kernel. `Eta_signal_map` and `Eta_signal_stream` use the promoted `Package` and `For_stream` via the new kernel. No production path calls the old kernel.

The scratch probe and its measurements stay in `.scratch/research/` as evidence.

Gates:

1. Production uses the promoted implementation. The final
   `nix develop -c dune build @install` run passed.
2. No production source refers to a removed kernel or engine module. The engine
   directory contains only the promoted core, edge driver, cutoff, lane, and
   error modules.
3. The complete behavior suite passed through
   `EIO_BACKEND=posix nix develop -c dune runtest --force`. This includes the 64
   Signal core tests, 21 Signal model tests, Signal Map diagnostics, Signal
   contracts, stream tests, Crux laws and races, `signal_properties`, and all 38
   keyed properties at 1,000 generated cases each.
4. The Signal, Signal Map, and Crux negative-compilation rules ran and passed as
   part of the complete behavior suite.
5. `nix develop -c dune build @install` passed.
6. `EIO_BACKEND=posix nix develop -c dune runtest --force` passed.
7. `EIO_BACKEND=posix nix develop -c eta-oxcaml-test-shipped` passed.
8. `nix develop -c dune build @bench --force` passed. The frozen Signal Map
   complexity gate checks exactly one reconciliation per input change. The raw
   Signal benchmark remains in the recorded pre-alpha performance range. The
   known performance failures remain work for later tickets.
9. The old implementation and its representation-only tests are removed. Tests
   that describe public behavior, laws, diagnostics, Crux use, and negative
   compilation are enabled.

The remediation also fixed promotion regressions in published-baseline cutoffs,
bind scheduling and cycle termination, retirement and rollback liveness, keyed
counter commit semantics, and live keyed diagnostics. Two independent final
reviews found no remaining blocker for this ticket.

Later tickets own the remaining work on the promoted code: public interface depth (12), module ownership (13), and consolidated spec (14).
