# V-Let-At Research Lab

This lab decides whether Eta should expose `let@` in `Eta.Syntax`, add a CPS-shaped companion to `Effect.acquire_release`, and recommend a downstream `with_*` callback convention.

## Status

Research verdict: ship `let@` in `Eta.Syntax` and ship `Effect.with_resource` as the CPS companion to `Effect.acquire_release`; recommend single-binder downstream `with_*` callbacks where the callback value has a real name; document that `Supervisor.scoped` is a rank-2 holdout and is intentionally not flattened by `let@`.

Implementation is out of scope for this worktree. No files under `lib/` were edited.

## Artifacts

- `OBJECTIVE.md` - original objective.
- `prior_art.md` - P0 orientation notes.
- `p1_consumer_fixture.ml` - synthetic 4-deep consumer chain with H-A through H-F rewrites.
- `p1_consumer_fixture/run.log` - P1 build/run log and metrics.
- `p1b_direct_acquire.ml` - direct `Effect.acquire_release` and mixed consumer fixture.
- `p1b_direct_acquire/` - P1b results and run log.
- `p2_misuse/` - three misuse fixtures and `results.md` with compiler errors.
- `p3_soundness/` - three compile-fail mode-safety fixtures, `run.sh`, and `results.md`.
- `p4_naming/coverage.md` - name x call-site coverage.
- `p5_multibinder/results.md` - callback binder convention probe.
- `p6_rank2_tax/results.md` - rank-2 inconsistency count.
- `results.md` - cross-tab and verdict diary.
- `adr.md` - ADR draft for promotion after planner approval.

## Hypothesis Ledger

| ID | Candidate | Current status | Evidence |
| --- | --- | --- | --- |
| H-A | Status quo: `acquire_release` only; consumers compose `@@ fun x ->` | Dominated | P1a preserves 4-line count in the synthetic pre-wrapped consumer, but keeps callback binder after the callee. P1b shows direct acquire sites remain bind-shaped and mixed consumer code cannot get uniform binder-first layout without a companion. |
| H-B | Add CPS `Effect.with_resource`, no `let@` | Dominated | P1b shows H-B is semantically useful on body-bounded direct acquire sites, but without `let@` it does not solve the original pre-wrapped CPS ladder. Dominated by H-D. |
| H-C | Add `let@` to `Eta.Syntax`, no new function | Dominated | P1a H-C is strong for pre-wrapped `with_*` ladders. P1b shows direct acquire sites pay a local wrapper tax: 9 lines versus H-D's 7 on each body-bounded direct site, and 11 versus 9 in the mixed consumer fixture. |
| H-D | Add both `let@` and CPS companion | Accepted | P1a gives flat layout for existing `with_*`; P1b gives a real win on direct body-bounded acquire sites and mixed consumer code; P2/P3 do not disprove the combined surface. |
| H-E | Replace `acquire_release` with CPS-only `Effect.use` | Out of scope / rejected | The objective forbids reshaping `acquire_release`. P1b includes a scope-end control where value-returning `acquire_release` remains the right primitive, so a CPS-only replacement would be a semantic regression. |
| H-F | Ship neither; document local `let@` cookbook one-liner | Dominated | P1a H-F is viable for pre-wrapped sites, but every file pays the one-line local definition and P1b still needs local wrappers for direct acquire sites. Eta already owns `Eta.Syntax` as the place for binding operators. |

## Re-run

```sh
nix develop -c dune build scratch/eta_research/let_at_and_with_resource/p1_consumer_fixture.exe scratch/eta_research/let_at_and_with_resource/p3_soundness_positive.exe
nix develop -c dune build scratch/eta_research/let_at_and_with_resource/p1b_direct_acquire.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p1_consumer_fixture.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p1b_direct_acquire.exe
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p3_soundness_positive.exe
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p2_misuse/run.sh
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p3_soundness/run.sh _build/default/lib/eta/eta.cmxa
```
