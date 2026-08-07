# Promote selected finalist to pre-alpha

Type: task
Status:
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
