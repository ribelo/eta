# DX-E13 Review Packet

Read in this order:

1. `js-old.ml` — the current application-level callback path through
   `Effect.Expert.make`, runtime context, runtime promise creation, manual
   one-shot state, and direct parking.
2. `js-new.ml` — the same `EventTarget` registration through `Effect.async`.
3. `QUESTIONS.md` — cancellation teach-back and answer key.

Both examples check `EventTarget.addEventListener` and `removeEventListener`
loudly and install no polyfill. Interruption cleanup depends on the latter. The
comparison is deliberately one application wrapper, not a
migration of Eta runtime-package `Expert.make` leaves.

The executable semantic evidence is shared, not copied:

- `test/core_common/effect_async_shared.ml` owns the programs and assertions;
- `test/core_common/effect_async_common_suites.ml` instantiates them for Eio;
- `test/js_jsoo/test_eta_jsoo.ml` instantiates the same suite for Node CPS.

Focused evidence commands passed during construction:

```text
nix develop -c dune runtest test/core_eio --force
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

The twelve “seeded” cases are fixed scheduler orderings, not simultaneous
cross-domain stress. Their diagnostic value is forcing resume-before-park,
resume-before-cancel, and cancel-claim-before-late-resume on both schedulers.

Review criteria (1 = reject, 5 = approve):

- Can the new call site be understood without knowing `Runtime_contract`?
- Is callback and canceler ownership obvious?
- Do the answers in `QUESTIONS.md` follow from `effect.mli` without inspecting
  `effect_core.ml`?
