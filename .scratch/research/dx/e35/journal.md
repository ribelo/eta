# DX-E35 stack-safety experiment journal

## Sealed predictions — 2026-07-26

This section was written before any DX-E35 probe code or measurements. It is
immutable after the `docs(dx-e35): seal predictions` commit. Measured evidence,
prediction scoring, and the final verdict belong in `report.md` and
`probe/RESULTS.md`; they must not be added here.

### Decision question and proof obligations

Question: does Eta execute the specified deep effect compositions without
exhausting the host stack on both native OCaml and js_of_ocaml/Node, and, if
not, can an explicit interpreter continuation stack establish that guarantee
without changing semantics or materially slowing the runtime watchlist?

| ID | Proof obligation | Minimum fair evidence | Risk |
| --- | --- | --- | --- |
| E35-P1 | Dynamic sequential binds are stack-safe | 10k, 100k, and 1M completed binds on both substrates with the exact final count | High |
| E35-P2 | Statically nested `Map`/`Bind` shapes are stack-safe | Static map and `concat` checkpoints plus exact first-failure search on both substrates | High |
| E35-P3 | Deep typed recovery is stack-safe | Nested `bind_error` checkpoints plus exact first-failure search on both substrates | High |
| E35-P4 | Public deep cause trees survive relevant traversal | Left-deep `Sequential` and `Concurrent` construction and `Cause.failures` traversal on both substrates | Medium |
| E35-P5 | A required rewrite preserves behavior and hot paths | Full parity gates, red-team case, 1M corpus rerun, and baseline/final runtime watchlist | High |

The favored hypothesis is the boring baseline: leave the interpreter alone if
every case passes at 1M on both substrates. The disconfirming hypothesis is that
non-tail descent through a static node or cause tree fails on either substrate;
one such failure mandates Phase 2.

### Probe-shape predictions

The predictions distinguish a dynamic bind chain, where each successful
continuation constructs the next node during evaluation, from left-deep static
trees built completely before `Runtime.run`. Cause predictions cover public
`Cause.sequential`/`Cause.concurrent` binary nesting followed by
`Cause.failures`, so successful construction alone cannot flatter the result.

`Boundary` is the predicted first failing depth, not a measured value. A range
records honest uncertainty; the single number in parentheses is the point
estimate used for scoring. `>1M` predicts all required checkpoints pass.

| Case | Native checkpoint prediction | Native boundary | Node/js_of_ocaml checkpoint prediction | Node boundary | Predicted failure mode |
| --- | --- | --- | --- | --- | --- |
| Dynamic sequential `bind` | 10k PASS; 100k PASS; 1M PASS | >1M | 10k PASS; 100k PASS; 1M PASS | >1M | none through 1M |
| Static left-deep `map` | 10k PASS; 100k PASS; 1M FAIL | 200k–400k (262,144) | 10k FAIL; 100k FAIL; 1M FAIL | 4k–9k (6,144) | caught `Stack_overflow` |
| `concat` of prebuilt unit effects | 100k PASS; 1M FAIL | 150k–350k (225,000) | 100k FAIL; 1M FAIL | 3k–8k (5,000) | caught `Stack_overflow` |
| Static nested `bind_error`, repeatedly propagating a typed failure | 10k PASS; 100k FAIL | 40k–100k (65,536) | 10k FAIL; 100k FAIL | 1.5k–5k (3,000) | caught `Stack_overflow` |
| Left-deep `Cause.Sequential` plus `Cause.failures` | 10k PASS; 100k FAIL | 40k–100k (65,536) | 10k FAIL; 100k FAIL | 2k–6k (4,000) | caught `Stack_overflow` |
| Left-deep `Cause.Concurrent` plus `Cause.failures` | 10k PASS; 100k FAIL | 40k–100k (65,536) | 10k FAIL; 100k FAIL | 2k–6k (4,000) | caught `Stack_overflow` |

I predict no segfault, OOM, or hang at the requested checkpoints when each case
runs in a fresh process with a bounded timeout. At 1M, static construction may
consume substantial heap, but I predict stack exhaustion during evaluation or
traversal before heap exhaustion.

