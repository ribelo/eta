# E4 review questions — Cause rendering corpus

You are rating rendered failure causes. Each `case-N-*.txt` file shows one
cause rendered two ways: a multi-line tree (`pretty`) and a one-line summary
(`pp_compact`). Do **not** read `lib/eta/cause.mli` or any implementation
while answering — the renders must stand alone.

For **each** case file, answer:

1. **What happened?** Name every failure/defect/interruption you can see,
   and which of them ran concurrently vs. sequentially.
2. **Which is the primary failure?** If the case has a suppressed/cleanup
   dimension, say which side is the original problem and which side is
   cleanup fallout.
3. **What ran in a finalizer?** Point at the exact segment(s).
4. **What would you check next?** One concrete next action (a log field, a
   span, a code path) based only on the render.

Then the board-level verdicts:

5. For each case, rate the **one-line form** alone:
   PASS (answers 1–4 without help) / PASS-WITH-COMMENT / FAIL.
6. **Kill-gate question:** does compressing to one line destroy the
   primary/finalizer distinction anywhere in the corpus? If yes, name the
   case — the one-liner is killed on that evidence and the finding becomes
   "two-line logs".
7. Is anything you see in the tree form **missing** from the one-line form
   in a way that misleads (as opposed to summarizes)? Distinguish
   "misleading" from "documented omission" (defect span names, annotations,
   and backtraces are intentionally only in the tree/JSON forms).
