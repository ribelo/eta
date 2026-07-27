# API, representation, and footgun deltas

Endpoint identities: baseline `7d8e5236`, S `f136a68d` (code endpoint
`6c51b9e3`), R `82d17297`.

## Public/API census per affected cluster

| Cluster | BEFORE | S | R |
| --- | ---: | ---: | ---: |
| Capability-audit entries (`type audit`, `val audit`) | 2 | 0 | 0 |
| Aggregate/tree introspection vals (`collect_names`, `describe`) | 2 | 2 | 0 |
| Leaf-label query (`name`) | 1 | 1 | 1 |
| Audit assertion vals in `Eta_test` | 7 | 0 | 0 |
| `Expert.make` introspection/audit metadata parameters (`names`, `inherit_`, `capabilities`) | 3 | 1 (`names`) | 0 |

For context only, the affected interfaces contain 143/35 total `val`
declarations in `effect.mli`/`eta_test.mli` at baseline, 142/28 at S, and
140/28 at R. Those totals are mechanical counts, not all E39 surface.

## Representation census

| Mechanism | BEFORE | S | R |
| --- | --- | --- | --- |
| `Custom` record fields | 4: `eval`, `leaf_name`, `names`, `footprint` | 3: no `footprint` | 2: `eval`, `leaf_name` |
| Capability metadata | six-boolean record, unions, walkers, declarations | absent | absent |
| Propagated static-name list | present | present generally; `all` aggregation removed | absent |
| Explicit `~names` storage sites under `lib/` | 13 | 12 | 0 |
| Runtime tracing name path | direct closure argument | unchanged | unchanged |

The `~names` counts are reproducible with
`git grep -n -- '~names' <revision> -- lib`.

## Footgun delta

| Footgun / behavior | BEFORE | S | R |
| --- | --- | --- | --- |
| Audit can over-report and under-report | writable public contract | **removed** | removed |
| `assert_pure_eff` sounds like a purity proof despite static-only hedge | public | **removed** | removed |
| Custom leaf can lie with `~capabilities:[]` | executable | **unwritable** | unwritable |
| `all` vs `map_par` introspection asymmetry | names + footprints vs neither | **removed for `all`** | absent with names mechanism |
| `collect_names` omits continuation-created names | public, hedged | remains, hedged | **removed** |
| `describe` stops at opaque/custom and bind boundaries | public, explicit | remains, explicit | **removed** |

S deletes the misleading assurance vocabulary while preserving honest static
inspection. R reaches the smallest representation and eliminates the remaining
incomplete aggregate-name surface, at the cost of the deterministic tree view.
