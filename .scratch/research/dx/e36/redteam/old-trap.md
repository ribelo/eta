# Old trap: dead protocol reader

## Attack

A required reader announces that the body has started, then fails while the body
waits forever:

```ocaml
let reader = await release |> Effect.bind (fun () -> Effect.fail `Reader_died) in
let body =
  Effect.finally record_cleanup
    (mark_ready |> Effect.bind (fun () -> Effect.never))
in
Effect.with_background reader (fun () -> body)
```

Under the old supervised implementation, `Reader_died` was only recorded. The
body remained in `never`, so this fixture invisibly continued and the enclosing
run hung unless an external timeout interrupted it.

## Result

The promoted tests `with_background typed failure cancels use and awaits
finalizers` and `with_background typed failure cancels use` release the reader
only after the body is ready. They require the exact `Cause.Fail Reader_died`
shape and exactly one body finalizer. They terminate without an external timeout
on native Eio and jsoo, proving the new generic spelling catches the old trap.

The defect counterparts repeat the attack with a raising reader and require the
same exception identity in `Cause.Die`; the failure cannot be swallowed into
supervision.
