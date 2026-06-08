# oxcaml_research

Research workspace for testing whether OxCaml earns a permanent switch for
Effet.

Final spike verdict: switch toward OxCaml. Under the user's churn-free,
parallelism-and-safety framing, OxCaml mechanically guarantees three
Effet-specific invariants that mainline OCaml cannot encode at all
(domain-portable AST, once-shot release, local_-bound switches), and the
shipped library already builds and tests under `5.2.0+ox`. See
`results.md` for the cross-tab and per-fixture evidence and
`results/compile.out` for the latest reproduction (`pass=27 fail=0`).
The earlier branch-only conclusion is superseded; it was based on
migration cost and dependency weight, both ruled out by the user.

The default Nix shell remains the mainline OCaml path:

    nix develop -c dune runtest --force

Use the separate OxCaml shell for spike work:

    nix develop .#oxcaml
    effet-oxcaml-init
    effet-oxcaml-test-shipped

If a previous setup attempt left a partial switch, remove it before retrying:

    OPAMROOT=$PWD/.opam-oxcaml opam switch remove 5.2.0+ox -y

`effet-oxcaml-init` creates an opam root in `.opam-oxcaml/` and an OxCaml
`5.2.0+ox` switch using the upstream OxCaml opam repository. The helper then
installs this worktree's package dependencies with tests enabled. The helper
passes `--assume-depexts` because host system packages are supplied by the
flake shell, not by opam's NixOS depext integration.

The mode research also needs OxCaml-specific packages that are not part of
Effet's normal dependency set:

    nix develop .#oxcaml -c bash -lc 'opam install capsule portable parallel --yes --assume-depexts'

`effet-oxcaml-test-shipped` intentionally tests shipped packages only. Full
`dune build` still includes old scratch experiments, so it is not the first
OxCaml gate for this branch.

Initial gates:

- Baseline: current shipped packages compile and test under OxCaml.
- Resource: decide whether `Resource.t` stays fiber-local or gains a
  portable/domain-safe variant.
- Supervisor: check whether local child handles simplify the current rank-2
  scoped handle design.
- Runtime internals: keep mode annotations inside implementation modules or
  PPX output; normal Effet examples should not become mode-heavy.

Run the fixture lab with:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/run.sh
