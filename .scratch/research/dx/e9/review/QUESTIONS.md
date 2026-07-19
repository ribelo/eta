# Reviewer questions

Answer from the snippets alone. Do not assume which form is "new" or preferred.
Score each factual question correct / incorrect; optional free-text notes are
allowed after the factual answers.

## Snippet A — `implicit.ml` (program)

1. How many fibers fork for the `left` / `right` product binding (0, 1, 2, or
   "not determined by this snippet")?
2. If `load_user left_id` fails with a typed error, what happens to the
   `right` load — does it still run to completion, get cancelled, never start,
   or "not determined"?
3. Is the order of effects inside the `left` / `right` product guaranteed by
   this snippet? (yes / no / only on success)

## Snippet B — `explicit-par.ml` (program)

4. How many fibers fork for the `left` / `right` product binding?
5. If `load_user left_id` fails, what happens to the `right` load?
6. What does the second `open` line contribute that the first `open` does not?

## Snippet C — `explicit-app.ml` (transfer)

7. Does the order of the two `write_balance` effects matter for correctness of
   this transfer? (yes / no)
8. Is that order guaranteed by this snippet? (yes / no / not determined)
9. If the debit write fails, does the credit write run?

## Snippet D — `implicit-race.ml` (transfer)

10. Does the order of the two `write_balance` effects matter for correctness?
11. Is that order guaranteed by this snippet?
12. If the debit write fails, does the credit write run — always / never /
    sometimes / not determined?

## Meta (after factual answers)

13. Which pair, if either, makes the concurrent-vs-sequential choice obvious
    without prior Eta knowledge: A/B, C/D, both, neither?
14. Would you accept requiring an extra `open` for every `and*` use site in
    application code? (yes / no / only for order-sensitive code)
