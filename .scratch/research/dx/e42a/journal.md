# DX-E42a sealed predictions — privacy moves (daemon, Expert, supervisor builders)

Sealed BEFORE any code change on `research/dx-e42a-privacy-moves`.
This file is append-never: written once, committed once, never edited.
Scoring happens in the dossier/report against these predictions as written.

Scope fence honored: `.scratch/research/dx-journal.md`, `docs/research/`,
`.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`
were not read.

## P1 — SPI shape / mechanics

One namespace, per constraint (a). Prediction:

- New PUBLIC module `Eta.Spi` in the ROOT `eta` library: `lib/eta/spi.ml` +
  `lib/eta/spi.mli`. It becomes `Eta.Spi` via the existing dune wrapper; no
  dune `(modules ...)` or opam change is needed anywhere.
- Contents: `Spi.daemon` (moved from `Effect.daemon`) and
  `Spi.Expert` (submodule holding the 13 Expert vals + abstract `context`
  type, moved from `Effect.Expert`). One namespace = the `Spi` module;
  `Expert` stays a named subgroup inside it to keep call-site churn at
  `Effect.Expert.X` -> `Spi.Expert.X` (one token) and to preserve the
  existing doc grouping.
- The `spi.mli` module doc block carries the four sentences in substance:
  not application API; no compatibility guarantee; usage requires
  justification at the runtime-package level; not for application dependency
  injection.
- Name choice: `Spi` (service-provider interface). Audit-suggested
  `Eta.Private` rejected: the module must be public/installable (six sibling
  packages consume it), so "Private" would lie. `Eta.Unsafe_runtime_extension`
  rejected: nothing here is memory-unsafe; "unsafe" overclaims. A separate
  public library rejected: constraint (c) minimal churn — every consumer
  already depends on `eta`.
- JS track: `lib/js/eta_js.ml{,i}` gains `module Spi = Eta.Spi` so
  `eta_js_stream` keeps addressing the SPI through the `Eta_js` facade.
- Zero dune/opam dependency edits for all consumers.
- Implementations move VERBATIM from `effect.ml` (daemon_internal, daemon,
  Expert). Leaf names (`~leaf_name:"Effect.daemon"`) stay byte-identical, so
  `test/effect_introspection/expected_descriptions.txt` does not change.

## P2 — supervisor builders mechanics

- Exactly the nine named vals (`supervisor_pure/lift/fail/bind/start/await/
  cancel/failures/check`) leave `effect.mli`. `lib/eta/supervisor.ml`
  consumes them from the already-private `Effect_supervisor_scope` module
  (it is in `private_modules`; the builders already live there — the move is
  an mli deletion plus a rewiring, not new code).
- `supervisor_scoped` and `supervisor_yield` STAY public (the objective
  enumerates nine and the census expects −10; they remain documented
  low-level primitives in the same category as `bind`/`(>>=)`). No consumer
  outside `Supervisor` uses any of the eleven (verified by grep), so no
  §4.6-style STOP applies.
- The supervisor types (`supervisor`, `supervisor_child`,
  `supervisor_scope`, `supervisor_body`) stay public in `effect.mli`;
  `supervisor.mli` publicly aliases them. `supervisor.mli` does not change.
- `effect.ml` keeps `include Effect_supervisor_scope` (needed for the
  remaining public supervisor vals/types); the nine become hidden.

## P3 — migration size

- Objective estimate: ~170 lines across lib/test/examples.
- Prediction: code diff (lib+test+examples, excluding docs/registry) lands
  in the 150–260 line band; ~45–55 files touched total including
  docs/examples/README/LAWS.md. Roughly: 24 lib files, ~20 test files,
  4 example files, 2 docs files, 1 registry file.
- The single largest sub-diff is `test/js_jsoo/test_eta_jsoo.ml`
  (~10 Expert sites + 1 daemon) and `lib/signal/` (6 files).

## P4 — census deltas

- `Effect.mli` public vals: 129 before -> 119 after (−10: daemon + nine
  supervisor builders). Submodules: 1 (`Expert`) -> 0. Public types:
  unchanged (7 incl. `and`-declared supervisor types + `intercept` +
  `metric`).
- SPI surface: +1 top-level module `Spi`: 1 val (`daemon`) + 1 submodule
  (`Expert`: 1 abstract type + 13 vals).
