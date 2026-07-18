# Red-team verdict

Probe: `probe_bind_error_exception.ml`

Intent: use `bind_error` as if it were `try/with` to swallow a `Failure`
raised from `Effect.sync`.

Observed output:

```
typed:recovered
defect:surfaces Die exn=Failure("secret-boom") span=- annotations=0
verdict:bind_error did not catch the exception
```

The defect surfaces as `Exit.Error (Cause.Die _)`. Span status and
annotations are empty here because the leaf was not wrapped in a named span;
the important result is that the handler never ran and the exception was not
reified into a typed success.

Does the new shape still invite the mistake? Less so than `catch`: there is no
Stdlib `bind_error` exception analogue, and the name sits next to `bind` /
`map_error` on the error channel. A reader can still write the same wrong
handler, but the runtime refuses to honor the exception-swallowing intent.
