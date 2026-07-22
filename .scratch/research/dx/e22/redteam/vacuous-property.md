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

## Attack: truncated schedule prefix

The original monotonic-delay property accepted an early [`None`] from
`Schedule.next` and then checked:

```ocaml
monotone [] = true
monotone [ only_delay ] = true
```

A regression that made every schedule terminate immediately therefore passed
all generated cases without producing a delay. This is direct semantic vacuity,
not merely weak generation.

## Verdict: REJECTED BY THE LIVE ASSERTION

The live property now checks `List.length delays = requested_length` before
monotonicity. For the attack example, `requested_length = 3` and `delays = []`,
so the coverage predicate is `0 = 3`, which is false; monotonicity is never
accepted as evidence. Every valid generated schedule must produce the complete
requested `Continue` prefix before its values are compared.

## Attack: generated label, fixed Drop program

The first `Drop` property accepted 50 generated integers as `_tag` and ignored
every one. All cases executed the same two-interceptor program with `Drop` always
outermost. The qcheck count therefore advertised variance that did not exist;
middle/inner placement, deeper nesting, replacement records, and attributes
could regress without producing a counterexample.

## Verdict: REJECTED BY THE POLICY ITSELF

The fixed-example clause in `AGENTS.md` applies even when a property has a
generator and reports 50 passes. The live generator now varies nesting on both
sides of `Drop`, the exact Drop position, record body, and attribute shapes. Its
model derives the exact executed prefix, skipped suffix, and sink outcome from
that generated input. Removing the Drop short-circuit or moving it one position
therefore falsifies a generated expectation instead of passing the same example
again.
