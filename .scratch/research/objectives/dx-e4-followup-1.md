# Follow-up 1: DX-E4 — board fired the kill gate on cases 2 & 6; one bounded rework round

The error review board rated the corpus: cases 1, 3, 4, 5
PASS-WITH-COMMENT; **cases 2 and 6 FAIL**. The failure is specific:

> The one-line form `p | suppressed: f` never says the right-hand cause ran
> in a **finalizer**. For a reader, "suppressed" can mean an arbitrary
> secondary error. The tree form labels `finalizer:`; the compact form
> loses that role.

The pre-registered kill gate ("compactness destroys the primary/finalizer
distinction") fired on this evidence. Instead of killing immediately, the
orchestrator authorizes **one rework round**, because the board's failure
is actionable in the notation itself. If the fixed line reads worse than
two lines, we kill `pp_compact` and ship "two-line logs" as the finding —
that outcome is still fully on the table.

## Required fix

The compact notation must make the finalizer role **explicit** in the
suppressed segment — e.g. `p | suppressed: finalizer(f)` (exact spelling is
yours; the review criterion is: a reader names "this ran in a finalizer"
from the line alone, for every suppressed case in the corpus).

Then:

1. Update the `pp_compact` mli doc (the segment legend changes).
2. Re-lock every affected snapshot (all suppressed cases, both forms stay
   locked), extend the red-team monsters if their output changes.
3. Re-run the full gate set from objective.md (native trio + mainline
   `test/cache_jsoo test/js_jsoo`).
4. Update journal + report with the board evidence (verbatim quotes above),
   the fix, and the re-locked corpus.
5. Housekeeping: the committed build artifacts in
   `.scratch/research/dx/e4/review/` (`gen_renders.cmi/.cmx/.o`, `_gen/`)
   must not be in git — remove them and add a `.gitignore`.

E5 is unaffected — it promoted on its own track (corpus drift gate
verified by the orchestrator, page review passed the rank-2 teach-back
bar). Nothing in this file changes E5.

## Done means

Same signals: `E4 READY FOR REVIEW` / `E4 BLOCKED: <reason>` /
`E4 STOP: <§4.6>`. The board re-convenes on the fixed renders (continuity
review) and a fresh reviewer sees the full revised corpus cold
(anti-anchoring). Both must pass cases 2 and 6 or `pp_compact` dies.
