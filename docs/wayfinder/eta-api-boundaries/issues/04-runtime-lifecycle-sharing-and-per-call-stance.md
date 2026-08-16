# Runtime lifecycle: sharing and per-call stance

Type: grilling
Status: open
Blocked by: 01, 02

## Question

What is Eta's stance on runtime lifecycle, on native hosts and on JS hosts?

The problem: `Effect.fresh` values are unique only within one runtime
(`lib/eta/effect.mli:503-512`). Runtime-per-call silently resets identities.
Nema creates a fresh runtime per `run_io` call inside its service layer. Inn
creates one per store call inside the server, and one per CLI query. Taumel
creates one per JS promise door, and `Eta_jsoo.run` itself models
runtime-per-call. Exergy built one runtime per session behind
`with_effect_host` in about 50 lines. It is the only correct consumer.

Decide one cross-host stance:

- Endorse runtime-per-call, and document its cost and semantics.
- Ship a shared-runtime helper, for example `with_runtime`, and name its
  package home.
- Or make runtime-per-call detectably wrong.

The answer names what happens to `Eta_jsoo.run`. It also documents the
identity semantics of `Effect.fresh` across runtimes. Apply the rubric from
[H-W4 decision rubric](01-hw4-decision-rubric.md) and the prior art from
[Runtime-door prior art](02-runtime-door-prior-art.md).
