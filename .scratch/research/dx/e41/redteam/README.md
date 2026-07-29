# DX-E41 red-team — ownership misreading and leak attempt

## The bug invited by the old name

The following looked like a scoped acquisition because `Resource` sat beside
Eta's actual acquire/release API and `auto` returned a handle:

```ocaml
Effect.with_scope
  (let open Eta.Syntax in
   let* resource = Eta.Resource.auto ~load ~schedule () in
   use resource)
```

A reader could reasonably expect the enclosing scope to release-fence the
handle and stop its work. It did not. `Resource.auto` started a runtime-owned
daemon, so exiting `with_scope` or finishing `use` did not own that daemon. The
handle represented a stale-while-refresh cache, not an acquired resource, and
the name suggested the opposite lifecycle.

**Verdict: REPRODUCED BY API SHAPE.** The old shape made the incorrect ownership
model both readable and type-correct.

## New-shape leak attempts

### Attempt 1: return the handle from the callback

```ocaml
Eta_cache.Refreshable.with_auto ~load ~schedule (fun refreshable ->
    Effect.pure refreshable)
```

The handle can be the callback result, but the refresh loop cannot be. Before
the outer effect publishes that result, `with_supervised_background` cancels and
awaits its child. The returned handle still supports `get` and explicit
`refresh`; it no longer has automatic work behind it.

Evidence: `Refreshable with_auto stops loop on body success` observes an
in-flight refresh, returns successfully, then proves its finalizer completed and
the load count remains fixed. `Refreshable with_auto leaves empty fiber census`
independently observes an available empty `Eta_test` census after the callback.

**Verdict: PASS — handle escape does not imply loop escape.**

### Attempt 2: capture the handle outside, then fail, die, or cancel

Capturing the handle in an application ref does not capture the supervised
child. The callback's typed failure, defect, and parent cancellation paths all
cross the same lexical finalizer that cancels and awaits the loop.

Evidence: the three named `Refreshable with_auto stops loop on body ...` tests
for typed failure, defect, and cancellation each start a blocked refresh, force
the stated exit, observe its finalizer, and prove no later load occurs. The
in-flight-finalizer test additionally holds refresh cleanup open and proves the
outer call cannot settle before cleanup is released.

**Verdict: PASS — all non-success exits retain the lexical fence.**

### Attempt 3: rebuild runtime-owned refresh from public cache API

`Eta_cache.Refreshable` exposes no fork, daemon, supervisor child, or detached
constructor. `with_auto` delegates only to public
`Effect.with_supervised_background`, whose callback is mandatory. Composing it
with `Effect.with_scope` can only add an outer lexical boundary; it cannot detach
the supervised child.

The only way found to recreate the old lifetime is to leave the cache API and
call unstable `Eta.Spi.daemon` directly (or provide a different runtime-owned
infrastructure module). That is precisely the SPI escape excluded by E41, not a
leak through the new public shape.

**Verdict: PASS — leaking the refresh loop is impossible through public
`Refreshable`/`Effect` machinery; SPI is required.**

## Overall verdict

**PROMOTE.** The rename removes the acquire/release collision, and the callback
shape makes ownership explicit. The value may escape; its automatic refresh
fiber cannot.
