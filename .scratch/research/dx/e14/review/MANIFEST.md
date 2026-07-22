# DX-E14 Review Packet

Read in this order:

1. `coord-old.ml` — one-shot coordination through `Effect.Expert.make`, the
   current runtime context, scope, and `Runtime_contract` promise operations.
2. `coord-new.ml` — the same producer/consumer coordination through
   `Eta.Promise`.
3. `QUESTIONS.md` — cancellation and resolver-authority teach-back with answers.
4. `RATINGS.md` and `TECHNICAL-REVIEW.md` — independent API and correctness
   outcomes plus the corrections they caused.

Both examples are backend-neutral in intent, but only the new call site avoids
runtime substrate machinery. `Eta.Promise` is a portability fence; code whose
lifetime is deliberately Eio-only should continue using `Eio.Promise` directly.

The executable semantic evidence is shared, not copied:

- `test/core_common/promise_shared.ml` owns all programs and assertions;
- `test/core_common/promise_common_suites.ml` instantiates them for native Eio;
- `test/js_jsoo/test_eta_jsoo.ml` instantiates the same suite for Node CPS.

Focused commands passed on the reviewed implementation:

```text
nix develop -c dune exec test/core_eio/run.exe -- test Promise
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

The native command ran all six Promise cases successfully. The Node CPS output
named the same six cases and reached the `eta_jsoo ok` completion sentinel.

Review criteria (1 = reject, 5 = approve):

- Can the new call site be understood without knowing `Runtime_contract`?
- Do cancellation and scope-close outcomes follow from `promise.mli`?
- Does one shared suite provide convincing two-substrate evidence?
