# DX-E20 red-team results

## Filter-before-intercept trap

`filter-before-intercept.ml` encodes the incorrect expectation that an
interceptor can observe a `Debug` record under a `Warn` minimum. The executable
regression `intercept_log runs after filter` proves the callback count remains
zero and the sink remains empty. The public contract explicitly restates the
pipeline order, so this trap is disarmed by docs and test.

## Raising-transform trap

`raising-transform.ml` throws from the user transform. The executable regression
`intercept_log raise becomes defect` proves the runtime returns
`Exit.Error (Cause.Die _)`, preserves exception identity, and does not call the
sink. The public contract says a raising transform becomes a defect through the
ordinary capture path. This is covered rather than silently defaulted.

No fallback, exception swallowing, or compatibility path was added.
