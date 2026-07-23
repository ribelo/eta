# DX-E24d review questions

## Does `retry` now refuse a composite with a defect?

Yes. It calls `stripped_uncatchable` before selecting a typed failure. Any
defect, interruption, or finalizer diagnostic makes the composite uncatchable;
`while_` and the schedule are skipped, and `retry` returns the original cause.

## What cause does terminal exhaustion return?

The complete cause from the final failed attempt. The first typed failure is
only the schedule input. Exhaustion does not rebuild `Cause.Fail first` and does
not discard sibling typed failures.
