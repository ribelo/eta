# V-Let-At Results

## Method Note

P1a and P1b metrics are computed from hand-formatted snippet strings embedded in the runnable fixtures, not from `ocamlformat` output. This limits the precision of absolute line and indentation counts. The snippets are backed by compiled OCaml functions in `p1_consumer_fixture.ml` and `p1b_direct_acquire.ml`, so the comparisons still test real expression shapes. Treat the numbers as directional evidence, especially where the difference is a local-wrapper tax or a whole callback ladder, not as formatter-stable exact values.

## Cross-Tab

| Criteria | H-A status quo | H-B CPS companion | H-C `let@` only | H-D both | H-E CPS-only replacement | H-F cookbook only |
| --- | --- | --- | --- | --- | --- | --- |
| P1a pre-wrapped consumer lines | 4 | same as H-A if no direct acquire participates | 4 | same as H-C if no direct acquire participates | out of scope | 5 |
| P1b direct body-bounded lines | 5 | 5 | 9 | 7 | not tested as replacement | 10-ish local syntax + wrapper |
| P1b mixed consumer lines | 8 | 8 | 11 | 9 | not tested as replacement | local syntax + wrapper |
| Binder visual flow | Binder after callee | Binder after companion | Binder first for pre-wrapped sites; wrapper tax for direct sites | Binder first for pre-wrapped and direct sites | Binder after companion | Binder first after local definition |
| Release-timing clarity | Scope-end `acquire_release` explicit | Body-end callback explicit | Body-end only after local wrapper | Body-end callback explicit with `let@` | Breaking replacement | Depends on local helper |
| Misuse-error clarity (P2) | N/A | N/A | acceptable | acceptable | N/A | acceptable |
| Soundness preserved (P3) | yes | yes | yes | yes | not tested as replacement | yes, same as H-C |
| Naming clarity (P4) | no new name | `Effect.with_resource` accepted | `let@` in `Eta.Syntax` | `let@` + `Effect.with_resource` accepted | `use` rejected | local one-liner |
| Multi-binder API impact (P5) | none | none | 0 `lib/` changes; downstream convention recommended | 0 `lib/` changes; downstream convention recommended | breaking / out of scope | 0 `lib/` changes |
| Rank-2 inconsistency (P6) | low | low | low | low | low | low |
| Prior-art alignment (P7) | Eio-aligned | Effect-TS/ZIO/Cats-aligned | Containers/Eio-aligned | Effect-TS/ZIO-aligned | partially Cats-aligned, not Eta-aligned | Containers cookbook-aligned |
| Public API surface delta | 0 | +1 Effect symbol | +1 Syntax symbol | +2 symbols | breaking replacement | 0 |
| Final status | Dominated | Dominated by H-D | Dominated by H-D | Accepted | Out of scope / rejected | Dominated |

P2 footnotes:

- `let@ x = Effect.pure 1`: expected `('b -> 'c) -> 'd`, got Eta effect.
- `let* x = with_thing`: expected Eta effect, got `(int -> 'a) -> 'a`.
- mixed body: expected Eta effect, got `int`.

P3 footnotes:

- Nonportable Eta-effect fixtures are positive controls: they prove `let@` and the companion do not relax existing gates.
- `Domain.Safe.spawn` capture rejects `effect` as nonportable.
- local borrow capture/escape fixtures reject values at the local boundary.
- unique double-use fixture rejects the second consume as already used unique.
- `Portable.Atomic` publish rejects `Some effect` because the contained Eta effect is nonportable.

## P1b Direct-Acquire Result

P1b examined three body-bounded direct `Effect.acquire_release` sites from `lib/` plus one mixed consumer fixture, and one scope-end control:

- `lib/eta/semaphore.ml` `with_permits`: fair companion candidate.
- `lib/eta/pubsub.ml` `subscribe`: fair companion candidate.
- `lib/http/body/source.ml` `with_owned_stream`: fair companion candidate.
- mixed downstream consumer: pre-wrapped `with_client`/`with_monitor` plus direct stream acquire.
- `lib/eta/pool.ml` `with_acquire_guard`: control; release is tied to surrounding scope and can be disarmed/replaced, so it should stay value-returning.

H-D saves two lines against H-C on every fair direct-acquire site because H-C must introduce a local CPS wrapper before `let@` can bind the resource. The mixed consumer fixture shows the same local-wrapper tax. That is enough to accept the combined surface: `let@` handles existing `with_*` functions, and `Effect.with_resource` handles direct body-bounded acquire/use/release sites.

## Verdict Diary

