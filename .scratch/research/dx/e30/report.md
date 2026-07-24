# DX-E30 Report — `Eta_js.from_js_promise`

Branch: `research/dx-e30-from-js-promise`
Recommendation: **PROMOTE**

## V-DX-E30-001 — Gates

Status: **ACCEPT**. All pre-registered gates run from the final worktree.

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS (all prior cases + 7 new) |

Native track green by construction: the change touches only the
jsoo-`enabled_if` facade `eta_js`, its Node test, and docs. The mainline
compiler repeated the repository's two pre-existing integer-overflow warnings;
no new warnings. First-attempt pass on every gate (zero fix-forward cycles
used), after one focused compile fix before the first gate run.

## V-DX-E30-002 — Design question answers, with evidence

**Q1 — Signature/rejection mapping. Shipped as predicted:**

```ocaml
val from_js_promise :
  ?on_cancel:(unit -> unit) ->
  on_reject:(Js_of_ocaml.Js.Unsafe.any -> 'err) ->
  Js_of_ocaml.Js.Unsafe.any ->
  ('a, 'err) Effect.t
```

Evidence: js_of_ocaml 6.3.2 ships no `Js.Promise` binding (`js.mli` module
list verified; zero promise matches), so the rejection value is the raw host
value delivered to the rejection callback — `Js.Unsafe.any`. JS rejection is
untyped (`Promise.reject(42)` is legal), and the executable fidelity probe
(`eta_js from_js_promise non-error rejection fidelity`) shows the number `42`
reaching the mapper unchanged. Decoding is therefore caller-owned:
`on_reject:(Js.Unsafe.any -> 'err)`. No convenience variant: the only in-repo
consumer of the shape (`await_host_promise` in `lib/http_js/eta_http_js.ml`)
maps rejections into its own `Host_api_error` string taxonomy — one consumer,
adapter-specific policy, no evidence for a facade-level convenience.

**Q2 — Cancellation. `?on_cancel:(unit -> unit)` shipped.**

Evidence: a real in-repo consumer exists today — `start_fetch` in
`lib/http_js/eta_http_js.ml` wires `~on_cancel` to `controller.abort()`. The
hook maps onto `Effect.async`'s optional canceler as `Some (Effect.sync f)`,
inheriting at-most-once, uninterruptible, never-after-resolution semantics.
Detach semantics documented in the `.mli`: interruption detaches the waiter,
later settlement is dropped silently, the host computation keeps running.

**Q3 — Non-thenable at register time. Defect.**

Evidence/justification: the bad value *exists* — it is not a missing host
capability (ADR 0001 typed failures cover absent `fetch`/`AbortController`,
which consumers check separately). A non-thenable means the caller's `Unsafe`
coercion forged the promise boundary: a precondition violation, which Eta's
engineering rules say must raise immediately. Registration raises
`invalid_arg`; the `Effect.async` contract captures it as `Cause.Die`. The
forged-value probe (`eta_js from_js_promise non-thenable dies`) confirms both
`{}` and `{then: 1}` die loudly and synchronously — never a hang.

## V-DX-E30-003 — Contract coverage

| Contract edge | Executable witness |
| --- | --- |
| Resolve → `Ok` | `eta_js from_js_promise resolve` |
| Reject → typed failure via mapper | `eta_js from_js_promise reject maps typed failure` |
| Non-`Error` rejection fidelity | `eta_js from_js_promise non-error rejection fidelity` |
| Interrupt while pending → detach, later resolution dropped, no double-resume | `eta_js from_js_promise interrupt detaches` |
| Already-settled promise, no lost wakeup | `eta_js from_js_promise already settled` |
| Rejection after detach stays host-handled | `eta_js from_js_promise reject after detach is handled` |
| Non-thenable → loud `Die`, never hang | `eta_js from_js_promise non-thenable dies` |
| First-settlement-wins, sync resolution, no lost wakeup, register-raise | inherited from E13's shared suite, running unchanged on jsoo in `test_eta_jsoo.ml` |

One contract edge is untriggerable through real thenables: synchronous
resolution *during* registration — JS `then` callbacks are always
microtask-deferred. The mechanism is covered by E13's
`async synchronous resolution does not deadlock` on the same track.

Suite honesty: `test_eta_js_jsoo.ml` gained the same `beforeExit` completion
sentinel `test_eta_jsoo.ml` already had (a lost wakeup can no longer
false-pass), plus an `unhandledRejection` tripwire. Both stayed silent.

## V-DX-E30-004 — Sealed-prediction scoring

