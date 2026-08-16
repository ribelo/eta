# jsoo boundary warts

Type: grilling
Status: open
Blocked by: 03

## Question

Which JS-host boundary fixes does Eta add, change, or reject?

Candidates from the digest:

- `Eta_jsoo.Runtime.run_exn` renders typed failures as `<typed failure>`.
  This is a documented wart (`lib/jsoo/eta_jsoo.mli:41-45`). Decide a
  `~pp_err` argument, or a cause-rendering door shaped by
  [Runtime doors: entry points and exit rendering](03-runtime-doors-entry-points-and-exit-rendering.md).
- The `Effect.async` canceler contract. Correct usage exists in taumel
  (`await_abort_signal`) and was expensive to get right. Decide a documented
  recipe, or a safer API.

The runtime-per-call question on JS hosts belongs to
[Runtime lifecycle: sharing and per-call stance](04-runtime-lifecycle-sharing-and-per-call-stance.md),
not to this ticket.

The native OxCaml gates do not build the jsoo packages. Each accepted item
names its own verification story.
