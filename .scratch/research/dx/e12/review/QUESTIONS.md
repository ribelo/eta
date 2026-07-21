# DX-E12 review questions

1. **What does `uses_clock = false` guarantee?**

   Expected: no clock footprint is declared by the currently visible static
   spine or its declared Eta library leaves. It does not constrain an effect
   later returned by an opaque bind/handler/mapper continuation, arbitrary OCaml
   work inside `sync`, or a false `Expert.make` declaration.

2. **Does `uses_clock = true` mean every execution reads or sleeps on a clock?**

   Expected: no. True is a conservative static possibility. A failed
   predecessor, disabled observability sink, untaken branch, empty collection,
   or schedule decision can prevent the operation on one run.

3. **Why does `describe` print `<bind …>`?**

   Expected: the continuation is an ordinary function that needs a success
   value. Calling it during inspection would execute user code, invent a value,
   and change the semantics from static description to partial interpretation.

4. **What does `assert_pure_eff` prove?**

   Expected: no declared Eta capability footprint in the visible static
   blueprint. It does not prove referential transparency of arbitrary OCaml
   closures.

5. **Which lesson is easier to verify: prose or real output? Rate each 1–5.**

   Promotion threshold: the `describe` lesson averages at least 4/5. Reviewers
   should cite whether the literal `<bind …>` makes the caveat easier to retain.