| Prediction | Sealed | Actual | Score |
| --- | --- | --- | --- |
| Q1 shape (general form, `on_reject` name, no convenience) | exact signature | exact signature | **MATCH** |
| Q2 `?on_cancel` in v1 | included, `unit -> unit` | included, `unit -> unit` | **MATCH** |
| Q3 non-thenable | defect via register-raise → `Die` | defect via register-raise → `Die` | **MATCH** |
| Facade census | 23 → 24 (+1 val) | 23 → 24 (+1 val) | **MATCH** |
| Interop cluster | founded, 1 member | founded, 1 member (`from_js_promise`) | **MATCH** |
| Facade dependencies | +0 | +0 (eta, eta_jsoo, js_of_ocaml unchanged) | **MATCH** |
| Footguns | +0 | +0 (detach/drop are documented contract edges) | **MATCH** |
| `.mli` contract size | ≤ 12 lines | 13 lines (5 sig + 8 doc) | **MISS by 1** (within the "~12" tolerance) |
| Risk most expected to bite | non-`Error` rejection fidelity | **bit at compile time**: `Unsafe.coerce` is `Js.t -> Js.t` only, so the naive number decode didn't typecheck; fixed with `Js.float_of_number (Unsafe.coerce reason)`. Runtime fidelity itself held (42 observed unchanged) | **PARTIAL HIT** |

## V-DX-E30-005 — Red-team outcome

Status: **ACCEPT**. Full verdicts in `redteam/VERDICTS.md`.

| Attack | Outcome |
| --- | --- |
| (a) Forged non-thenable (`{}`, `{then: 1}`) | Loud `Cause.Die` at registration, synchronous, no hang |
| (b) Interrupt-during-pending then force resolve | Timeout wins, `on_cancel` ran exactly once, late settlement dropped silently, single completion |
| (c) `Promise.reject(42)` fidelity | Raw value reached the mapper unchanged |
| (aux) Reject after detach | No unhandled rejection; handlers stay attached |

## V-DX-E30-006 — Deviations and hypothesis ledger

Deviations from the plan: none in surface or scope. Test infrastructure
hardening (the two sentinels) was added to `test_eta_jsoo.ml`'s sibling —
in-scope, and required for the lost-wakeup and unhandled-rejection claims to
be falsifiable. No `Effect.async` changes, no http_js migration, no native
edits, no new dependencies.

| Candidate | Final status |
| --- | --- |
| A. `?on_cancel` + `on_reject` general form, defect on non-thenable | **ACCEPTED** — shipped, all 7 tests pass |
| B. General form + string convenience variant | **REJECTED** — no usage evidence (one consumer, own taxonomy) |
| C. Typed host-policy failure for non-thenable | **REJECTED** — value exists; precondition violation is caller-side; defect is the honest shape |
| D. Phantom-typed `'a promise` input | **REJECTED** — no runtime content; only in-repo producer yields `Unsafe.any` |

## V-DX-E30-007 — Recommendation

**PROMOTE.** The contract is implemented, tested, and documented within the
doc budget; every sealed design answer survived contact with the runtime; the
red-team found no hang, no unhandled rejection, no double-resume, and no
fidelity loss; all five gates pass. Neither BLOCKED condition fired:
`Effect.async` needed no changes, and js_of_ocaml's promise reality (raw
untyped rejection values) fits Eta's typed-failure culture through the
caller-named `on_reject` mapper.

## Follow-up 1 rework — 2026-07-24

This append-only section supersedes the original recommendation where review
found incorrect semantics or evidence. Historical claims above remain visible;
the following corrections are authoritative.

### V-DX-E30-008 — Original claims withdrawn

Status: **CORRECTED AFTER BLOCKING REVIEW**.

Two earlier claims were wrong:

1. The original report said the mapper path had “no hang” and “no unhandled
   child rejection.” That was true only for non-raising mappers. Because
   `on_reject reason` ran inside `Js.wrap_callback`, a mapper exception escaped
   into JavaScript before `resume`: the Eta effect could remain pending and the
   ignored `.then` child could reject unhandled. This was a real blocking
   semantic defect, not merely missing coverage.
2. The evidence row and red-team auxiliary verdict for “rejection after detach”
   were vacuous. `deferred_promise` discarded `_on_reject`; its returned handle
   always fulfilled. The test therefore never performed a host rejection and
   proved neither mapper suppression nor the `unhandledRejection` claim.

The original red-team “host computation is untouched / keeps running” wording
was also too broad when `?on_cancel` is supplied: Eta itself does not cancel host
work, but the caller-owned hook may abort it (the Fetch consumer does exactly
that).

