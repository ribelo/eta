# DX-E37 follow-up 1 sealed micro-predictions

Sealed after reading `followup-1.md` and before follow-up implementation. This
file is immutable after its sealing commit; the original `journal.md` remains
untouched.

## Y1 — native discriminators

- A true parent cancellation while acquisitions are in flight will preserve an
  interruption primary, release every completed resource exactly once in reverse
  successful-acquisition order, and skip result publication.
- A typed acquire failure followed by a failing staged release will produce
  `Cause.Suppressed` with the acquire failure primary and a rendered finalizer
  diagnostic; the diagnostic will not become a normal typed acquisition error.
- An acquire defect after earlier successful acquisitions will remain a
  `Cause.Die`; staged releases will run exactly once in reverse success order.
- Prediction: all three expose evidence gaps only; no mechanism change is needed.

## Y2 — registry truth

- R149 and R153 will need new executable pointers rather than broader prose.
- R84 will contain stale deleted recipe-test references and should be replaced
  by current evidence or removed if its old public claim no longer exists.
- The 13-line insertion and later documentation edits will have invalidated a
  contiguous family of exact Effect spans, not only the examples named by
  review. A whole-file pointer sweep will find and repair that class in one pass.
- Header arithmetic will need recomputation from actual M/R/debt/model rows;
  prediction: row coverage remains complete after repair, but the prose totals
  do not currently describe those rows truthfully.

## Y3 — jsoo

- The backend-sensitive staging/check/yield protocol will pass direct jsoo
  success-transfer, sibling-failure rollback, and parent-interruption tests.
- Prediction: the JS harness will require explicit scheduler driving but no Eta
  core implementation branch or fallback.

## Y4 — heterogeneous documentation

- The honest one-paragraph recommendation is the sequential `with_resource`
  ladder by default; any advanced concurrent heterogeneous implementation must
  independently stage and atomically transfer the whole finalizer batch.
- The old direct owner-registration advice will be deleted, not qualified.

## Outcome prediction

After the native trio, direct jsoo evidence, registry recensus, one-paragraph
doc repair, report correction, and required gates, the branch remains
`E37 READY FOR REVIEW`. Any failure showing a leak, duplicate release, incorrect
cause category, or backend-specific commit race changes that outcome to blocked.
