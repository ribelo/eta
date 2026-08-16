# Effect-core friction and vocabulary

Type: grilling
Status: open
Blocked by:

## Question

What does Eta do about effect-core friction and vocabulary sprawl?

Candidates from the digest:

- An explicit exception-to-typed bridge, for example `sync_exn ~catch`, or a
  ppx lint for the `Effect.sync` plus raise trap. A raise inside
  `Effect.sync` becomes `Cause.Die`. This is the most repeated user mistake:
  pie's REVIEW.md lists four sites with fictional typed error rows.
  `sync_result` and `sync_option` exist, and the trap still recurs.
- The discovery fate of `to_option` and `to_result`. Pie hand-rolls the
  equivalent fold about 12 times and uses the real helpers once.
- Vocabulary pruning. `docs/api-dx.md` needs 1090 lines to teach lifter
  selection. The repo rule is delete-old-paths. Decide delete versus
  document for each lifter family: `from_result` and `flatten_result` and
  `sync_result`, `to_result` and `to_option` and `to_exit`, `when_` and
  `when_effect` and `unless` and `unless_effect`, and the rest.
- The fate of the two-monad supervisor: `Supervisor.Scope` with its own
  `let*` and `Scope.lift`. Consumers used it zero times. They prefer
  `with_background` and `par`.
- A recipe or a helper for typed-error glue between micro-domains. Pie has
  about 15 manual `map_error` translators at boundaries.

For each candidate: add, change, or reject, with a named shape sketch and
law-registry obligations.
