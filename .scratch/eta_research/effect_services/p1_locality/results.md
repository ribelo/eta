# P1 locality results

## Command

    nix develop -c dune build scratch/eta_research/effect_services
    nix develop -c dune exec scratch/eta_research/effect_services/p1_locality/p1_locality.exe

The executable uses Eio_posix.run because the local eta-oxcaml-init run failed
to build eio_linux.1.3+ox; eio, eio_posix, portable, and the Eta runtime
dependencies needed by this probe installed successfully.

## Output

    case=direct_same_fiber_root_handler status=resolved events=[direct] detail=returned
    case=eio_fiber_both_bare status=unhandled events=[] detail=raised Effect.Unhandled
    case=eio_fiber_both_branch_reinstall status=resolved events=[left,right] detail=returned
    case=eio_fiber_fork_bare status=unhandled events=[] detail=raised Effect.Unhandled
    case=eio_fiber_fork_child_reinstall status=resolved events=[fork] detail=returned
    case=nested_switch_run_bare status=resolved events=[nested-switch] detail=returned
    case=eta_effect_timeout_bare status=resolved events=[timeout] detail=Runtime.run returned Exit.Ok
    case=eta_effect_timeout_leaf_reinstall status=resolved events=[timeout] detail=Runtime.run returned Exit.Ok
    case=eta_supervisor_scoped_two_children_bare status=unhandled events=[] detail=Runtime.run returned Exit.Error containing Effect.Unhandled: Supervisor failures contained 2 unhandled cause(s)
    case=eta_supervisor_scoped_leaf_reinstall status=resolved events=[supervisor-left,supervisor-right] detail=Runtime.run returned Exit.Ok
    case=eta_acquire_release_body_release_bare status=resolved events=[body,release] detail=Runtime.run returned Exit.Ok
    p1 locality evidence complete

## Classification

| Probe | Root handler propagates? | Reinstall result | Acceptable? |
| --- | --- | --- | --- |
| Same-fiber direct perform | Yes | Not needed | Yes |
| Eio.Fiber.both branches | No | Branch reinstall through Eio FLS works | Yes for user-owned fork sites |
| Eio.Fiber.fork child | No | Child reinstall through Eio FLS works | Yes for user-owned fork sites |
| Nested Eio.Switch.run | Yes | Not needed | Yes |
| Eta.Effect.timeout body | Yes | Not needed | Yes |
| Eta.Supervisor.scoped children | No | Leaf self-reinstall works | No |
| Eta.Effect.acquire_release body/release | Yes | Not needed | Yes |

## Verdict

P1 fails the locality bar.

The failure is not that every fork is hopeless. For user-owned Eio fork sites,
one wrapper can reinstall the handler in each branch or child, using Eio
fiber-local storage to carry the service implementation.

The falsifier is Supervisor.scoped: Eta creates the child fibers internally.
The application can write start sup (lift child), but it cannot wrap the actual
internal fork or generically wrap an arbitrary Eta.Effect.t so its evaluation
happens under a native service handler. The only external rescue shown by the
executable is eta_log_reinstall, which wraps each service leaf. That is not one
well-named call per fork site; it is service-call-site tax and collapses the
design into effects as sugar over fiber-local lookup.

## Stop condition

The objective's P1 stop condition fires: propagation is broken and no acceptable
wrapping primitive exists for every required fork boundary.

No P2-P8 probes should run in this lab. Further composition, cancellation,
unhandled-mitigation, DX, mocking, boundary, and DI sketches would be testing a
mechanism that already failed the mandatory locality precondition.

## What would change the verdict

- OCaml/Eio gains handler inheritance across Eio child fibers, so a root native
  service handler covers Fiber.both, Fiber.fork, and Eta supervisor children.
- Eta exposes or implements a generic service-handler capture/reinstall hook for
  every internal fiber creation point, without requiring each service operation
  to self-wrap and without changing ordinary Eta effects into FLS lookups.
- A future OCaml effect-row or handler-presence mechanism provides static
  service-handler evidence and composes with Eio structured concurrency.
