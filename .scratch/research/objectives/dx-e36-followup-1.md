# Follow-up 1: DX-E36 — blocker adjudication: one spec amendment, two evidence assignments

Your blocker was correct to raise and correctly handled. Adjudication
(V-DX-E36-002): finding 1 was an over-specification in the objective, not
a runtime gap; findings 2 and 3 are unfinished evidence, not
inexpressibility. `objective.md` still applies except where this file
amends it.

## F1 (closed by amendment — implement the contract wording)

The same-release rule is **publication-order linearization** — exactly
`par`'s model ("the first child failure cancels the sibling", first in
observation order). Safety-first same-instant priority is explicitly NOT
guaranteed. Concretely:

- mli: the fail-fast contract's racing line must say "linearized by
  terminal-exit publication order" (or your sharper phrasing), and name
  that it matches `par`'s model — no priority promise.
- Same-release tests renamed/worded to publication-order, not priority.
- No `Runtime_contract` work. This item is wording + test naming only.

## F2 (evidence) — cleanup parity, proven or adjusted

Write discriminating tests for background cleanup failing **after**:
(a) body success, (b) body typed failure, (c) body defect. Assert the
cause shape and ordering the OLD `finally (cancel_child_effect child)`
structure produced (finalizer diagnostics / `Suppressed` composition —
document the old shape from the old code/tests first, then the new one).
If the shapes differ: either adjust the structure to parity, or document
the new shape precisely and argue it is equivalent-or-better (the review
decides). A difference you find but cannot justify is a fresh BLOCKED —
with the evidence, not a summary.

## F3 (evidence) — cancellation-safe loser publication, both substrates

Write the regression: force the loser's exit to publish *after*
cancellation, on BOTH native and jsoo; assert both terminal events are
always published before the arbiter assembles the result (no lost
publication, ever). If it fails on any substrate: add the protected
commit (uninterruptible publication window, smallest possible) and
re-prove. This is the E15 lost-wakeup discipline: the guarantee must be
stated and tested, not assumed.

## Protocol

Journal note (micro-predictions for F2/F3), implement, re-run all gates
(native trio + mainline js_jsoo), update report (findings re-stated as
closed-with-evidence), law rows for any new law-bearing claims, usual
signal. Same scope fence. This file stays uncommitted.
