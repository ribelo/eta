# Follow-up 1: DX-E28 — C3 resolved: unified admission (implement Option A)

Your escalation was correct and the audit held up under adversarial
review. The orchestrator decision (journaled as V-DX-E28-002): **Option A
— unified admission.** `objective.md` still applies except where this file
overrides it (C1/docs-only is superseded; this is now a semantics
experiment).

## The decision

`Effect.all` gains `?max_concurrent:int` (default 8 — the SAME admission
policy as `map_par`), implemented on the shared worker machinery. The
differentiation that survives is input shape, not scheduling: `all` for
prebuilt effects (rich introspection), `map_par` for lazy mapping. The
fuzzy "ready vs. collection" semantic boundary is abandoned — that was
the fuzz that made the trap unteachable.

## Contract

```ocaml
val all :
  ?max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
```

mli must state, in this vocabulary:
- collects in input order; fail-fast; at most `max_concurrent` children
  admitted at once; **omission means 8**; fewer when the list is shorter;
- `Invalid_argument` on `max_concurrent <= 0` at construction (same rule
  as `map_par`);
- **admission warning:** children must not depend on work beyond the
  bound — a child waiting on an unadmitted sibling deadlocks (name it
  plainly);
- **full fan-out recipe:** barrier/coordinator shapes that need every
  child admitted spell `~max_concurrent:(List.length effects)` (nonempty);
- introspection note: child names/footprints aggregate (that is why this
  operation exists separately from `map_par`, whose mapper is never
  forced at blueprint time).

## Required work

1. **Journal:** new sealed micro-predictions for this round (peak-8
   behavior, barrier-9 admission, introspection preservation, js_stream
   migration effects, which existing tests change behavior by design).
2. **Implementation:** shared worker scheduling for `all`. Preserve
   `concat_names`/`concurrent_footprint` aggregation and the blueprint
   construction rules (names/footprints of prebuilt children remain
   static metadata; the bound affects only the interpreter path).
3. **Migrate `lib/js_stream/eta_js_stream.ml`'s `map_effect`** from
   `Effect.all (List.map f xs)` to `Effect.map_par f xs` (its chunk
   mapping is the textbook `map_par` task; default bound).
4. **`docs/api-dx.md`:** remove the "dynamic homogeneous lists → all"
   mis-steering; one admission policy for both combinators; task-shape
   table by input shape (effects in hand → `all`; function + collection
   → `map_par`); the full-fan-out recipe.
5. **Tests** (all must exist and pass):
   - default peak concurrency of 8 for `all` (probe ≥ 9 blocked children);
   - explicit full fan-out: 9 barrier participants all admitted
     (construct a real rendezvous — every participant must be live for
     any to proceed);
   - input order under out-of-order completion; fail-fast sibling
     cancellation; cancellation/finalizer parity with the pre-change
     engine;
   - `all []` unchanged; `max_concurrent <= 0` rejected at construction;
   - introspection names/footprints of `all` preserved (E12's
     audit/describe expectations);
   - js_stream `map_effect` behavior (mainline js suite).
6. **Law registry:** rows for the new law-bearing mli claims
   (AGENTS.md policy).
7. **Semantics-change ledger** in your report: enumerate every existing
   test whose concurrency behavior changes by design (capped where
   previously unbounded — the 6–128-child sites), with a one-line
   justification each.
8. **Red-team:** (a) `all (List.map f xs)` over 10k — now bounded; the
   eta-expansion bypass is closed by construction, state the evidence;
   (b) a >8 interdependent barrier WITHOUT the explicit bound — you
   cannot test a deadlock directly; instead show the explicit-bound form
   works (positive) and assess whether the mli warning catches the
   hazard at review time.
9. **Report:** as before + scoring of BOTH prediction sets (audit round
   and this round).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/js_stream test/http_js --force
```

(Adjust the JS test targets to the real directories; js_stream is a jsoo
package and MUST be verified under mainline.) Fix-forward ≤ 3 attempts
per failure class, then BLOCKED.

## Done means

`E28 READY FOR REVIEW` / `E28 BLOCKED: <reason>` / `E28 STOP: <§4.6>`.
Same scope fence; this file and objective.md stay uncommitted.
