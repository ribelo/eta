# P0 prior art - algebraic effects as a service substrate

## Question

Can OCaml 5 native algebraic effects be used as an opt-in mechanism for Eta
services, and can the lab draw an observable boundary between effect-suitable
services and value-passing-suitable services?

## Sources checked

- OCaml 5 stdlib Effect interface:
  /nix/store/.../lib/ocaml/effect.mli and
  https://ocaml.org/manual/effects.html.
- Eio fiber-local storage docs:
  /nix/store/.../site-lib/eio/core/eio__core.mli.
- Eio capability style from installed docs and APIs:
  Eio.Stdenv, Eio.Switch, Eio.Fiber, Eio.Path, and the fiber-local storage
  warning in eio__core.mli.
- Effekt docs:
  https://effekt-lang.org/docs/concepts/effect-safety and
  https://effekt-lang.org/tour/captures.
- Eff language site:
  https://www.eff-lang.org/learn/.
- Koka book:
  https://koka-lang.github.io/koka/doc/book.html.
- Local Eta prior work:
  journal.md R-channel entries, scratch/layer_research/,
  scratch/provide_survival/, and
  ../Eta-native-effects/scratch/eta_research/native_effects_pivot/.

## Findings

### Effekt

Effekt is the strongest positive prior for the hypothesis because its effects
are statically tracked requirements on the calling context. The docs say
effects are requirements and handlers introduce capabilities; captures are also
tracked to prevent capabilities from escaping lexical scope. This is the shape
Eta would want if service effects were to be safe by construction.

Eta does not have this mechanism in OCaml. type _ Effect.t += ... creates an
open runtime operation, but OCaml does not infer or check that a matching
handler is installed at the call site or boot boundary.

### Eff

Eff is useful as the conceptual source for algebraic effects and handlers, but
it is not direct evidence for Eta service injection. The site points readers to
introductory algebraic-effects material; it does not remove OCaml's missing
handler-presence check or Eio fiber-locality behavior.

### Koka

Koka is a strong positive prior for typed effect rows. Its book presents effect
typing, polymorphic effects, handler composition, and dynamic binding of
handlers. That supports the idea that service requirements can be made explicit
and composable in a language with effect rows.

OCaml's native effects do not carry Koka-style rows. Eta would have to add a
separate witness/token/registry layer to recover handler-presence evidence. The
local scratch/native_effects_research/ R-D typed request DSL already found that
this moves the cost back into explicit witness passing.

### OCaml 5 native effects

The stdlib interface exposes an open effect type and perform, with
Effect.Unhandled raised when no handler is installed. This gives Eta an
excellent low-level primitive for local control effects, but the missing
handler-presence check is load-bearing for services: a forgotten service handler
is not rejected by the type checker.

### Eio

Eio uses explicit capabilities such as Stdenv, clock, fs, net, and switches,
and fiber-local storage only for narrow contextual data. Its docs explicitly
warn that fiber-local variables act like another form of global state and say
to prefer passing arguments explicitly when possible.

The same docs also say Fiber.with_binding bindings are propagated to forked
fibers. This is the best possible rescue mechanism for service effects: store
the service implementation in FLS and reinstall a native handler inside a child
fiber.

### Local Eta prior work

The native-effects pivot already found handlers are fiber-local across
Eio.Fiber.both and require per-fork reinstall. The R-channel, provide, and
layer labs repeatedly found that ordinary OCaml values and scoped factories beat
generic service machinery when the machinery does not add static safety or a
new lifecycle property.

## P0 implication for P1

P1 must distinguish three cases:

1. Root handler works in same-fiber code.
2. Root handler does not cross Eio child-fiber boundaries.
3. Eio FLS can carry service implementations to children, but a service
   substrate is viable only if the handler can be reinstalled with at most one
   well-named call at each user-visible fork site.

If any Eta primitive creates an internal child fiber that can run service
effects but does not expose a wrapping point, native service effects fail the
locality bar for this lab.
