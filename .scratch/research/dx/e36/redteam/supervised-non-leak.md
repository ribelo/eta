# Supervised variant non-leak attempt

## Attack

Force the supervised child to fail while the body is observably blocked, yield
the scheduler, and check whether child failure cancels or otherwise completes the
body before its independent release:

```ocaml
let child = await fail_now |> Effect.bind (fun () -> Effect.fail `Child_died) in
let body = mark_started *> await finish_body *> mark_completed in
Effect.with_supervised_background child (fun () -> body)
```

## Result

`with_supervised_background failure does not cancel use` observes
`body_completed = false` after child failure and a scheduler yield, then releases
the body and observes `body_completed = true`. Only after body completion does
the already-recorded child failure surface through the existing cleanup
diagnostic. The jsoo counterpart reaches the same ordering.

The three mechanically migrated current-behavior tests also retain child
cancellation, await, finalizer, use-failure, and child-cleanup-failure behavior.
No attempted child failure leaked into the running body.
