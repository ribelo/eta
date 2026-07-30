# DX-E44 PR-style review pointers

## Actual change

Review the complete executor range, not copied snippets:

```sh
git diff --find-renames fd27e518..HEAD
git diff --stat fd27e518..HEAD
git log --oneline fd27e518..HEAD
```

`fd27e518` is the pre-executor branch tip. The range includes the executor's
sealed journal, docs-first contract, implementation, full migration,
performance follow-up, evidence, red-team probes, and final report.

Key commits:

- `027d5500` — seal executor predictions;
- `6bf3038f` — docs-first package boundary and moved contracts;
- `e44aa96b` — split the SDK from root;
- `bd604bbe` — migrate consumers, PPX, docs, tests, examples, and package deps;
- `9745169e` — restore hot-path allocation/wall parity;
- `e51f9e2e` — commit dependency, census, gate, migration, and benchmark proof;
- `dd4e4247` — commit adversarial boundary probes.
- `b66c56ec` — correct final independent-review law pointers and stale error path.
- `f6ce2182` — address F1-F4 contracts, tests, laws, and changelog;
- `8cfb17c5` — stream timestamped batches and commit expanded paired evidence.
- `c2249a62` — strengthen fork isolation tests and repair shifted law pointers.

## Boundary and public contract

- Package boundary and usage: `lib/observability/README.md`
- Flat SDK contract: `lib/observability/eta_observability.mli`
- Package map/re-tiering: `docs/packages.md`
- Breaking draft: `.scratch/research/dx/e44/CHANGELOG.md`
- PPX expansion: `lib/ppx/ppx_eta.ml` and
  `test/ppx_expansion/expected_expansions.txt`

## Fiber-local seam

- Root-owned keys and diagnostic path: `lib/eta/runtime_observability.ml`
- Behavioral, key-free SDK seam: `lib/eta/spi.ml`, `lib/eta/spi.mli`
- Root private noops: `lib/eta/runtime_capabilities.ml`
- Root private propagation subset: `lib/eta/runtime_trace_context.ml`
- Root private named instrumentation: `lib/eta/effect_instrument.ml`
- SDK Custom leaves: `lib/observability/eta_observability.ml`
- Direction proof: `.scratch/research/dx/e44/evidence/dependency-direction.txt`

## Census and completeness

- Before/after census: `.scratch/research/dx/e44/evidence/census.txt`
- Full before/after Dune graphs:
  `.scratch/research/dx/e44/evidence/dependency-before.txt` and
  `dependency-after.txt`
- Runnable stale-reference proof:
  `.scratch/research/dx/e44/evidence/stale-references.sh`
- Law registry: `.scratch/research/dx/e22/review/LAWS.md`

## Runtime and adversarial proof

- Exact gate summary: `.scratch/research/dx/e44/evidence/gates.txt`
- Superseding batch method/verdict:
  `.scratch/research/dx/e44/evidence/bench-followup-pairs/README.md`
- Superseding raw pairs/analyzer:
  `.scratch/research/dx/e44/evidence/bench-followup-pairs/`
- Historical single-point evidence:
  `.scratch/research/dx/e44/evidence/bench-parity.md`
- Red-team sources/outputs/verdicts: `.scratch/research/dx/e44/redteam/`
- Final synthesis: `.scratch/research/dx/e44/report.md`

## Weakest spot

The weakest design spot is the breadth of the unstable `Spi.Expert`
observability seam. Keeping all runtime-local keys private and preserving daemon
diagnostics requires behavioral operations for spans, context, scoped logs, and
metrics. This is directionally safer than exporting shared keys, but it leaves a
larger root-owned SPI surface whose SDK parity depends on the migrated executable
suites. Review `spi.ml` and `eta_observability.ml` side by side, especially
exception capture, dynamic-scope restoration, lazy metric admission, and the
targeted hot-path inline attributes.

The secondary evidence weakness is statistical: the exact full quick benchmark
stops in an unchanged TypeScript workload, and the focused 15-pair batch run has
material per-pair spread. Its pooled medians and deterministic allocations are
reported, but no one-sided bound is claimed. Review the raw alternating pairs
and analyzer rather than relying on the pooled table alone.