V-Let-At-1 - Ship `let@` in `Eta.Syntax`.
Status: ACCEPT.
Decision: Add `( let@ ) : (('a -> 'b) -> 'c) -> ('a -> 'b) -> 'c` to `Eta.Syntax`.
Evidence: P1a H-C gives binder-first layout for pre-wrapped CPS chains; P1b H-D keeps that layout when direct `acquire_release` participates; P2 errors are acceptable; P3 shows no soundness relaxation.
Counterevidence considered: H-F avoids public API growth with a local one-liner. The public symbol still wins because Eta already centralizes binding operators in `Eta.Syntax` and repeated downstream resource ladders should not carry local syntax boilerplate.
Remaining uncertainty: Larger downstream codebases may reveal mixed `let@` / rank-2 supervisor ladders not present here.
Recommendation for production: Implement the binding operator in `lib/eta/syntax.ml` and `lib/eta/syntax.mli`.
Confidence: Medium-high.
Would change if: P2-style errors are shown to be unrecoverable for Eta users, or a larger consumer corpus shows frequent `Supervisor.scoped` alternation in the same ladder.

V-Let-At-2 - Ship `Effect.with_resource` as the CPS companion.
Status: ACCEPT.
Decision: Add `Effect.with_resource ~acquire ~release body`, implemented over `Effect.acquire_release`, for body-bounded acquire/use/release code. Keep `Effect.acquire_release` for value-returning and scope-end-release cases.
Evidence: P1b shows four fair body-bounded sites where H-D avoids H-C's local wrapper tax, including a mixed consumer fixture. P4 pins `Effect.with_resource` as the least surprising name. P3 shows the companion preserves Eta effect nonportability and local/unique gates.
Counterevidence considered: H-B alone does not solve the original pre-wrapped CPS ladder, and some direct `acquire_release` sites such as `pool.with_acquire_guard` need scope-end semantics and should not use the companion.
Remaining uncertainty: Exact formatting may shift under `ocamlformat`, but the local-wrapper requirement for H-C is semantic and will remain.
Recommendation for production: Ship `Effect.with_resource` together with `let@`; document that it is for body-bounded use, not a replacement for `acquire_release`.
Confidence: Medium. The new fixture closes the previous denominator problem and includes a scope-end control.
Would change if: P3 soundness fails after production implementation, or downstream examples show the companion being used incorrectly for scope-end finalizers often enough that docs cannot prevent misuse.

V-Let-At-3 - Recommend single-binder `with_*` callbacks, not a mechanical record-pack mandate.
Status: ACCEPT.
Decision: Downstream Eta consumers should shape `with_*` callbacks around one binder. Use a record when multiple callback values are one named resource/session.
Evidence: P5 finds 0 cascading `lib/` API changes and a natural record shape for the reported `with_record_stream` case.
Counterevidence considered: Record packing can allocate and can hide unrelated values behind a fake type. The recommendation is therefore semantic, not absolute.
Remaining uncertainty: No microbench was run because P5 found no required Eta-core multi-binder change.
Recommendation for production: Document this as a convention after implementation approval, not as a type-level Eta rule.
Confidence: Medium.
Would change if: A hot-path consumer fixture shows record packing creates observable allocation or requires changing more than 5 Eta-core APIs.

V-Let-At-4 - Document `Supervisor.scoped` as the rank-2 holdout.
Status: ACCEPT.
Decision: Consumers should be told that `Supervisor.scoped` intentionally does not fit `let@` because rank-2 scoping prevents child handles escaping.
Evidence: P6 found 15 supervisor call sites and no common visual ladder alternating `let@`-eligible `with_*` calls with `Supervisor.scoped` in the same body. P3 separately confirms mode/scope boundaries remain enforced.
Counterevidence considered: `lib/stream/eta_stream.ml` has functions where `acquire_release` setup and supervisor scoping both appear, so the inconsistency is real, just not common as a user-facing ladder.
Remaining uncertainty: More application code could mix supervisors and resource callbacks more often than Eta core/tests.
Recommendation for production: Mention the holdout in cookbook/docs after implementation; do not reshape `Supervisor.scoped`.
Confidence: Medium-high.
Would change if: A consumer corpus shows frequent mixed ladders where the rank-2 holdout dominates readability.

## What Evidence Would Change This Verdict

- Reopen `let@` if OCaml error transcripts from realistic users are materially worse than P2, or if a broader corpus shows `let@` and `let*` confusion causing wrong successful programs rather than compile errors.
- Reopen `Effect.with_resource` if production P3 soundness regresses, or if real use shows it commonly obscures required scope-end release timing.
- Reopen the single-binder convention if record packing in a hot callback path shows measurable allocation or forces >5 cascading `lib/` API changes.
- Reopen the rank-2 documentation verdict if real consumer functions commonly interleave `let@` resource ladders and `Supervisor.scoped` blocks.

## Verification Commands

```text
nix develop -c dune build scratch/eta_research/let_at_and_with_resource/p1_consumer_fixture.exe scratch/eta_research/let_at_and_with_resource/p1b_direct_acquire.exe scratch/eta_research/let_at_and_with_resource/p3_soundness_positive.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p1_consumer_fixture.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p1b_direct_acquire.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p3_soundness_positive.exe
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p2_misuse/run.sh
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p3_soundness/run.sh _build/default/lib/eta/eta.cmxa
```

Plain `dune build` outside `nix develop` failed because the local environment did not provide the pinned `portable` library. A broad `nix develop -c dune build` is blocked by pre-existing negative fixtures under `scratch/eta_research/scoped_sessions`; the lab-specific gates above pass.