### V-DX-E30-009 — Review-finding scorecard

| Finding | Resolution | Evidence | Score |
| --- | --- | --- | --- |
| R1: mapper ran in host callback | JS callbacks now resume only raw internal `` `Fulfilled`` / `` `Rejected`` settlements. `on_reject` runs afterward under `Effect.sync`; a raise becomes `Cause.Die`, and detached continuations never invoke it. | `eta_js from_js_promise raising mapper dies`; `eta_js from_js_promise late rejection skips mapper`; completion and `unhandledRejection` sentinels | **FIXED** |
| R2: late-reject test was vacuous | `deferred_promise` now captures distinct JS resolver and rejector callbacks; the test invokes the real rejector and asserts mapper calls = 0. | `eta_js from_js_promise late rejection skips mapper` | **FIXED** |
| R3: coverage gaps | Added pending success after registration, raising mapper, first-settlement discrimination, and late rejection with exact mapper suppression. Kept already-settled as the distinct pre-settlement case. | Four named Node tests in `test/js_jsoo/test_eta_js_jsoo.ml` | **FIXED** |
| R4: inaccurate/unchecked contract wording | MLI now states Eta does not itself cancel host work, handlers stay attached, `on_cancel` may request host cancellation, and success typing is caller-asserted/unchecked. Recipe matches. | `lib/js/eta_js.mli:32-40`; `docs/api-dx.md` | **FIXED** |
| R5: missing law rows | Added R116–R125, one registered external row per behavioral claim with exact source spans and named executable witnesses; totals updated to 124 external / 227 covered rows. | `.scratch/research/dx/e22/review/LAWS.md` | **FIXED** |
| R6: hand-rolled motivating consumer | Layering is legal (`eta_js` → `eta_jsoo`; no reverse HTTP edge). `eta_http_js` now depends on `eta_js`, uses `Eta_js.from_js_promise`, and deletes its private-promise bridge and `Host_promise_rejected` exception. | `cancellation aborts fetch` and full `test/http_js` focused suite | **FIXED** |

### V-DX-E30-010 — Reworked mechanism

The public signature is unchanged. The async registration callback contains no
user code:

```ocaml
on_fulfilled value -> resume (Exit.Ok (`Fulfilled value))
on_rejected reason -> resume (Exit.Ok (`Rejected reason))
```

A subsequent Eta `Effect.bind` interprets the winning raw settlement.
Fulfillment returns `Effect.pure value`; rejection executes
`Effect.sync (fun () -> on_reject reason) |> Effect.bind Effect.fail`.
Consequences verified under Node CPS:

- mapper exceptions are ordinary Eta defects rather than host exceptions;
- every host callback calls `resume` with raw settlement;
- interruption drops the continuation, so late rejection cannot run the mapper;
- host handlers remain attached, so late rejection is still handled by JS;
- internal variant tags do not escape and the public signature did not widen.

### V-DX-E30-011 — Rework gates

Status: **ACCEPT**. All five exact gates passed after commit `cecf096d`.

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS, including all nine adapter tests and both sentinels |

Additional consumer validation:

```sh
nix develop .#mainline -c dune runtest \
  --build-dir=_build-mainline test/js_jsoo test/http_js --force
```

Result: PASS, including `cancellation aborts fetch` after the consumer migration.
No fix-forward cycle was needed after the focused rework tests passed.

### V-DX-E30-012 — Follow-up prediction reconciliation

| Micro-prediction | Actual | Score |
| --- | --- | --- |
| Raw settlement, mapper under Eta capture | Implemented exactly | **MATCH** |
| Real reject handle; late rejection sentinel stays clean | Implemented; mapper count exactly 0 | **MATCH** |
| Four coverage additions pass | All named cases pass | **MATCH** |
| Precise cancellation and caller-asserted success prose | MLI and recipe updated | **MATCH** |
| Registry rows with external named tests | R116–R125 added | **MATCH** |
| HTTP layering permits migration | Legal; direct dependency changed from `eta_jsoo` to `eta_js`; suite passes | **MATCH** |
| Main compile risk: internal variant inference | No issue | **DID NOT BITE** |

### V-DX-E30-013 — Updated recommendation

**PROMOTE.** The blocking host-context defect and vacuous evidence are fixed;
all coverage, contract, registry, and consumer findings are closed; the raw
settlement construction makes mapper execution obey Eta's defect and
cancellation semantics; all exact gates and the focused migrated-consumer suite
pass. The code, append-only journal, corrected red-team verdict, law registry,
and this report now agree.
