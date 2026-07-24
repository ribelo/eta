# DX-E30 Journal — `Eta_js.from_js_promise`

Branch: `research/dx-e30-from-js-promise`
Phase: queued candidate (post-Phase-D)

## Predictions (sealed)

Sealed before any E30 interface, implementation, test, documentation, red-team,
or report edit. This file is the prediction record and will not be edited after
the predictions commit; wrong predictions remain as evidence. The orchestrator's
sealed set on master has not been read (fenced).

### Design question 1 — signature and rejection mapping

**Sealed answer.**

```ocaml
val from_js_promise :
  ?on_cancel:(unit -> unit) ->
  on_reject:(Js_of_ocaml.Js.Unsafe.any -> 'err) ->
  Js_of_ocaml.Js.Unsafe.any ->
  ('a, 'err) Effect.t
```

Evidence gathered before sealing:

- js_of_ocaml 6.3.2 ships **no** `Js.Promise` binding module: `js.mli`
  contains only `Opt`, `Optdef`, `Js_error`, `Unsafe` modules and zero
  case-insensitive matches for "promise". Handlers attach via
  `Js.Unsafe.meth_call promise "then" [| on_fulfilled; on_rejected |]`.
- The rejection value delivered to the rejection callback is the **raw JS
  value**, represented as `Js.Unsafe.any` (`type any = top t`). JavaScript
  rejection is untyped: `Promise.reject(42)` delivers the number `42`, not an
  `Error`. Therefore the honest mapper shape is
  `on_reject:(Js.Unsafe.any -> 'err)` — the caller owns decoding.
- The input promise is also `Js.Unsafe.any`: the only in-repo producer
  (`Unsafe.fun_call fetch ...` in `lib/http_js/eta_http_js.ml`) yields `any`,
  and forcing callers through a phantom-typed promise wrapper would add a
  coercion step with no runtime content. The success type `'a` is a
  caller-asserted FFI boundary claim, exactly like `Js.Unsafe.coerce`.
- Convenience variant: **not justified**. The only in-repo usage of the shape
  is `await_host_promise` in `lib/http_js/eta_http_js.ml`, which maps
  rejections to `js_string` inside its own `Host_api_error` taxonomy. That is
  one consumer with adapter-specific policy, not evidence for a facade-level
  string convenience. General form alone ships.
