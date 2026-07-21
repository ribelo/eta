# DX-E12 examples audit manifest

`examples.golden` records `Effect.audit` immediately before every supported
`Runtime.run` boundary reached by one normal execution of all 54 committed
`examples/*.ml` programs. Programs with no reached Eta runtime boundary are
recorded explicitly.

Regenerate from the repository root, inside the OxCaml Nix shell:

```sh
nix develop -c bash .scratch/research/dx/e12/manifest/regenerate.sh
```

The script copies the examples into a temporary Dune workspace directory,
injects a capture wrapper around the textual `Eta.Runtime.run`,
`Eta_eio.Runtime.run`, and opened `Runtime.run` forms used by this corpus, then
compiles and executes those copies unchanged otherwise. It never edits
`examples/`. The wrapper calls the real `Effect.audit` on the exact effect value
passed to each reached boundary before delegating to the real runtime. Any
example timeout or nonzero exit fails regeneration instead of blessing partial
output. The temporary sources are deleted on exit.

The manifest is static-preflight evidence, not a runtime inventory. In
particular, effects constructed by bind continuations after the capture remain
outside the audit, exactly as documented by `Effect.audit`.
