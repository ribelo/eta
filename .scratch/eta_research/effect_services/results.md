# effect_services results

## Verdict

Closed at P1. OCaml 5 native algebraic effects are not viable as an Eta service
substrate in this worktree when the design is a generic root-installed handler
used directly by arbitrary services.

The root handler works in same-fiber code, nested Switch.run,
Eta.Effect.timeout body execution, and Eta.Effect.acquire_release body/release.
It does not propagate into Eio child fibers. Eio FLS makes user-owned
Fiber.both and Fiber.fork recoverable with a wrapper, but Eta.Supervisor.scoped
creates internal child fibers that application code cannot wrap at the actual
fork site.

The only external rescue for supervisor children is wrapping each service leaf,
which is not the accepted <= one call per fork-site pattern. It turns the design
into FLS lookup sugar rather than root-installed service effects.

## Probes

- P0 prior art: prior_art.md.
- P1 locality: p1_locality/p1_locality.ml and p1_locality/results.md.
- P2-P8: not run because P1 fired the hard stop condition.

## Commands run

    nix develop -c eta-oxcaml-init
    nix develop -c dune build scratch/eta_research/effect_services
    nix develop -c dune exec scratch/eta_research/effect_services/p1_locality/p1_locality.exe

eta-oxcaml-init partially failed at eio_linux.1.3+ox, but the probe does not
depend on eio_main or eio_linux; it builds and runs with eio_posix.

## Boundary rule

A service can use OCaml native effects in Eta only if every execution path that
may perform the service is guaranteed to stay under the installed handler, or
every fiber creation point that may cross the handler boundary is user-visible
and can be wrapped with one named call.

Current Eta services do not meet that bar once Supervisor.scoped is in scope.
Therefore the effect-suitable set for this lab is empty.

## P9 Logger addendum

P9 re-opened only the narrower user-facing Logger question. It does not revive
generic service DI.

Result: a Logger API can be made robust if Eta owns the public API, hides the
raw effect constructor, installs the handler in runtime scopes, and carries the
configured logger through Eio fiber-local storage plus Domain-local storage as a
fallback. See p9_logger_domain/results.md and logger_domain_addendum.md.
