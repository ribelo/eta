# Vocabulary: Elm names and the Task framing

Type: grilling
Status: resolved

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

## Answer

Eta Crux keeps its own canonical vocabulary:

- An **action** is typed input for one cell transition. A **message** is a boundary envelope
  or shell-capability value.
- A **model** is the application value owned by one cell. State remains the general term for
  runtime state or aggregate application state.
- A **scheduled command** contains **command work** and Eta Crux metadata. Command work is a
  force-total Eta effect that resolves to one action.
- A **subscription** is a state-derived long-lived source whose items become actions.
- A **fragment** is one addressed output value. The **output tree** is the aggregate of all
  live fragments.
- **Startup input** is the reserved term for Elm flags. Its type and lifecycle remain open.

Transitions compose scheduled commands as ordinary lists. Application code also composes
subscriptions as ordinary lists. The empty list expresses no work or no subscriptions. List
construction and concatenation provide batching. Eta Crux adds no `none` or `batch`
functions for these collections.

The [concepts note](../../../requirements/eta-crux/concepts.md) contains an explanatory Elm
correspondence. It maps command work to `Task` after `Task.attempt`, and Eta effect
composition to `Task.andThen`. It also states the differences in ownership, interruption,
defects, and output shape. The comparison creates no Elm compatibility contract.

Elm names appear only in that correspondence and other explicit comparisons. The rest of
the requirement bundle uses Eta Crux terms. This decision locks conceptual vocabulary, not
public OCaml identifiers. [One public API across both state
backends](02-one-api-across-backends.md) and later API tickets own those identifiers.

The decision is reflected in the [domain glossary](../../../../CONTEXT.md), the concepts
note, and the affected requirement notes. Subscription list composition is requirement
`sub-zg59`.