- Mapper name: **`on_reject`** — matches the JS vocabulary ("rejection
  reason") and the existing `?on_cancel` naming convention in
  `Eta_jsoo.Private.await`.

### Design question 2 — cancellation / abort hook

**Sealed answer: `?on_cancel:(unit -> unit)` is included in v1.**

Evidence: a real in-repo consumer exists **today**.
`lib/http_js/eta_http_js.ml` `start_fetch` (line ~331) wires
`~on_cancel:(fun () -> controller.abort())` through its hand-rolled
`await_host_promise` — the AbortController lane is live code, not a
hypothetical. The hook shape `(unit -> unit)` matches the existing
`Eta_jsoo.Private.await ~on_cancel` convention and maps onto
`Effect.async`'s optional canceler as `Some (Effect.sync on_cancel)`.

Semantics to be documented: JS promises are not cancellable. Interruption
detaches the waiter (the async state machine claims the interruption; later
settlement calls `resume`, which is dropped silently — no crash, no
double-resume), runs `on_cancel` at most once and uninterruptibly, and the
host computation keeps running.

### Design question 3 — non-thenable at register time

**Sealed answer: defect.** A non-thenable raises `invalid_arg` inside
registration, which the `Effect.async` contract captures as `Cause.Die`.

Justification from who produces the bad value: the value **exists** — this is
not a missing host capability (ADR 0001's typed `Host_api_unavailable` covers
absent `fetch`/`AbortController`, a host-environment condition the consumer
checks separately). A non-thenable means the caller's `Unsafe` coercion forged
the promise boundary — a defect in the interop glue, per Eta's
precondition-violation rule (raise immediately; fail loudly, never default or
skip). Routing it to `on_reject` would lie (it is not a rejection); a second
mapper argument would bloat the signature past the doc budget for a case that
honest callers cannot reach. Register-raise → `Cause.Die` is already the
contract's loud path and costs zero new surface.

### Predicted mechanism

`Effect.async ~register` where `register resume`:

1. reads `promise##then` via `Js.Unsafe.get`, checks
   `Js.typeof` is `"function"`, else `invalid_arg` (→ `Cause.Die`);
2. wraps `on_fulfilled = fun v -> resume (Exit.Ok v)` and
   `on_rejected = fun r -> resume (Exit.Error (Cause.fail (on_reject r)))`
   with `Js.wrap_callback`;
3. attaches both synchronously via `Unsafe.meth_call promise "then"` —
   synchronous attachment inside cancellation-protected registration means no
   unhandled-rejection window and no lost wakeup for already-settled promises
   (microtask delivery lands on E13's latched runtime promise);
4. returns `Option.map (fun f -> Effect.sync f) on_cancel`.

### Predicted census / footgun deltas

| Census | Before | Predicted delta |
| --- | ---: | ---: |
| `eta_js` facade top-level items (22 module aliases + `val version` = 23) | 23 | **+1** (24) |
| Facade "interop" cluster | 0 clusters | **+1 cluster, founded with 1 member** |
| `eta_js` facade external dependencies | eta, eta_jsoo, js_of_ocaml | **+0** |
| New footguns | — | **+0** (detach/drop semantics are documented contract edges, same accounting as E13) |
| `.mli` contract size (val + doc comment) | — | **≤ 12 lines** |

### Risk most expected to bite

**Non-`Error` rejection fidelity.** `Promise.reject(42)` must deliver the raw
number through `Js.wrap_callback` to the OCaml mapper unchanged; coercing a JS
number to OCaml `int` via `Unsafe.coerce` relies on jsoo's int representation,
and if the fidelity probe fails the mapper signature (not its shape) may need
re-examination. Secondary risk: already-settled promise microtask timing
against CPS parking (E13's latch should make this a non-event; the probe will
confirm). Not expected to bite: `Effect.async` contract changes — E13's
guarantees cover every edge in this experiment's contract.

### Predicted test list (test/js_jsoo/test_eta_js_jsoo.ml)

1. resolve → `Ok` value (`Promise.resolve` via host).
2. reject with `Error` → typed failure via `on_reject`.
3. `Promise.reject(42)` → raw value reaches `on_reject` unchanged.
4. interrupt while pending → `on_timeout` wins, `on_cancel` ran once, later
   forced resolution dropped silently (no crash, no double-resume).
5. already-settled promise → resolves without lost wakeup.
6. non-thenable (forged `{then: 1}` and `{}`) → `Cause.Die`, never a hang.
7. reject-after-detach → no unhandled rejection (host handlers stay attached;
   a process-level `unhandledRejection` sentinel fails the suite if one fires).

### Hypothesis space

| Candidate | Strongest case | Evidence needed to win | Falsifier | Predicted status |
| --- | --- | --- | --- | --- |
| A. `?on_cancel` + `on_reject` general form, defect on non-thenable | Typed-failure culture; matches the one live consumer exactly | All 7 tests pass | Any test forces a wider signature | **Accept** |
| B. General form + string convenience variant | Fewer call-site characters | A second in-repo consumer with the same string policy | Only one consumer, with its own taxonomy | **Reject** (no usage evidence) |
| C. Typed host-policy failure for non-thenable | ADR 0001 analogy | Show the bad value is a host-environment condition | Value exists; precondition violation is caller-side | **Reject** (defect is the honest shape) |
| D. Phantom-typed `'a promise` input | Compile-time boundary assertion | Show call sites gain safety without extra coercions | Only producer yields `Unsafe.any`; phantom is decorative | **Reject** (no runtime content) |

## Follow-up 1 micro-predictions (sealed 2026-07-24)

This append-only section is sealed before R1–R6 implementation. It does not
rewrite the original predictions; where review disproved prior evidence, the
correction is explicit.

### Review corrections accepted before rework

- **R1 is a real semantic defect.** The original implementation executes
  `on_reject` in a `Js.wrap_callback`. A raising mapper prevents `resume`, can
  strand the Eta waiter, and rejects the ignored `.then` child promise. The
  original report's broad no-hang/no-unhandled-rejection claim was wrong for
  raising mappers.
- **R2 is a vacuous test.** The original `deferred_promise` discarded the JS
  reject callback. Its returned handle was always the fulfiller, so the test
  named “reject after detach” fulfilled with `unit`; it proved neither late
  rejection nor the unhandled-rejection claim. The original journal's test
  prediction, report evidence row, and red-team auxiliary verdict overstated
  the evidence.

### R1–R6 sealed predictions

| Finding | Predicted fix | Predicted executable result |
| --- | --- | --- |
| R1 mapper in host context | Resume only raw internal `` `Fulfilled`` / `` `Rejected`` settlements inside JS callbacks; decode rejection afterward through `Effect.sync` then `Effect.fail` | Raising mapper becomes `Cause.Die`; no hang or unhandled child rejection; mapper never runs after interruption |
| R2 vacuous reject helper | Capture and expose both JS resolver and rejector | The late-reject test performs a real JS rejection and the process `unhandledRejection` sentinel stays silent |
| R3 coverage | Add pending-success-after-registration, raising-mapper, mapper-not-run-after-detach, and explicit first-settlement tests | All named tests pass with the completion sentinel armed |
| R4 contract | Replace “host computation keeps running” with precise Eta ownership: Eta does not cancel it; handlers remain attached; `on_cancel` may request host cancellation. State unchecked caller assertion for success type | Public signature unchanged; teach-back no longer implies abort is impossible |
| R5 registry | Add one external-suite row per new `eta_js.mli` law, with exact spans and named Node tests | No unregistered new law-bearing prose remains |
| R6 consumer | Change `eta_http_js` dependency from `eta_jsoo` to `eta_js`; implement `await_host_promise` with `Eta_js.from_js_promise` | Existing HTTP JS suite passes; direct private-promise bridge and `Host_promise_rejected` exception disappear |

### Mechanism prediction

The adapter's async leaf will produce a raw internal settlement:

```ocaml
[ `Fulfilled of 'a | `Rejected of Js.Unsafe.any ]
```

No caller function executes in either JS callback. `Effect.bind` runs only for
the winning, still-attached settlement. Rejection mapping runs under
`Effect.sync`, so mapper exceptions follow ordinary Eta capture as `Cause.Die`;
interruption drops the continuation before mapping, leaving the counter at
zero for late rejection. The internal variant cannot escape the implementation
and the public signature remains unchanged.

### Predicted deviations and risks

- The prior report recommendation is suspended until all findings and all five
  gates pass; the append-only rework report will supersede it.
- `eta_http_js` migration should be mechanical because it already implements
  the same `?on_cancel` and rejection mapping. The only anticipated compile
  risk is polymorphic inference around the internal settlement variant.
- Law rows will use the post-edit exact `eta_js.mli` line span and registered
  Node test names rather than claiming qcheck coverage.

## Follow-up 2 micro-predictions (sealed 2026-07-24)

This append-only section is sealed before S1–S5 implementation. It preserves
both prior rounds and records the expected repair independently of the result.

| Finding | Sealed prediction | Falsifying evidence |
| --- | --- | --- |
| S1 package metadata | `eta_http_js` replaces direct `eta_jsoo` with `eta_js` in `dune-project`; Dune regenerates the same dependency change in `eta_http_js.opam`; the mainline source-pin list adds `eta_js` while retaining `eta_jsoo` as `eta_js`'s package dependency | Exact `-p eta_http_js @install` still cannot resolve `eta_js` |
| S2 non-discriminating native Promise | Replace the native-Promise first-wins case with adversarial thenables whose `then` invokes both callbacks synchronously, once fulfillment-first and once rejection-first; each order observes only its first branch and the losing rejection mapper never runs | Either second callback changes the Eta exit or loser-side mapper/callback state changes |
| S3 synchronous-attach precision | The adversarial `then` records at invocation that both supplied arguments have JS type `function`; because it invokes them before returning, this directly observes both handlers at registration call time rather than merely before Node's unhandled-rejection deadline | Either argument is absent/non-callable, or `then` is not invoked during registration |
| S4 unchecked success-type row | Add a registry row with a **static observation boundary**: the public signature's result `'a` is unconstrained by the `Js.Unsafe.any` input, and numeric pending/already-settled tests demonstrate the raw boundary without claiming runtime type validation | Signature gains a checked decoder or ties `'a` to a typed promise input |
| S5 Fetch taxonomy | Document that migrated `eta_http_js` treats a non-thenable host return as `Cause.Die`, while actual promise rejection remains typed `Host_api_error` | Consumer still catches non-thenable as typed failure or docs imply it does |

### Predicted gate outcome

After package metadata regeneration, the exact new gate

```sh
nix develop .#mainline -c dune build --build-dir=_build-mainline \
  -p eta_http_js @install
```

will pass in addition to all five original gates and focused `test/js_jsoo
 test/http_js`. The likely risk is package-source pin ordering rather than code:
`eta_js` must be present in the mainline pin set before Dune builds
`eta_http_js`; `eta_jsoo` remains pinned because `eta_js` depends on it.
