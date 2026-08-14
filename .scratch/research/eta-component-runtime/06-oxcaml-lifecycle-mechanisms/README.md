# OxCaml lifecycle compiler probes

This bundle preserves the compiler probes for the
[OxCaml lifecycle report](../06-oxcaml-lifecycle-mechanisms.md).

The probes use the repository compiler. They do not test lifecycle semantics.
They test the static limits that the report assigns to OxCaml.

## Contents

- `probes/` contains two accepted programs and six rejected programs.
- `run.sh` compiles every probe and checks its exit code.
- `results/` contains the complete compiler output from the last run.
- `results/toolchain.txt` contains the compiler path, version, configuration,
  architecture, and pinned OxCaml source revision.

The result files preserve compiler whitespace exactly. The local
`.gitattributes` file disables whitespace warnings for them.

The runner copies each source file to a temporary directory before compilation.
Thus, compiler diagnostics contain stable source names instead of worktree
paths.

## Run

Run the bundle from the repository root:

```sh
env XDG_CACHE_HOME=/tmp/eta-nix-cache nix develop -c bash \
  .scratch/research/eta-component-runtime/06-oxcaml-lifecycle-mechanisms/run.sh
```

The runner records the expected exit and actual exit in each result file. It
exits with a nonzero status if one or more results differ.

## Expected results

| Probe | Expected exit | Evidence |
| --- | ---: | --- |
| `positive` | 0 | The requested mode annotations and kind crossing compile. |
| `affine_drop` | 0 | `unique` values and `once` closures can be discarded. |
| `local_escape` | 2 | A local reference cannot escape its region. |
| `nonportable_closure` | 2 | A closure that mutates a captured ref is not portable. |
| `contended_mutation` | 2 | Unprotected mutation requires uncontended access. |
| `unique_twice` | 2 | A unique value cannot be consumed twice. |
| `once_twice` | 2 | A once closure cannot be called twice. |
| `capsule_unavailable` | 2 | `Capsule` is not available without an external package. |

Exit code `2` is the compiler's type-error exit for these rejected probes.
