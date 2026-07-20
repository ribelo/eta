# DX-E19 red-team pass

Run from the repository root:

```sh
bash .scratch/research/dx/e19/redteam/run.sh
ocaml .scratch/research/dx/e19/redteam/par-sibling-trap.ml
```

## RT-1 — expect a `par` sibling leak

The intentionally wrong oracle in `par-sibling-trap.ml` expects `(11, 11)`
when only the left branch installs clock 11. Native regression case 2 observes
`(11, 0)` and also checks logger/tracer isolation in both branch directions.
The trap therefore cannot pass. `Effect.with_clock`'s mli says “`par` siblings
are isolated,” and `docs/zio-boundaries.md` shows that the override must wrap
both branches when both need it.

Result: **DISARMED BY CONTRACT AND EXECUTABLE TEST**.

## RT-2 — override while a real sleep is in flight

Native regression case 11 starts a 30 ms sleep through the real Eio monotonic
clock, waits until `sleep` has been called, then runs a clock-999 override in a
sibling scope. The override reports 999, while the first fiber still waits at
least 20 ms for its originally selected clock. It is not accelerated or moved
to the later clock.

Result: **IN-FLIGHT SLEEP KEEPS ITS CALL-TIME CLOCK**. The mli says “in-flight
sleeps are unchanged.”

## RT-3 — daemon outlives the override

Native regression case 7 starts a daemon under all four overrides, blocks it on
a gate, returns from the lexical override, then releases the daemon. The daemon
observes clock 88 and records only into the override logger/tracer; the runtime
base sinks remain empty.

Result: **DAEMON KEEPS ITS FORK-TIME BINDINGS**. Every combinator's mli warns
that daemons retain the inherited binding after scope exit.
