# Teaching A — blueprint model from prose

An `('a, 'err) Effect.t` is a lazy blueprint. Constructing one does not perform
the work. `Runtime.run` interprets the blueprint later.

`Effect.pure` and `Effect.fail` are terminal descriptions. `Effect.map` adds a
pure success transformation. `Effect.bind` records an input blueprint and an
ordinary OCaml function that can construct the next blueprint after the input
succeeds. Because that function needs the runtime success value, static tools do
not call it early.

Consequently, preflight inspection can see the already-constructed input side
of a bind but not the continuation's future effect. A capability flag means a
visible declared leaf may use that capability. It is not a complete list of
what one runtime execution will do.

## Reviewer prompt

Sketch the static shape of two nested binds and explain whether a sleep returned
by the second continuation is visible before runtime interpretation.
