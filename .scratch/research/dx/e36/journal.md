# DX-E36 sealed predictions

Sealed before E36 code or contract changes. This file is immutable after the
`docs(dx-e36): seal predictions` commit.

## Question and proof obligations

Implement the upstream-decided split between fail-fast lexical background work
and supervised lexical background work without changing Eta's cause taxonomy or
Supervisor protocol. The decisive evidence is deterministic native and jsoo
coverage of cancellation, finalization, cause propagation, and tie arbitration.

| ID | Proof question | Required evidence | Risk |
|---|---|---|---|
| P1 | Does background typed failure/defect stop `use` immediately without replacing its cause? | Shared-runtime named tests inspecting exits and body finalizers | High |
| P2 | Does foreground completion/interruption cancel and await the background exactly as before / as `par` does? | Success, failure, and interruption tests with settlement/finalizer witnesses | High |
| P3 | Is simultaneous background-failure/body-success arbitration single-winner and deterministic? | Shared barrier test plus exact exit/cancellation counts | High |
| P4 | Is supervision preserved verbatim? | Existing tests mechanically renamed plus adversarial non-leak probe | Medium |

## Sealed semantic predictions

1. **Typed background failure first.** `with_background` returns that exact
   `Cause.Fail`; it cancels and awaits `use`, and `use` finalizers complete before
   the combinator returns. The internal sibling interruption is not added to the
   public group cause.
2. **Background defect first.** The same rule applies to `Cause.Die`: the defect
   is propagated, not recorded-and-hidden or converted to a typed failure, while
   body finalizers still run before return.
3. **Body finishes first.** On body success or typed failure, the body exit wins;
   the background is cancelled and awaited. Pure internal background
   interruption is ignored. A background cleanup failure remains visible through
   the current finalizer/suppression behavior.
4. **Body is interrupted.** The background is cancelled and awaited; pure child
   cancellation does not add another public cause, so the resulting interruption
   shape matches `par`'s sibling-cancellation boundary.
5. **Supervised variant.** `with_supervised_background` is the old implementation
   verbatim: a child failure is recorded by the supervisor and never changes the
   running body's exit; cancellation/await happens only when `use` ends.
6. **Simultaneous failure/success.** Background failure has safety-first
   precedence when both terminal outcomes become runnable from the same release.
   One atomic arbitration winner initiates cancellation exactly once; the body
   success cannot overwrite a published background failure.

## Implementation and migration prediction

- The smallest mechanism will use one lexical concurrent scope and a single
  winner/arbitration point, filtering only its own cancellation marker exactly as
  `par` does. It will not redesign Supervisor.
- The existing `with_background` body becomes
  `with_supervised_background`; the fail-fast name receives the new mechanism.
- The source census is 37 `with_background` call-site lines (39 OCaml matches
  minus the public declaration and implementation definition). Tests that encode
  today's delayed-observation/lifecycle behavior move mechanically to
  `with_supervised_background`. `examples/background_lifecycle.ml` remains on
  `with_background` and becomes the fail-fast teaching site. No HTTP daemon
  reader is migrated; that remains E42a follow-up work.
- Public census delta: **+1 val**. Footgun delta: **-1**, because the generic
  lexical-background spelling can no longer let invisible background death leave
  the body running.
- `with_best_effort_background` is not justified: the existing composition
  `with_supervised_background (ignore_errors background)` already expresses it
  without another public value.

## Predicted review outcome

Prediction: **READY FOR REVIEW**, provided both substrates prove all six edges,
the law registry points each new law-bearing span to named executable coverage,
and every mandated Nix gate passes. The most likely adversarial finding is a tie
or cleanup race that either leaks an internal interruption into the cause or
returns before the losing side's finalizers settle.

## Active hypothesis space

| Candidate | Status | Reason |
|---|---|---|
| A. Dedicated fail-fast lexical arbiter plus verbatim supervised helper | Selected upstream; pending evidence | Directly owns the cancellation/cause protocol with only one new public value. |
| B. Express fail-fast solely as `par`/`race` composition | Active until implementation probe | Attractive reuse, but ordinary `par` cannot cancel a still-running successful-background/body pair and ordinary `race` is not fail-fast on one failed branch. |
| C. Add best-effort helper | Out of scope | Explicitly excluded upstream and composition already expresses it. |
| D. Change Supervisor or HTTP daemon readers | Out of scope | Violates the E36 scope fence; HTTP reader migration is E42a. |
