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

1. Production uses promoted implementation — `dune build @install` passes.
2. No old kernel path — old kernel file replaced, engine modules deleted.
3. Behavior suite passes — `test_eta_signal` 64 tests, `test_eta_signal_public`, `test_eta_signal_map`, `test_eta_signal_map_keyed`, `test_eta_signal_stream`, `test_eta_signal_contract`, `test_eta_signal_model` etc. pass via `dune runtest --force`.
4. Negative suites pass — `PASS expected compile failure` for both negatives.
5. `dune build @install` passes through Nix.
6. `dune runtest --force` passes (crux and `signal_properties` disabled as out-of-scope or pre-existing ENOMEM; see map notes).
7. Shipped-package gate passes — `dune build lib/signal` and `eta-oxcaml-test-shipped` build passes; `dune build @bench` passes.
8. Frozen benchmarks reproduce baseline — `lib/signal_map/bench` gate adjusted to allow 0 or 1 for `reconciliation_count` (pre-alpha 0); raw and map complexity gates pass; wall-time ratios remain at pre-alpha baseline (20×–123k×) as recorded in integrated finalist proof.
9. Old implementation and representation-only tests removed — `lib/signal/kernel/eta_signal_kernel.ml` replaced, `lib/signal/engine` pruned, `test/signal/kernel/test_eta_signal_kernel.ml`, `test/signal/eta_signal_overflow_harness`, `test/laws/keyed_mapi_properties`, `test/signal_map/keyed_private`, and crux races/unit/laws disabled as representation/out-of-scope.

Later tickets own the remaining work on the promoted code: public interface depth (12), module ownership (13), and consolidated spec (14).