- `Eta_js`: +1 aliased module member (`Spi`).
- Footguns: −1/+0. The removed footgun is "public `Effect.daemon` = a second
  execution model presented as application API". `Effect.Expert` moving to
  `Spi.Expert` is counted as the same move's framing fix, not a second
  footgun; nothing new is introduced (+0).

## P5 — law registry deltas

- Re-anchored to `lib/eta/spi.mli` spans (claims unchanged): R41, R42
  (daemon diagnostics/drain), CD-E22-018 (Expert cluster debt; description
  updated to name `Spi.Expert`; debt terms unchanged).
- Re-anchored for pure line drift inside `effect.mli` (claims and text
  unchanged, spans shifted): 16 M-rows (M28–M44), 17 R-rows (R87–R93,
  R112–R115, R166a–R166h), 6 CD-rows (CD-E22-010/011/012/013/014/017).
  Rows above the deletions (M25–M27 at 666–671, R38–R40/R138–R144 at
  677–688, etc.) do NOT shift because the `effect.mli` header comment stays
  byte-identical.
- Census totals table: `effect.mli` registered-external 120 -> 118 and
  covered 183 -> 181; NEW row `lib/eta/spi.mli` 0 direct / 2 registered /
  2 covered; totals stay 116 / 169 / 2 / 285. Header counts unchanged.
- The four-sentence SPI prose is classified NOT law-bearing (compatibility/
  usage policy, not behavior), so it needs no row; the daemon doc's two
  law sentences move verbatim and stay covered by R41/R42.
- No orphans; no new debt; no deleted claims.

## P6 — example outcome

- `examples/daemon_drain.ml` is DELETED and replaced by
  `examples/background_shutdown.ml`: the audit's recommended pattern —
  long-lived worker owned by the explicit top-level application scope via
  `Effect.with_background`, with the body signalling stop and explicitly
  awaiting worker completion inside the scope (the application-scope drain).
  No `Effect.daemon`, no `Runtime.drain`, no SPI in `examples/`.
- `examples/dune` (stanza + alias), `examples/README.md`,
  `test/api_dx/api_dx_surface.ml` file list updated for the rename.
- `test/api_dx/api_dx_examples.ml`: area `daemon_drain` renamed to
  `background_shutdown`; the "current" (manual Eio bookkeeping) snippet
  stays as the before; the "proposed" snippet teaches `with_background` +
  explicit wait; assertions updated (`Effect.with_background` == 1,
  `Effect.daemon`/`Runtime.drain`/`Eio.Fiber.fork_daemon`/`Atomic.` == 0);
  the compilable `daemon_drain_proposed` helper is replaced by a
  `background_shutdown_proposed` helper. Area count stays 64.
- `docs/api-dx.md` daemon/Expert teachings updated (see dossier);
  `docs/background-work.md` gains the SPI pointer in place of the
  `Effect.daemon` recommendation. `docs/services.md` predicted UNTOUCHED
  (it never names Expert; its runtime-services framing already matches).

## P7 — behavior parity

- Zero semantic change: implementations move verbatim; every edit outside
  `lib/eta/{spi,effect,supervisor}.ml{,i}` is a namespace token swap
  (`Effect.Expert` -> `Spi.Expert`, `Effect.daemon` -> `Spi.daemon`).
- The full native suite passes with NO expectation/snapshot regeneration;
  `expected_descriptions.txt` is untouched (leaf_name kept).
- All four gates pass: `dune build @install`, `dune runtest --force`,
  `eta-oxcaml-test-shipped`, and the mainline JS build of
  test/{cache_jsoo,js_jsoo,signal_jsoo,http_js}.

## P8 — considered-and-kept

- `Runtime.drain` STAYS public (out of scope per objective; the grill
  verdict's §6.2 "probably remove" was not adopted — recorded here as
  considered-and-kept). Its doc stays as-is.
- `~leaf_name:"Effect.daemon"` KEPT byte-identical: leaf names are
  observability operation labels, not module paths; renaming would churn the
  committed describe corpus and downstream trace filters for zero semantic
  gain. Precedent: `Supervisor.scoped` already traces as
  "Effect.supervisor_scoped".
- Red-team expectation: an application-shaped file CAN still write
  `Eta.Spi.daemon` (OCaml visibility cannot forbid it), but the namespace +
  doc block makes the wrong thing look wrong (T2): `Spi` reads as
  service-provider machinery, not application API, and the four sentences
  say so at the point of hover. Prediction: nothing in the new shape is
  MORE inviting to service-locating than before; `runtime_service` behind
  `Spi.Expert` is strictly less inviting than behind `Effect.Expert`.
