# DX-E6 Report — `Effect.Scoped.with_2` / `with_3`

## Summary

Implemented `Effect.Scoped.with_2` and `with_3` as concurrent, fail-fast
resource bootstraps over the existing `with_scope`, `acquire_release`, and `par`
machinery. A small private frame bridge is necessary: `par` children own local
finalizer scopes, so each completed child acquisition is registered through
`acquire_release` in the still-live enclosing scope before the child returns.
No runtime, switch, cancellation, or concurrency machinery changed.

The public result error row remains the acquisition/body row. Independent
release rows remain finalizer diagnostics and do not leak into it.

## Gates

All required commands were green on the final implementation/test tree:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build test/js_jsoo
```

The mainline JS build emitted its existing integer-truncation warnings and
completed successfully. Focused development gate:

```sh
nix develop -c dune runtest test/core_eio --force
```

Final result: 526 tests successful, including 11 new `Scoped` semantics tests.

## Semantics-suite evidence

The tests are in
`test/core_common/effect_resource_timeout_common_suites.ml` and therefore run
through the shared runtime-backend suite.

| Obligation | Executable evidence | Result |
|---|---|---|
| Concurrent acquisition | `test_scoped_with_2_acquires_concurrently`; both branches wait for the other to start | proven |
| `with_3` concurrency | `test_scoped_with_3_acquires_concurrently`; all three branches rendezvous | proven |
| Fail-fast sibling interruption | `test_scoped_with_2_acquire_failure_cancels_sibling` | proven |
| Partial acquire failure | acquire 1 completes, acquire 2 fails; body skipped, release 1 runs once, release 2 never runs | proven |
| Success release order | forced completion order 1/2/3 produces release order 3/2/1 after the body | proven |
| Typed-failure release order | forced completion order 1/2 produces release order 2/1 | proven |
| Defect release order | forced completion order 1/2 produces release order 2/1 | proven |
| Cancellation release order | external body cancellation produces release order 2/1 | proven |
| Interrupt during acquire | completed acquire releases once; interrupted acquire registers no release; body never runs | proven |
| Nested-ladder parity | helper and nested `with_resource` program have equal typed exits and equal release trails | proven |
| Release-row erasure | explicit `(unit, [ `Body ]) Effect.t` annotation compiles with distinct `` `Release1``/`` `Release2`` rows | proven |

The ownership commit point is successful acquisition followed immediately by
registration in the enclosing scope; there is no cancellation checkpoint
between those operations.

## Census / footgun vs sealed predictions

Independent census used the pre-experiment interface at `da4b98a8^` and the
current `lib/eta/effect.mli` lifecycle cluster.

| Metric | Predicted | Actual | Score |
|---|---|---|---|
| Lifecycle vals | 6 → 8 | 6 → 8 | hit |
| Lifecycle concepts | +1 (`Scoped`) | +1 (`Scoped`) | hit |
| Footguns | −1 / +0 | −1 / +0 | hit |
| Second acquire failure | first registered resource releases once | first registered resource releases once | hit |
| Release order | reverse successful registration order | reverse successful registration order | hit |
| Interrupt during acquire | completed acquisitions release; incomplete do not | exactly that | hit |

The six baseline vals are `acquire_release`, `acquire_use_release`,
`acquire_use_release_exit`, `with_resource`, `with_resource_exit`, and
`with_scope`; `Scoped.with_2` and `Scoped.with_3` make eight. The justification
is unchanged: replaces the `and@` operator (syntax machinery) with composition.
The removed footgun is the serializing nested-ladder trap; the semantics suite
found no new lifecycle default or silent fallback.

## Error-row and review evidence

`review/INFERRED.md` records the compiler result for both review candidates:

```ocaml
val boot :
  (services -> ('a, 'err) Eta.Effect.t) -> ('a, 'err) Eta.Effect.t
```

The signatures are identical and readable; release rows do not appear. The
matched snippets are within the registered size bound: `boot-old.ml` is 27
lines and `boot-new.ml` is 25 lines.

## Red-team

- `redteam/leak-attempt.ml`: the predicted leak does not occur. Failed second
  acquisition leaves the enclosing scope, which runs the first release once.
- `redteam/and-at-temptation.ml`: ordinary composition of two
  `with_resource` CPS functions nests callbacks and serializes acquisition.
  Syntax cannot honestly create shared concurrent ownership without hiding a
  new protocol. Verdict: reject `and@`; the named helper is the honest spelling.

## Deviations and implementation findings

1. No mission or scope-fence deviation.
2. The obvious public expression `map_par (acquire_release ...)` is incorrect:
   each parallel child drains its own finalizers before returning. The
   implementation therefore uses a private frame bridge, and the
   arity-greater-than-3 documentation recipe spells the same bridge with the
   public `Effect.Expert` surface. Both register successful resources in the
   enclosing `with_scope`. This is interpreter plumbing over existing
   primitives, not new runtime machinery.
3. The first focused run had one assertion mismatch: a singleton concurrent
   failure normalizes to `Cause.Fail`, not `Cause.Concurrent [Fail]`. The test
   expectation was corrected; the implementation did not change, and the next
   two focused runs were fully green.

The arity-greater-than-3 recipe is necessarily more advanced than the helpers.
That supports progressive disclosure but is also the strongest remaining cost:
users needing arbitrary homogeneous arity must use the documented local bridge
rather than naïvely combining `map_par` with `acquire_release`.

## Decision diary

- **V-DX-E6-1 — scoped helpers preserve lifecycle semantics.**
  Status: ACCEPT. Runtime evidence covers concurrency, fail-fast, partial
  failure, all body exits, interrupted acquisition, and ladder parity.
  Confidence: high. Would change if another runtime backend fails the shared
  suite or registration can be interrupted between acquire success and commit.

- **V-DX-E6-2 — release rows stay outside the public error row.**
  Status: ACCEPT. Compile-time annotation and identical inferred review
  signatures prove the claim.
  Confidence: high.

- **V-DX-E6-3 — prefer helpers over `and@`.**
  Status: ACCEPT. CPS composition is demonstrably serial; the helper names the
  lifecycle/concurrency protocol without syntax machinery.
  Confidence: high.

- **V-DX-E6-4 — promote helpers rather than recipe-only fallback.**
  Status: PENDING INDEPENDENT REVIEW. The technical gates pass; the
  pre-registered visual kill gate remains authoritative.
  Confidence: medium.

## Recommendation

**Promote to independent review.** Technical, type, census, and footgun gates
pass. Before review feedback, my honest read remains the sealed prior:
`with_3` is likely to rate better than the ladder (about 65% confidence). The
review pair makes the tradeoff concrete: six labelled acquire/release lines
versus three CPS nesting levels; the complete helper sample is also two lines
shorter. The labels remain the strongest counterevidence.

If independent reviewers rate `boot-new.ml` worse, kill `with_2`/`with_3` and
keep the documented recipe exactly as pre-registered. Regardless of that
result, `and@` should remain killed.

## Follow-up 1 — final kill outcome

The independent cohort fired the pre-registered kill gate:

| Blinded pass | Ladder rating | `with_3` rating | Preference |
|---|---:|---:|---|
| 1 | 5 | 3 | ladder |
| 2 | 5 | 3 | ladder |
| 3 | 4 | 3 | `with_3` for scanning, despite the lower rating |
| **Median** | **5** | **3** | ladder in 2 of 3 |

### Prediction scoring

| Prediction set | Prediction | Cohort result | Score |
|---|---|---|---|
| Primary prior | `with_3` rates better, about 65% confidence | median 3 vs ladder median 5 | miss |
| Counterprediction | labelled boilerplate scans worse than the ladder | consistent cohort diagnosis | hit |

The cohort found that the helper name exposed cardinality while hiding
acquisition strategy and release order. The ladder's serial acquisition and
inner-before-outer release semantics remained structural at the call site.

### Final implementation

This supersedes **V-DX-E6-4** and the pre-review recommendation above.

- **V-DX-E6-5 — kill cardinality-named scoped helpers.**
  Status: ACCEPT.
  Decision: remove `Effect.Scoped.with_2` and `with_3` with no rename rescue.
  Evidence: three blinded cohort passes, median 5 vs 3, ladder preferred in two
  of three.
  Counterevidence: the third pass preferred `with_3` for scanning, but still
  rated it lower; all technical semantics tests had passed.
  Recommendation: keep the ladder as the default and the explicit parallel
  recipe as progressive disclosure.
  Confidence: high; this is the pre-registered decision rule.

The public helper implementation and its 11 API-specific tests were excised.
Three durable recipe regressions now prove:

1. partial-acquire failure releases the registered resource exactly once;
2. reverse successful-registration release order on success and typed failure;
3. typed-exit and release-order parity with the nested ladder.

The final focused Eio suite is green with 518 tests. The recipe documentation,
ported tests, journal, report, red-team probes, blinded review packet, and
inferred-signature artifact survive. `and@` stays killed by the red-team result.
All four required gates listed above were rerun after excision and passed.

### Generalizable finding

*Helper names must carry execution strategy, not just cardinality.*

A strategy-carrying name is a different backlog experiment. It is not a rename
rescue for E6.

### Final recommendation

**Kill the helpers; keep the ladder-first documentation and parallel-acquire
recipe.**
