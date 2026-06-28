# sync_async_survival

Effet-hpt evidence for collapsing `Sync` and `Async` into one `Thunk` leaf.

Current branch result:

- `Effect.t` has one leaf constructor: `Thunk`.
- `Effect.sync` is removed.
- `Effect.async` is removed.
- `[%effet.thunk ...]` is the only PPX leaf extension.
- Runtime instrumentation still uses the leaf name carried by the constructor.

Verification:

```sh
nix develop -c dune build packages/effet packages/ppx_effet
```

The deleted distinction had no runtime case left: before this pass
`runtime.ml` interpreted `EP.Sync` and `EP.Async` with identical code before
this change.
