# Daemon pending-fiber red team

Executable: `test/test/dx_e11_daemon_pending.ml`

Run with:

```sh
nix develop -c dune exec test/test/dx_e11_daemon_pending.exe
```

The program starts `Effect.daemon Effect.never`, lets the root effect return,
and prints the resulting golden record. The pending entry is rendered as
`kind=daemon(runtime-owned)`: it is runtime-owned work, not labeled a leak.

Structured children are registered as `kind=structured`, but Eta's lexical
runtime scopes join or cancel them before the root exit becomes available. The
canonical `completed structured fibers are not pending` test proves the normal
case. Consequently a structured entry in a root-exit snapshot would identify an
abnormal escaped child, while a daemon entry explicitly identifies owned work.
