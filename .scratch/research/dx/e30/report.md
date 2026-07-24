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

## Follow-up 2 rework — 2026-07-24

This append-only section supersedes round-1 packaging and evidence claims where
S1–S5 found them incomplete.

### V-DX-E30-014 — Blocking package repair

Status: **FIXED**.

Round 1 migrated `eta_http_js` code to `Eta_js.from_js_promise` but changed only
the Dune library stanza. That broke isolated shipped-package builds because the
package metadata still declared `eta_jsoo`, not `eta_js`. All three authoritative
locations now agree:

- `dune-project`: `eta_http_js` depends on `eta_js` (and no longer directly on
  `eta_jsoo`);
- generated `eta_http_js.opam`: regenerated by Dune and contains `eta_js`;
- `flake.nix`: mainline source-pin list includes `eta_js` between `eta_jsoo` and
  `eta_http_js`.

The exact blocking command now passes unchanged:

```sh
nix develop .#mainline -c dune build --build-dir=_build-mainline \
  -p eta_http_js @install
```

`dune -p eta_http_js` deliberately excludes sibling packages, so its Eta
dependencies must already be installed. To keep the Nix verification ABI-pure,
the shared mainline shell searches `$HOME/.cache/eta/mainline-nix/lib`, populated
from this worktree with the same Nix OCaml/js_of_ocaml toolchain:

```sh
nix develop .#mainline -c dune build \
  --build-dir=_build-mainline-deps @install
nix develop .#mainline -c dune install \
  --build-dir=_build-mainline-deps \
  --prefix="$HOME/.cache/eta/mainline-nix" \
  eta eta_http eta_jsoo eta_js
rm -rf _build-mainline-deps
```

The first post-metadata attempt correctly exposed the missing installed
`eta_js`. A broad opam site-lib bridge was rejected after the full gate detected
`ppxlib` ABI contamination; a package-curated opam bridge was also rejected
because opam js_of_ocaml 6.4.0 differed from Nix 6.3.2. The final Nix-built
prefix makes both the isolated package gate and full mainline gate pass without
mixing compiler/library assumptions. These were two bounded fix-forward probes
of the separate verification-environment failure class; neither entered the
final implementation.

### V-DX-E30-015 — Precision finding scorecard

| Finding | Resolution | Evidence | Score |
| --- | --- | --- | --- |
| S1: shipped package omitted `eta_js` | Package declaration, generated opam, and source-pin list all include `eta_js`; mainline shell uses same-toolchain installed Eta dependencies for isolated `-p` checks | Exact `-p eta_http_js @install` and full `@install` both PASS | **FIXED** |
| S2: native Promise hid later settlement | Replaced the case with two adversarial thenables. Each invokes both adapter callbacks synchronously: fulfillment→rejection and rejection→fulfillment. Exact exits and mapper counts discriminate the winner and loser. | `eta_js from_js_promise adversarial thenable first settlement wins` | **FIXED** |
| S3: R116 evidence did not prove synchronous attachment | Each adversarial `then` records, at invocation time and before returning, that both supplied arguments have JS type `function`, then calls both in that same registration stack. | R116 now points at the attach-time observation, not the Node deadline sentinel | **FIXED** |
| S4: unchecked success type lacked a row | Added R126 with an explicit static observation boundary: signature result `'a` is unconstrained by `Js.Unsafe.any`; raw numeric boundary tests are dynamic witnesses but do not claim runtime validation. | `eta_js.mli:27-31,39`; pending and already-settled tests | **FIXED** |
| S5: Fetch taxonomy change undocumented | Recipe now says non-thenable Fetch return → `Cause.Die`, while real Promise rejection → typed `Host_api_error`; added a focused HTTP regression. | `non-thenable fetch dies`; `read error maps to host API error` | **FIXED** |

### V-DX-E30-016 — Registry precision

R116 and R117 now share one genuinely discriminating adversarial test but point
to different observations:

- R116: both handler arguments are callable inside synchronous `then` invocation;
- R117: both callbacks are invoked in both orders, while exit and mapper counts
  prove only the first raw settlement wins.

R126 registers the caller-asserted success type with a static observation
boundary rather than pretending a runtime test can prove absence of validation.
Registry totals are now **125 registered external rows** and **228 total covered
rows**; `lib/js/eta_js.mli` owns 11 external rows.

