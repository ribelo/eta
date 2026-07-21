# Teaching B — blueprint model from real `describe` output

This value has two nested sequencing steps:

```ocaml
let program =
  Effect.unit
  |> Effect.bind (fun () -> Effect.unit)
  |> Effect.bind (fun () -> Effect.sleep (Duration.ms 10))
```

The committed `describe` snapshot for that static shape is:

```text
Bind
  Bind
    Pure
    <bind …>
  <bind …>
```

This output is produced by
`test/effect_introspection/snapshot_effect_describe.ml` and pinned in
`expected_descriptions.txt`; it is not a hand-drawn conceptual tree.

`Pure` is the visible initial blueprint. Each `Bind` shows its already-built
input and prints `<bind …>` instead of calling the ordinary OCaml continuation.
The final `Effect.sleep` therefore does not appear in this static output and
does not set `uses_clock`. `Runtime.run` will call the continuation after the
input succeeds and will then execute the sleep.

## Reviewer prompt

Point to the exact output line that prevents `describe` from claiming it can
see the final sleep, then explain what `uses_clock = false` means for this value.
