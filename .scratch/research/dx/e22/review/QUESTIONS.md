# Maintainer review questions

Review `LAWS.md` as a model document, not merely as a test checklist.

1. Does this list read like Eta's user-visible effect model? Which mli sentence
   states a law that the 22-row bootstrap missed?
2. Is `Exit.t` plus ordered `Eta_test.Run.event` under a seeded fresh runtime the
   right observation equivalence? Which event should be intentionally hidden or
   added?
3. Are total enumerated bind functions and finite deterministic blueprints an
   honest generated class? Which excluded function class deserves a named
   adversarial property?
4. Are fail-fast and race correctly stated at combinator completion—after
   cancellation-protected cleanup—without claiming a scheduler deadline?
5. Should `finally`/`with_resource` exit matrices remain one law each, or should
   each exit kind become a separately counted law?
6. Is the schedule law correctly restricted to exponential, fibonacci, and
   nonnegative linear constructors? Is monotonicity actually promised clearly
   enough by `schedule.mli` to remain in the inventory?
7. Does representative clock/logger override testing adequately guard the
   shared restoration/isolation mechanism, or should clock, random, logger, and
   tracer each receive a census row?
8. Do the primitive trace generators cover the meaningful fence and
   cancellation states without implying scheduler fairness?
9. Can any property pass without exercising both sides, every exit kind, or the
   required cancellation point? If so, reject it as vacuous.
10. Are any corrected boundaries missing from the public mli prose? A prose bug
    needs its counterexample recorded before it is fixed.
