# Follow-up 1: DX-E38 — design repair: render at capture, store value + rendered string

The review found a blocking defect and an equality defect, both with the
same root: the payload stores a PRINTER and invokes it later, outside
Eta's capture boundary. A raising printer escapes as a raw exception
(E25's contract — "a raising `error_pp` becomes a defect via the
ordinary capture path" — is violated; reproduced:
`portable=raised(Failure("renderer exploded"))`). And a stateful
printer can break reflexivity of the new equality rule.

`objective.md` still applies; this file replaces the payload design.

## The repaired shape (decided by the orchestrator)

```ocaml
| Fail : { error : 'err; rendered : string } -> t
```

- At `finalizer_of_cause` (and any other storage site), invoke the pp
  **inside the runtime capture path at conversion** — exactly where it
  ran before this experiment. A raising printer → `Cause.Die`, restoring
  E25's observable contract bit-for-bit.
- On success, store the error VALUE (the experiment's point: structure
  survives) and the RENDERED STRING (computed once, inside capture —
  matching E25's "rendered at most once" rule).
- The payload stores NO printer. Consumers render via `rendered`
  (parity with today by construction); consumers needing structure use
  `error`.
- Equality on `Fail` payloads = structural equality on `rendered`
  strings — exactly the old string-world semantics: reflexive, total,
  no collision-limit novelty, no stateful-printer surface.
- `Portable` materializes from `rendered` (parity).

This is strictly more information-preserving than both the old shape
(string only) and the current one (value + deferred printer): every
render today is already computed at conversion; we keep it AND keep
the value.

## What changes mechanically

- `cause.mli`/`cause.ml`: the payload record; mli docs rewritten (the
  render-at-capture rule, the E25 defect contract, the value-survival
  note, string-equality rule — no collision-limit paragraph needed);
  `equal`/`diagnostic_equal` simplify to string comparison on `rendered`.
- All current consumers of `{ error; pp }` move to `{ error; rendered }`
  (simpler than what they do now — no pp application).
- The E25-defect regression test: a raising printer on a release
  failure MUST produce `Cause.Die` at conversion (the exact case the
  review reproduced — now a named test on both substrates where the
  capture path exists).
- Equality: state the rule plainly (string equality on `rendered`,
  parity with the pre-E38 world); the reflexivity counterexample in the
  review must now pass (it compares strings).
- Remove the now-dead code the review flagged (`effect_core.ml:48-49`)
  and rename the misleading `render_finalizer_cause` /
  `render_cause_error` / local `render` (they no longer render at those
  sites — or they do again under the repaired rule; align names with
  whichever is true).
- Registry: R154–R161 re-shaped for the repaired payload; exact spans
  fixed (R154 must not include the unrelated `bind_error` line; R156/
  R157 must not cite both Fail and Die clauses when covering one;
  R160/R161 cite only the finalizer clauses); register the restored
  "raising printer → `Cause.Die` at conversion" claim with its new test.
- The "footguns +0" claim: re-derive it under the repaired design (the
  reflexivity issue never exists now; state that).

## Protocol

Journal note (micro-predictions), implement, re-run all gates (native
trio + mainline js_jsoo + otel suites), update report (the design
change explained against the review's findings, parity evidence
refreshed), registry updated, usual signal. Same scope fence. This file
stays uncommitted.
