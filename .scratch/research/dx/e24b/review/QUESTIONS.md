# DX-E24b reviewer questions

Read `DECISION.md`, then inspect `../journal.md` and `../redteam/` only as needed.

1. Is the driver/protocol inventory complete, including `step_with_hooks`, both
   hand-interpreters, the no-hook HTTP path, and the public custom-driver seam?
2. Is every semantics-matrix row stated strongly enough to distinguish A, B,
   and C? Which cell is unsupported or overstated?
3. Does the A verdict follow from the composition and type-system evidence, or
   is there a fairer B/C design that preserves the same contract?
4. What is the strongest objection the record does not answer?
5. Does the new mli ownership sentence say only what the named qcheck property
   proves, and are M95/M96/R96 valid E22 registrations?
6. Is “no production tap construction” weighted honestly, or has the record
   confused protocol capability with user adoption?
