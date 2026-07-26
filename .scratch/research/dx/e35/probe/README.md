# DX-E35 boundary probe

This standalone Dune project runs each depth/case in a fresh process on native
OCaml and under js_of_ocaml/Node. It validates successful values, exact recovery
handler counts, and cause leaf count/order rather than treating mere process
survival as a pass.

## Cases

- `dynamic_bind`: each continuation constructs the next bind during evaluation.
- `static_map`: a fully prebuilt left-deep map tree.
- `concat`: a fully prebuilt list passed to `Effect.concat`.
- `bind_error`: fully prebuilt nested recovery wrappers; every handler runs and
  propagates the same typed failure.
- `cause_sequential` / `cause_concurrent`: public binary cause constructors form
  a left-deep tree, then `Cause.failures` traverses it and verifies leaf order.

## Build and run

From the repository root:

```sh
nix develop .#mainline -c bash .scratch/research/dx/e35/probe/build.sh
nix develop .#mainline -c bash \
  .scratch/research/dx/e35/probe/run-case.sh native dynamic_bind 10000
nix develop .#mainline -c bash \
  .scratch/research/dx/e35/probe/run-case.sh jsoo dynamic_bind 10000
```

`build.sh` first builds the current repository's `@install` tree and points the
separate probe project at it through `OCAMLPATH`. This prevents an installed,
stale Eta package from contaminating post-rewrite measurements.

`run-case.sh` imposes a per-process timeout (default 180 seconds, configurable
with `E35_TIMEOUT_SECONDS`) and normalizes caught exceptions, runtime-captured
stack-overflow defects, signals, timeouts, and other process exits to one
`RESULT` line. A case-level failure is deliberately reported in output rather
than as a nonzero shell status so the complete matrix can be collected without
special shell control flow.

The requested measurement matrix and exact boundary-search method are recorded
in `RESULTS.md` after this corpus is committed, preserving probe-before-verdict
ordering.