### Pre-registered verdict

I predict **Phase 2 is triggered**, first by static map/concat/recovery on Node
and independently by at least one static native case below 1M. Confidence:
high that some case fails, medium on native failure points, and low-to-medium on
the exact Node boundary because js_of_ocaml may transform some direct recursion
into loops but cannot transform the indirect `Custom.eval` recovery cycle.

The alternative outcome remains live: if all cases, including cause traversal,
pass at 1M on both substrates, the correct decision is to leave the interpreter
untouched and promote only the corpus.

### Phase 2 performance prediction

If Phase 2 is required, I predict a naive allocated OCaml-list continuation
stack would regress the prebuilt-bind row by more than 15% and violate its
zero-minor-allocation watchlist invariant. That design is therefore not an
acceptable final tree even if it passes the corpus.

For an optimized final interpreter, I predict these median wall-time deltas
versus the pre-probe baseline (same machine and command):

| Runtime watchlist row | Predicted final delta |
| --- | ---: |
| `overhead.eta.pure.reused_rt` | 0% to +1% (point +0.5%) |
| `overhead.eta.bind.100k.prebuilt` | +2% to +5% (point +4%) |
| `overhead.eta.fail_catch.100k.prebuilt` | 0% to +3% (point +2%) |
| `realuse.retry.flaky.fail4_then_ok` | 0% to +3% (point +2%) |

The final prediction is that all four stay within the assignment's approximate
5% noise guard, with existing hard allocation invariants preserved. If the
smallest semantics-preserving trampoline cannot meet that bar after bounded
optimization, DX-E35 should be reported BLOCKED rather than shipping a slow
core interpreter.

---

## Follow-up note — 2026-07-26 (post-review; sealed predictions above unchanged)

The orchestrator accepted the verdict with six corrections (follow-up-1.md,
uncommitted per protocol). The accepted guarantee statement is narrower than
the one I first wrote: **stack-safe at 1M under documented default runtime
configurations on shipped substrates (1 GiB default OCaml `stack_limit`
native/bytecode, CPS jsoo); configuration-dependent, not intrinsic.** Applied:

- C1: guarantee wording narrowed in `report.md`, `probe/RESULTS.md`, and both
  promoted-test comment blocks; default limit measured (134,217,728 words =
  1 GiB on 64-bit, both compilers) and the `OCAMLRUNPARAM=l=` reopener
  demonstrated (`probe/STACKLIMIT.raw.txt`).
- C2: `concat` now counts `Effect.sync` executions (exactly `depth`); cause
  cases validate every leaf against its index — in the probe and both
  promoted suites.
- C3: promoted thresholds pinned to the full measured 1M on native,
  bytecode, and jsoo (per-case 1M timings: native 10–198 ms, byte 52–361 ms,
  jsoo 96 ms–1.5 s).
- C4: bytecode added to the probe matrix (54 mainline + 36 OxCaml runs, all
  PASS) and to the gates via `test/eta/run_stack_safety_byte.ml` on the
  `runtest` alias.
- C5: jsoo mechanism wording corrected — the whole `eval` is CPS-transformed
  because its branches and callbacks are effect-capable; evidence cites the
  compiled `eval$` trampoline call sites (`probe/JS-EVAL-TRAMPOLINE.raw.txt`).
- C6: prediction autopsy completed in `report.md` — the mistake was which
  stack (OCaml 5 heap fiber stacks, not the 8 MiB C stack) and which limit
  (configurable `stack_limit`, 1 GiB default, not a fixed bound); the sealed
  `Custom.eval`-not-CPS premise scored wrong; `dynamic_bind`'s tail-call
  caveat recorded (its pass is not absorption evidence).

Law-registry assessment: no new or changed law-bearing prose in any `.mli`,
so no `LAWS.md` census row applies; the named tests are listed in
`report.md` for the day the contract enters interface prose.

All gates re-run green on the final tree. `E35 READY FOR REVIEW`.
