# DX-E15 Phase 0 probes

These probes execute the existing cancellation substrates before any DX-E15
design or implementation change.

## Native Eio

```sh
nix develop -c dune exec \
  --root .scratch/research/dx/e15/probes ./native_probe.exe
```

`native_probe.ml` asserts the propagation/protection matrix rather than merely
printing an observed trace:

- parent cancellation stops at `Cancel.protect`, including an unprotected
  `Cancel.sub` descendant blocked on a promise;
- explicitly cancelling that sub-context raises through the outer protection;
- nested protection returns normally and Eio observes the pending old-parent
  cancellation at the next explicit check after the outer protection returns.

## js_of_ocaml CPS

The probe must link the current worktree rather than any previously installed
Eta. Build and install the worktree into a temporary prefix, put that prefix
first on `OCAMLPATH`, and compile the separate probe project:

```sh
prefix="$(mktemp -d)"
trap 'rm -rf "$prefix"' EXIT
nix develop .#mainline -c sh -eu -c '
  prefix="$1"
  dune build @install
  dune install --prefix "$prefix"
  OCAMLPATH="$prefix/lib${OCAMLPATH:+:$OCAMLPATH}" \
    dune build --root .scratch/research/dx/e15/probes jsoo_probe.bc.js
  node .scratch/research/dx/e15/probes/_build/default/jsoo_probe.bc.js
' sh "$prefix"
```

`jsoo_probe.ml` has a Node `beforeExit` sentinel and asserts that:

- cancellation remains pending at protection depths two and one;
- returning the outer protection to depth zero delivers it at that return edge;
- a sub-context created under protection after its parent is already cancelled
  is not seeded with the pending reason, but returning to the cancelled parent
  at the protection exit still delivers it.

Captured outputs and the resulting matrix are recorded in `../phase0.md`.
