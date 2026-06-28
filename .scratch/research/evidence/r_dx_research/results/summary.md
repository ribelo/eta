# R-channel DX Measurements

Generated fixture: 20 modules per variant, 30 capability methods, deep chain
through m01..m20.

## Build Times

Single local run, measured with date-based wall clock after removing the
scratch build subtree.

| Measurement | ms |
|---|---:|
| clean all variants | 525 |
| clean env-row top | 189 |
| clean args top | 187 |
| clean bag top | 236 |
| noop incremental all | 41 |
| touch env_m10 rebuild top | 28 |
| touch args_m10 rebuild top | 29 |
| touch bag_m10 rebuild top | 30 |
| shape refactor failed rebuild | 442 |

## Interface Size

ocamlc -i output:

| Variant | bytes | lines |
|---|---:|---:|
| env-row top | 851 | 16 |
| args top | 901 | 32 |
| bag top | 88 | 2 |

## Error Size

Warnings from nix dirty-tree output excluded.

| Probe | bytes | lines |
|---|---:|---:|
| env missing capability | 2295 | 40 |
| args missing capability | 689 | 15 |
| bag shape refactor | 2284 | 38 |
| env generic method collision | 391 | 8 |

## Notes

- env-row module values needed thunks because open object rows hit the value
  restriction at module boundaries.
- env-row missing-capability errors are precise at the final sentence but long.
- args missing-capability errors are shorter and name the missing argument.
- bag hover/interface output is shortest, but it hides per-effect capability use.
