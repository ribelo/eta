# Follow-up 1: DX-E35 — accept-with-conditions (six corrections)

The measurement stands — no Phase 2 — but the guarantee must be stated
and pinned precisely. The verdict is **"stack-safe at 1M under
documented default configurations on shipped substrates (1 GiB OCaml
stack limit native, CPS jsoo); configuration-dependent, not intrinsic"**
(orchestrator decision). Six corrections, all from the review:

## C1 — Narrow the guarantee statement everywhere

Report, regression-test comments, and any docs wording must say exactly:
1M under default runtime configurations; exhaustion is governed by the
OCaml `stack_limit` (default 1 GiB words on 64-bit), so user-selected
`OCAMLRUNPARAM=l=…` limits reopen it; non-CPS jsoo is excluded by
`eta_jsoo.mli`'s own requirement; a future bounded-stack substrate
reopens the question. Delete any phrasing that reads as "arbitrarily
deep" or "intrinsic stack safety".

## C2 — Strengthen the two weak semantic checks

- `concat`: counter-incrementing `Effect.sync` leaves; assert exactly
  `depth` executions (current `Ok ()` check cannot detect skipped
  effects).
- Cause cases: validate EVERY leaf against its index, not just length +
  first leaf.

## C3 — Regression thresholds must pin the measured contract

Promoted tests currently check 10k–100k where the probe established
1M. Either run the full 1M thresholds where they are affordable in gate
time (measure: `dynamic_bind` 1M native took 41 ms; pick per-case
depths accordingly) or explicitly narrow the continuously-checked
contract in the test names/comments. A regression that moves failure
to 200k must fail the suite.

## C4 — Add bytecode to the matrix

`eta.cma` is a shipped artifact. The review independently built the
probe in bytecode and all five static cases passed at 1M — add bytecode
runs to the matrix and the gates, or stop saying "shipped substrates".

## C5 — Correct the jsoo mechanism wording

The whole `eval` function is CPS-transformed because its branches and
callbacks are effect-capable — not because each case dynamically
reaches `Custom` leaves (`static_map` and unit `concat` don't). Cite
the generated `eval$` trampoline call sites, not just global symbol
counts.

## C6 — Complete the prediction autopsy

The precise mistake (both predictors): confusing the 8 MiB OS C stack
with OCaml's growable stack having a 1 GiB default maximum — the model
"fixed stack" was wrong about WHICH stack and WHICH limit. Also score:
the executor's sealed premise that the indirect `Custom.eval` cycle
would not be CPS-transformed (wrong); `dynamic_bind`'s tail-called
character (its pass is not evidence of absorbed frames — say so).

## Protocol

Journal note, implement (tests/report/registry as applicable — note
that new law-bearing test names need LAWS.md rows if they register
claims), re-run native trio + mainline js_jsoo + the probe matrix
(including bytecode), update the report, usual signal. Same scope
fence. This file stays uncommitted.
