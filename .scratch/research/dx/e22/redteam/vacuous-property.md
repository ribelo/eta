# Red team: deliberately vacuous property

## Attack

This property is true regardless of Eta's implementation and must not be
admitted to the live suite:

```ocaml
QCheck.Test.make ~name:"fake map identity" generated_blueprint
  (fun blueprint ->
    let observed = observe (interpret blueprint) in
    observed = observed)
```

## Verdict: REJECT

It executes only one expression and compares the resulting value with itself.
Generation count, shrinking, and a green qcheck result cannot rescue it.

The E22 review controls catch this class mechanically enough to make it visible:

- every `LAWS.md` row names both sides of its statement;
- algebraic properties separately construct and run the left and right
  expressions before passing their outcomes to `equivalent` (the helper itself
  cannot detect a caller that supplies the same outcome twice);
- lifecycle properties require generated coverage of all four exit kinds;
- cancellation properties require an observable finalizer and an available,
  empty structured-fiber census;
- `QUESTIONS.md` explicitly asks whether either side or a required case can be
  deleted without making the property fail.

There is no honest generic runtime detector for semantic vacuity: a deliberately
malicious author can disguise `true`. The final gate is readable one-line law
inventory plus maintainer review, not a claim that qcheck itself proves a test is
meaningful.
