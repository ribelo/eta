# Cmd.map and Sub.map: provide, or declare absent

Type: grilling
Status: open

## Question

Composition currently uses Elm's translator pattern: a parent passes a command constructor
down, and the child returns it among its scheduled commands. There is no map for commands or
subscriptions, and the notes nowhere say that the omission is deliberate.

These are the two combinators an Elm reader looks for first, and their absence changes how
components are written. The omission also interacts with subscription identity: the mapper
is excluded from identity, which is precisely the invariant a subscription map needs in
order to be safe. That is worth stating as the reason rather than leaving it implicit.

Decide:

- Whether eta_crux provides map for commands and for subscriptions, or states plainly that
  it does not. Either answer is acceptable; leaving it unstated is not.
- That the monoid operations exist for both commands and subscriptions — an empty value and
  a batch combinator.
- Where mapping is supported, that identity derives from the spec value and excludes the
  mapping function.
