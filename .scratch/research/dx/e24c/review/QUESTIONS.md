# DX-E24c review question

## What happened to schedule taps, and what do I do instead?

`Schedule.tap_input`, `Schedule.tap_output`, the third `Schedule.t` parameter,
`Schedule.no_hook`, and the suspended `step_plan`/`step_with_hooks` protocol were
deleted. There is no compatibility alias: old ternary annotations and tap calls
fail at compile time.

Instrument the source operation instead:

- wrap an effect before `Effect.retry`, `retry_or_else`, or `repeat`;
- instrument `Resource.auto`'s `load`;
- put `Stream.tap_error` on the source before `Stream.retry` and use `Stream.tap`
  for emitted scheduled values;
- observe around `Schedule.step` in a custom driver.

This changes the observation boundary. The recipes see process attempts, loads,
or emitted values; they do not recreate terminal, policy-output,
state-publication, or branch-local schedule events. If an application genuinely
needs one of those structural boundaries, that is new demand evidence for a
future design—not a reason to rebuild the deleted hook protocol locally.
