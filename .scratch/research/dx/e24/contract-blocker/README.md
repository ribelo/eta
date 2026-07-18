# E24 optional-last contract blocker

The signatures in this directory minimize the E24 public arrow order while
keeping the intended ordinary omission calls. Run from the repository root:

```sh
bash .scratch/research/dx/e24/contract-blocker/probe.sh
```

The probe succeeds only when OxCaml rejects the ordinary call because the last
optional argument remains as a partial function. It uses the repository's Nix
shell and copies sources to a temporary directory, so it leaves no build output
in the research bundle.

This proves only the contract-level blocker. It does not test the proposed
runtime behavior.
