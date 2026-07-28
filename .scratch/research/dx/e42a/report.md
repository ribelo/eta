# DX-E42a report — privacy moves (daemon, Expert, supervisor builders)

Evidence vs. sealed predictions (`journal.md`, commit `6bd63296`, unedited).

## Gates

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (full log: 0 FAIL / 0 Fatal) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS (plus explicit `lib/js_stream lib/js`) |

## Scored predictions

| # | prediction | verdict | evidence |
| --- | --- | --- | --- |
| P1 | SPI shape: `Eta.Spi` in root `eta`, daemon + Expert subgroup, four sentences, eta_js alias, zero dune/opam churn, verbatim impls, leaf names kept | **HIT** | `lib/eta/spi.ml{,i}`; dossier §2/§4; no dune file touched except `examples/dune` (example rename) |
| P2 | supervisor: nine builders out via private module, two stay, types stay, `supervisor.mli` unchanged, no STOP | **HIT with one miss** | as predicted, except "mli deletion plus rewiring, not new code": the sealed facade forced 5 typed `%identity` bridges + 10 wrappers in `effect_erasure.ml` (new code, ~75 lines) |
| P3 | size: 150–260 code lines; 45–55 files (24 lib / ~20 test / 4 examples / 2 docs / 1 registry) | **files HIT, lines MISS** | 55 files (25 lib / 24 test / 4 examples / 2 docs) + registry. Code line-events ≈ 536+/437− (≈563 excluding moved blocks): test-surface breadth (24 files) and the unpredicted erasure bridge drove it over band. Objective's own ~170 was likewise exceeded |
| P4 | census: −10 vals, −1 submodule, +1 SPI module; SPI = 1 val + 1 submodule (1 type + 13 vals); eta_js +1 alias | **HIT (exact)** | 129→119 vals, 1→0 submodules; dossier §6 |
| P5 | registry: R41/R42 + CD-E22-018 → spi.mli; 16 M + 17 R + 6 CD drift rows; totals 120→118/183→181, +spi 0/2/2, total 285; no orphans/debt/claim loss | **HIT** | commit `8ef34a9d`, content-verified line mapping; the off-by-one from the yield-doc rewrite was caught by the verifier before writing |
| P6 | example: delete `daemon_drain.ml`, `background_shutdown.ml` teaches application-scope drain; area rename, count stays 64; `services.md` untouched | **HIT** | dossier §5; api_dx suite green |
| P7 | parity: snapshot zero-diff; suite green with namespace swaps only | **HIT** | `expected_descriptions.txt` untouched; only deliberate api_dx example rework differs |
| P8 | considered-and-kept: `Runtime.drain` stays; leaf names stay; red-team: SPI reachable but looks wrong, not more inviting | **HIT** | dossier §9 red-team record |

Score: 7/8 clean hits; P2 hit with a mechanistic miss (erasure bridge);
P3 file counts hit, line band under-predicted.

## Deviations (all judged minor; none changed the design)

1. **Erasure bridges** (`effect_erasure.ml`): the sealed facade makes
   `Effect.supervisor_scope` nominally distinct from the private GADT, so
   `Supervisor`'s builders needed typed `%identity` bridges — the module
   that exists for exactly this. `spi.ml` likewise casts at its boundary
   (`daemon`, `Expert.make/eval/eval_in_scope`). No public surface change;
   `supervisor.mli` byte-identical; `Effect.supervisor_scoped` still
   composes with `Supervisor.Scope` builders. Alternative rejected:
   abstracting `Supervisor`'s public type manifests (less code, but narrows
   a public manifest and breaks that composition — more than a namespace
   move).
2. **Yield group doc** rewritten to singular (2→3 lines) for honesty after
   the nine deletions; absorbed into the re-anchor drift map.
3. **api_dx assertion calibrated** (`let_star` 2→1) after the suite caught
   it — test-authoring slip, fixed in the same change.
4. **Two mli doc references** (`runtime.mli`, `runtime_contract.mli`)
   re-pointed to `Spi.Expert` (in place, no drift).

## Stop-condition check

Objective §"The change": STOP if anything besides `Supervisor` and tests
uses the nine builders. Verified by repo-wide grep before the move: only
`lib/eta/supervisor.ml`. No STOP. No §4.6 involvement (finalizer causes
untouched).

## Recommendation

Ready for review. The three audit claims (§6.2–6.4) are discharged with
zero semantic delta, the facade census matches the sealed expectation
exactly, the law registry is re-anchored with content verification, and the
example now teaches the audit's application-scope pattern. One open
question for the reviewer (not blocking): whether `supervisor_scoped` /
`supervisor_yield` should follow the nine builders in a later pass — the
mechanics now make that a 6-line mli deletion, and the census impact would
be −2 further vals.

## Follow-up 1 (promote-with-fixes)

Independent review: design sound, three inconsistencies blocked promotion.
All three applied; amendment `journal-followup-1.md` (journal.md stays
sealed).

1. **`Eta_js.Spi` alias removed.** One namespace restored: `eta_js` no
   longer re-exports the SPI; `eta_js_stream` consumes `Eta.Spi.Expert`
   directly with `eta` declared in `lib/js_stream/dune`, `dune-project`,
   and the regenerated `eta_js_stream.opam`. Census corrected (the
   "`Eta_js`: +1 module alias" line is gone; SPI surface is unchanged at
   14 vals). Registry: R116–R126 re-anchored −1 for the `eta_js.mli` line
   shift (content-verified, including R126's second reference).
2. **SPI eligibility doc matches its consumers.** The bullet now names
   justified Eta library/package implementation support — runtime
   backends, backend-aware leaves, and runtime-owned infrastructure — so
   the fence admits `eta_cache`/`eta_signal`/`eta_http`/`eta_stream`/
   protocol clients while keeping "not application API / no compatibility
   guarantee / not for application dependency injection" verbatim.
   Registry: R41/R42 → `spi.mli:29-31`, CD-E22-018 → `spi.mli:33-98`
   (content-verified).
3. **Example asserts what it demonstrates.** The completion assertion
   moved inside the `with_background` body after the `done_` await as
   `"worker completed before scope exit"`. Executing the example for this
   fix exposed a latent defect from the original batch: the rewritten
   example never compiled (`Eio.Promise.resolve` was passed the promise,
   not the resolver) because none of the four mandated gates build
   `@examples`. Fixed (`worker` now takes `resolve_done`);
   `dune build @examples` and `dune exec examples/background_shutdown.exe`
   both pass, printing `started=true before=false after=true`. Gate
   lesson recorded: example rewrites must build and run the example,
   not just its dune stanza.

Registered follow-up **F-E42a-1**: `Supervisor` should eventually own the
public supervisor/child/scope/body types directly over the private
representation, eliminating the five erasure bridges (no new ones); the
`%identity` invariant stays audited-only — erasure surface must not
spread.

### Parity (qualified)

The batch parity claim is qualified: `test/api_dx/api_dx_examples.ml`
intentionally changes meaning — its "proposed" pattern moved from
daemon/drain to scoped shutdown, which is the mandated example migration,
not a behavior expectation of the library. Every other test edit is a
namespace token swap; `expected_descriptions.txt` remains zero-diff; all
behavior suites pass unmodified.

### Gates (re-run after fixes)

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline lib/js lib/js_stream test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS |

### Final recommendation

Promote. The three inconsistencies are resolved at their roots (namespace,
doc, assertion), the law registry is re-anchored for both file shifts with
content verification, and all gates are green on the amended tree.
