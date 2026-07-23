# Follow-up 1: DX-E24b — assess candidate D + close the evidence gaps

The decision review verdict is SOUND-WITH-RESERVATIONS: A (retain) is
supported IF structural taps remain a feature — but "permanent" was
concluded without evaluating deletion, and several evidence gaps remain.
Fix all of it; the verdict's final form is yours to re-decide on the new
evidence.

## 1. HIGH: assess candidate D (delete taps + the hook channel) explicitly

The hypothesis space skipped the boring baseline (the method's own
canonical candidate: "delete the feature and document the recipe").
Assess it honestly:

- **Surface delta (executable)**: what actually breaks — the 12 test tap
  constructions, `Resource.auto`'s and `Eta_stream`'s documented
  tap support (their mlis promise tap behavior to users), the suspended
  `Hook` constructor in the public `step` type, the 8 threaded signatures
  going 3-param → 2-param.
- **Capability delta**: what becomes inexpressible (pre/post-step
  observation of schedule-driven processes — e.g. "log every retry
  attempt" — for custom drivers and for `Resource.auto`/`Eta_stream`
  users who pass tapped schedules). Write the recipe users would need
  instead and rate it.
- **Demand analysis**: zero production producers today. What is the
  honest status — "coherent extension point awaiting demand" vs "dead
  weight"? Your journal's initial falsifier ("reject A if no production
  need") was encountered and reframed as external-adoption-unknown; face
  it directly: either define the demand signal that would justify
  retention, or fold.
- **Verdict**: revise to the evidence-conditional form the review
  named — e.g. "retain A as the ownership model IF structural taps are
  kept; deletion assessed and rejected/deferred BECAUSE <evidence>" —
  and drop "permanent" unless the evidence carries it. If D wins after
  all, say so: that flips the experiment to a deletion proposal.

## 2. MEDIUM: complete the semantics matrix (suspension + observability rows)

Add and probe (executable where behavior is claimed):
- the resume contract: resume once, only after successful interpretation;
  abandonment / multiple invocation of the public non-linear `resume`
  closure (what happens?);
- failures raised DURING hook interpretation/`resume`; partial execution
  — prior successful hook effects are NOT rolled back and may repeat on
  retry (document, test);
- cancellation during interpretation;
- wrapper interactions: taps inside vs. outside `jittered`,
  `modify_delay`, `while_output` (which runs first?); `named`'s
  transparency to hooks;
- telemetry: do hooks produce spans/logs/metrics anywhere; should
  `Schedule.named` affect that?

## 3. MEDIUM: ownership prose → driver contract

Extend `lib/eta/schedule.mli` (and the two tap vals) to state the
operational contract for a custom driver: hooks arrive in deterministic
structural order; resume each continuation once and only after its hook
succeeds; no next driver is published until the whole plan completes;
prior successful hook effects are not rolled back if a later hook fails;
the `tap_input` vs `tap_output` failure asymmetry made explicit. (E22
policy: this is law-bearing prose — register or add the named tests.)

## 4. Wording fixes (LOW/MEDIUM)

- B's rejection reads "cannot represent" — narrow to "top-level driver
  observers cannot represent; structural observers can only by restoring
  policy-owned placement" (the review's exact framing).
- C's "dominated" → "the tested C variants fail or add surface" (the
  journal's own medium-confidence honesty, carried into the report).
- The new qcheck law: label it what it is (a strong table test — fixed
  schedule shape, payload variance) or broaden the generated shape.

## Records

Journal: append-only entry covering D's assessment and the matrix
additions. Report + DECISION.md updated; the verdict sentence revised to
its evidence-conditional form. Parking-lot entry: update if the verdict's
strength changes. Red-team: the D probes join `run-all.sh`.

## Gates

Native trio; mainline `@install` + `test/laws`; `@doc` if prose changed.

## Done means

`E24B READY FOR REVIEW` / `E24B BLOCKED: <reason>` / `E24B STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
