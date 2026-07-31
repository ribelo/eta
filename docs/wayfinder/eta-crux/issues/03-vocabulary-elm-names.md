# Vocabulary: Elm names and the Task framing

Type: grilling
Status: open

## Question

Reviewers describe this system in Elm vocabulary — Msg, Cmd, Sub, Model, ViewModel, flags,
Task — while the requirement notes use action, scheduled command, subscription, model and
fragment. Decide the canonical vocabulary and apply it across the bundle and the concepts
note.

Also decide whether to state the Elm correspondence outright:

- Command work is a force-total Eta effect resolving to one action, with typed failures
  folded in before scheduling. That is exactly Elm's `Task x a` converted through
  `Task.attempt : (Result x a -> msg) -> Task x a -> Cmd msg`, and the existing rule that
  sequencing happens inside one command is `Task.andThen`. Naming this gives free
  comprehension to anyone arriving from Elm or Crux, and makes fold-errors-first read as a
  known law rather than a local restriction.
- Whether the monoid operations are named as `Cmd.none`, `Cmd.batch`, `Sub.none` and
  `Sub.batch` equivalents.

Constraint: requirement notes carry no rationale, so the correspondence itself belongs in
the concepts vocabulary note or an ADR, not in a requirement bullet.