### V-DX-E30-017 — Round-2 gates

Status: **ACCEPT**. Required gates after packaging commit `73097421`:

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline -p eta_http_js @install` | **PASS (new isolated package gate)** |

Additional focused consumer gate:

```sh
nix develop .#mainline -c dune runtest \
  --build-dir=_build-mainline test/js_jsoo test/http_js --force
```

Result: PASS, including adversarial callback ordering, attach-time handler
observation, `non-thenable fetch dies`, Fetch rejection mapping, and cancellation
abort behavior. After the final comment-only commit amend, the full mainline and
isolated package builds were rerun and passed again.

### V-DX-E30-018 — Micro-prediction reconciliation

| Prediction | Actual | Score |
| --- | --- | --- |
| Metadata changes in all three locations make isolated package build pass | Required same-toolchain dependency installation in addition; exact gate passes | **PARTIAL** — metadata right, setup risk underestimated |
| Adversarial thenables discriminate both settlement orders | Implemented exactly; loser mapper count 0 / winning mapper count 1 | **MATCH** |
| Attach-time handler types directly prove synchronous attachment | Both arguments observed as JS functions inside synchronous `then` | **MATCH** |
| R126 uses honest static observation boundary | Implemented exactly | **MATCH** |
| Fetch non-thenable taxonomy documented | Documented and additionally regression-tested | **MATCH + extra evidence** |
| Main risk is package source-pin ordering | Actual risk was stronger: Nix/opam ABI separation | **MISS**, corrected by Nix-built prefix |

### V-DX-E30-019 — Updated recommendation

**PROMOTE.** The shipped-package dependency graph is now correct and proven by
the exact isolated build; full mainline remains green without ABI mixing; the
first-settlement and synchronous-attachment rows now point to discriminating
runtime observations; the unchecked success claim is registered honestly; and
the Fetch taxonomy change is documented and tested. S1–S5 are closed, all six
required gates pass, and the code, package metadata, registry, docs, journal,
and report agree.

## Follow-up 3 — R116 temporal discriminator (2026-07-24)

### V-DX-E30-020 — Option choice

Status: **OPTION A.2 ACCEPTED**.

Option A.1 (marker set when `Runtime.run` returns) is invalid on this substrate:
`run_eta_jsoo` deliberately schedules its body through `schedule`, which is
`queueMicrotask` under Node (`lib/jsoo/eta_jsoo.ml:31-45,755-772`). The marker
must still be false in the initiating synchronous stack.

Option A.2 directly discriminates the MLI claim:

1. `Runtime.run` queues runtime-body microtask **M1**.
2. Before yielding, the test queues sentinel microtask **M2**.
3. The shipped adapter calls the thenable's `then` inline during registration in
   M1, so the thenable observes both callable handlers and sets its marker.
4. M2 records that marker as true.
5. A counterfactual adapter that deferred `meth_call promise "then"` from M1
   would enqueue attachment as **M3**, behind M2; M2 would record false and the
   final assertion would fail.

The test additionally asserts the marker is false immediately after
`Runtime.run`, validating the scheduler premise rather than assuming it.

### V-DX-E30-021 — Executable and registry result

Named test:

```text
eta_js from_js_promise attaches handlers in runtime body turn
```

Observed: immediate marker `false`; sentinel observation `Some true`; final Eta
result `Ok 21`. The test passes under Node CPS.

R116 now points only to this temporal test and the exact scheduler source. R117
continues to point to the separate dual-order adversarial thenable test; first
settlement and attachment timing are no longer conflated. Shifted pointers for
R118–R126 were refreshed without changing their claims or totals.

### V-DX-E30-022 — Follow-up 3 gates

| Command | Result |
| --- | --- |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force` | PASS |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |

The full mainline install, isolated `eta_http_js` package build, and HTTP suite
are unaffected: this round changes only the Node test and registry pointers.

### V-DX-E30-023 — Final recommendation

**PROMOTE.** R116 now has a named executable that fails under deferred
attachment and passes only when both handlers attach in the runtime body's
registration turn. The public claim remains unchanged because it is now proven
at the required discriminating observation boundary. All requested round-3
gates pass.
