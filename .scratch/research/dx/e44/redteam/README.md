# DX-E44 red-team verdicts

## 1. Root-only observability call

`root-only-combinator/` declares only `(libraries eta)` while the local install
root contains both packages. Building its call to
`Eta_observability.log_info` fails with `Unbound module "Eta_observability"`.
Package declaration is therefore an effective compile-time fence; root does not
re-export or forward the SDK.

Command:

```sh
OCAMLPATH="$PWD/_build/install/default/lib" \
  nix develop -c dune build \
  --root .scratch/research/dx/e44/redteam/root-only-combinator
```

Raw result: `root-only-combinator/output.txt` (expected exit 1).

## 2. Dependency cycle

`cycle-probe.sh` temporarily adds the forbidden root
`eta -> eta_observability` edge, builds root, and restores `lib/eta/dune` under a
trap. Dune reports the exact cycle:

```text
eta -> eta_observability -> eta
```

Raw result: `cycle-output.txt`. A post-probe `git diff --exit-code --
lib/eta/dune` confirms restoration.

## 3. Root-only hand-written tracer

`root-defect/` declares `eta`, `eta_eio`, and `eio_main`, but not
`eta_observability`. It supplies an object implementing
`Capabilities.tracer`, runs a defective root `Effect.with_background ~name`
span, and requires an `exception` event with `exception.type` and
`eta.cause.path` attributes.

Command:

```sh
OCAMLPATH="$PWD/_build/install/default/lib" \
  nix develop -c dune exec \
  --root .scratch/research/dx/e44/redteam/root-defect ./probe.exe
```

Raw result: `root-defect/output.txt` (`PASS root-only tracer received defect
annotation`). This proves the interpreter diagnostic write path works with the
SDK absent.

## Verdict

All three adversarial probes passed their expected boundary outcome.
