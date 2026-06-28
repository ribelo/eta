## Summary

## Verification

- [ ] nix develop -c dune build @install
- [ ] nix develop -c dune runtest --force
- [ ] nix develop -c eta-oxcaml-test-shipped
- [ ] JS track if applicable: nix develop .#mainline -c dune runtest <target> --force
- [ ] Benchmarks if performance-sensitive: nix develop -c dune build @bench or nix develop -c bash bench/run.sh --quick

## Boundary Check

- [ ] Root `eta` did not gain optional/provider/test/system dependencies.
- [ ] Optional features live in their `eta_<feature>` package.
- [ ] Public API changes update both `.ml` and `.mli` files.
