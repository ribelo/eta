# Follow-up 3: DX-E15 — restore must listen to both contexts (CRITICAL) + lane-depth policy

Round three. The fiber-local rework is confirmed correct (all four
previous findings closed), and the reviewer reproduced one more
critical topology.

## 1. CRITICAL: descendant `cancel_sub` inside the mask is bypassed

Topology `C → R → P → S`, where `S` is a `cancel_sub` created INSIDE
the masked body (same fiber). Native restoration moves the fiber from
`S` to `R`; cancelling `S` then finds no registered fiber — hang
(reviewer's repro: `uninterruptible (cancel_sub @@ fun sub ->
install_cancel sub; Expert.eval (interruptible never))` — native
timeout). jsoo retains `S` and resets depth, so BOTH cancellation
sources deliver there — and jsoo's behavior is the correct model.

This shape is production-real: `lib/signal/eta_signal_timer.ml:173-190`
already does `cancel_sub` + nested `Expert.eval`.

**Fix direction (verify, don't assume):** at restore entry, the native
side observes the fiber's CURRENT context `S` in addition to `R` —
e.g. a relay installed at restore entry that cancels `R` when `S` is
cancelled (the Phase 0 probes proved explicit sub-cancel escapes
protection, so the relay CAN wake), or an equivalent combination. The
semantics must match jsoo: **restore listens to the mask-entry parent
AND the entry-time current context; first cancel wins; delivery at
most once.** If the relay turns out to need machinery that violates
the doc budget, bring the cost back as evidence — do not silently
narrow the semantics (e.g. "identity inside sub-contexts") without an
orchestrator decision; silent narrowing would mask the signal-timer
shape.

Regression tests (both backends):
- the reviewer's repro: cancel `S` while restored-blocked — prompt
  delivery, no hang;
- cancel `R`'s parent while restored-blocked in the same shape —
  delivery (the restore's original purpose, preserved);
- the signal-timer shape specifically: `cancel_sub` + nested
  `Expert.eval (interruptible ...)` with an outer `uninterruptible` —
  both cancellation sources delivered, at most once.

## 2. MEDIUM: Signal lane depth local is still `Inherit`

`lib/signal/eta_signal.ml:687-688` creates `graph_lane_depth_local`
with default inheritance; `eta_signal_lane.ml:60-65` treats positive
inherited depth as sufficient re-entry evidence without checking the
child's fiber identity — a fork while the parent holds the lane can
bypass admission. Apply the new `Fiber_local` policy here UNLESS
cross-fiber lane re-entry is explicitly intended — in which case prove
it safe and document it. Either way: a fork-while-lane-held regression
test. (This is in scope: the new policy exists precisely for this
class of bug, and the review surfaced it.)

## Records and gates

Journal: append-only — the descendant-context topology, the both-ears
model, the lane decision. Report: updated. mli: if the restore
semantics sentence needs the extra clause ("listens to the mask-entry
parent and the entry-time current context"), add it within budget.
Gates: full set both shells (`_build-mainline` for mainline).

## Done means

`E15 READY FOR REVIEW` / `E15 BLOCKED: <reason>` / `E15 STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
