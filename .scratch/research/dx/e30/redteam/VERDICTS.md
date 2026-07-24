# DX-E30 Red-Team — `Eta_js.from_js_promise`

Branch: `research/dx-e30-from-js-promise`
Method: adversarial probes against the shipped adapter, executed under Node via
`nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force`.
All executable witnesses live in `test/js_jsoo/test_eta_js_jsoo.ml`; two
process-level sentinels arm the whole suite: a `beforeExit` completion sentinel
(any lost wakeup or hang fails the run) and an `unhandledRejection` sentinel
(any unhandled host rejection fails the run). Both stayed silent.

## Attack (a): forged non-thenable → loud failure, never a hang

**Verdict: HELD.**

Two forged shapes were handed to the adapter:

- `{}` (`then` absent),
- `{then: 1}` (`then` present but not callable).

Witness: `eta_js from_js_promise non-thenable dies`. Both produce
`Exit.Error` with a non-empty `Cause.defects` (registration raises
`invalid_arg`, captured as `Cause.Die` by the `Effect.async` contract) —
synchronously, so there is no park and no possible hang. The `beforeExit`
sentinel confirms the chain reached completion.

Adjacent attack not separately probed: a thenable whose `then` throws when
called. This is the register-raises path, covered authoritatively by the E13
shared suite cases `async register raise becomes die` and `async register
raise wins after synchronous resume`, which run unchanged on the jsoo track
in `test_eta_jsoo.ml`.

## Attack (b): interrupt during pending, then force the promise to resolve → dropped silently

**Verdict: HELD.**

Witness: `eta_js from_js_promise interrupt detaches`. A deferred host promise
is awaited under `timeout_as (ms 5)`. Observed: the timeout wins; `on_cancel`
runs exactly once; the test then forces host resolution (`js_resolve 7`) and
waits 10 ms past it. No crash, no second resume, no stranded waiter — the
single completion is confirmed by the `beforeExit` sentinel. The late `resume`
call is dropped by the async atomic state (interruption already claimed), and
the host computation is untouched: the JS promise itself still settled
normally, matching the documented "host computation keeps running" semantics.

## Attack (c): `Promise.reject(42)` (non-`Error` rejection) fidelity

**Verdict: HELD.**

Witness: `eta_js from_js_promise non-error rejection fidelity`. The rejection
callback receives the raw host value as `Js.Unsafe.any`; the test mapper
decodes it as a JS number and observes exactly `42.0`. No `Error` wrapping, no
string coercion, no information loss is imposed by the adapter — decoding
policy belongs to the caller's `on_reject`.

## Auxiliary attack: rejection after detach → unhandled rejection?

**Verdict: HELD.**

Witness: `eta_js from_js_promise reject after detach is handled`. After
interruption detaches the waiter, the host promise is force-rejected. Because
`from_js_promise` attaches both handlers synchronously during registration and
never removes them, the late rejection is still handled host-side; the
`unhandledRejection` sentinel did not fire. A hand-rolled detach that removed
or never attached the rejection handler would have tripped it.
