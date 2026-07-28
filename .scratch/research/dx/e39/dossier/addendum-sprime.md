# Follow-up 1 addendum — Endpoint S′

Endpoint S′ is **R + `describe`**, committed at
`563eef245c98f175b5d722304b8cdaa15ee9957a`. It retains R's two-field
`Custom` and every deletion of audit, footprints, assertions, propagated names,
and `collect_names`.

## Review findings, answered

### 1. `collect_names` made S internally arbitrary

**Accepted.** At S (`f136a68d`), `race`, `par`, `par3`, `par4`, and
`all_settled` still passed aggregated `~names` at
`lib/eta/effect_concurrent.ml:210,247,280,301,319`, while `all` at `:344-351`
did not. Consequently sibling combinators had inconsistent static-name
boundaries solely because S removed the documented `all` special case while
trying to preserve `collect_names` generally.

S′ does not patch that seam. It keeps R's complete deletion:

- no public `collect_names`;
- no `Custom.names` field;
- no `Expert.make ?names`;
- no `~names` producer or `with_names` helper;
- no collect-names law or disposition restoration.

Mechanical evidence: [`../evidence/representation-sprime.md`](../evidence/representation-sprime.md).

### 2. `describe` is justified by T5, not observed demand

**Accepted and corrected.** The original dossier overstated the
teaching/external-demand case. No production consumer or dedicated public docs
section was found; the snapshot is a self-test. The governing rationale is T5:
a blueprint value remains minimally inspectable and printable.

S′ restores master's exact `describe` contract and walker. It adds no
representation field: the walker matches `Pure`, `Fail`, `Custom`, `Map`, and
`Bind`, and reads only `Custom.leaf_name`, which R already retained. The focused
constructor/opacity test proves that custom evaluators and bind continuations
are not run and that wrapper internals remain opaque.

### 3. The consumer map missed the benchmark sink

**Accepted and corrected.** At pre-deletion commit `ba1275f4`,
`bench/effect_construction/construction_sink.ml:9` called `Effect.describe` to
fingerprint a retained blueprint and prevent benchmark elision. It is benchmark
infrastructure, not production demand. The omission is now recorded as D7 in
[`../evidence/source-audit.md`](../evidence/source-audit.md) and in the dossier's
[consumer table](consumer-dependency-honesty.md). S′ restores that exact sink
implementation for BEFORE/S cross-tree benchmark comparability.

## S′ census

| Cluster | BEFORE | S | R | S′ |
| --- | --- | --- | --- | --- |
| `Custom` fields | 4: `eval`, `leaf_name`, `names`, `footprint` | 3: no footprint | 2: `eval`, `leaf_name` | **2: `eval`, `leaf_name`** |
| Public aggregate/tree introspection vals (`collect_names`, `describe`) | 2 | 2 | 0 | **1: `describe`** |
| Separate leaf-label query (`name`) | 1 | 1 | 1 | **1** |
| `Eta_test` audit assertions | 7 | 0 | 0 | **0** |
| `Expert.make` metadata-bearing signature | `?leaf_name`, `?names`, `?inherit_`, `capabilities` | `?leaf_name`, `?names` | `?leaf_name` | **`?leaf_name` only** |
| E39 aggregate/audit `Expert.make` metadata parameters (excluding `leaf_name`) | 3 | 1 | 0 | **0** |
| Explicit `~names` storage sites under `lib/` | 13 | 12 | 0 | **0** |

This matches the sealed amendment prediction exactly.

## Snapshot and representation proof

The restored corpus output is byte-identical to the committed master bytes:

```text
master e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
sprime e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
cmp=byte-identical
```

Artifacts:

- [`../evidence/snapshot-parity-sprime.txt`](../evidence/snapshot-parity-sprime.txt)
- [`../evidence/describe-sprime.txt`](../evidence/describe-sprime.txt)
- [`../evidence/representation-sprime.md`](../evidence/representation-sprime.md)

Because the exact master walker compiles and passes against the two-field R
`Custom`, the follow-up's names-dependency stop condition is not met.

## Law registry, third pass

The exact public contract at `lib/eta/effect.mli:1174-1182` is covered claim by
claim by registered external rows R166a–R166h:

- deterministic exact corpus: named Dune alias `effect-describe-snapshot`;
- no evaluation, all labels, indentation, no trailing newline, Bind shape and
  continuation opacity, and custom/wrapper opacity: Alcotest case
  `constructor tree is exact and inspection does not evaluate`.

The R disposition now says it is superseded only for `describe`. R's
`collect_names` disposition remains; CD-E22-014 remains only the pre-existing
`fn ~error_pp` debt. No audit/footprint/assertion/names claim returns.

## Gates

All mandatory S′ gates passed. Exact command/timestamp/status artifacts are in
[`../evidence/gates-sprime/`](../evidence/gates-sprime/README.md).

| Gate | Status |
| --- | ---: |
| `nix develop -c dune build @install` | 0 |
| `nix develop -c dune runtest --force` | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 |
| mainline JS targets with dedicated `_build-mainline` | 0 |

## Diff statistics

S′ coordinate: `563eef245c98f175b5d722304b8cdaa15ee9957a`.

| Range | Files | Added | Deleted | Net |
| --- | ---: | ---: | ---: | ---: |
| `f136a68d..563eef24` (requested S→S′ review range) | 44 | 773 | 290 | +483 |
| `7d8e5236..563eef24` (merge-base→S′) | 105 | 2,075 | 1,169 | +906 |
| `82d17297..563eef24` (R→S′ provenance, including intervening dossier/seal) | 26 | 730 | 12 | +718 |

Product/test/docs/examples/bench subsets are respectively 19 files +70/-210,
65 files +290/-971, and 7 files +159/-4. Reproduction commands are committed in
[`diff-stats.txt`](diff-stats.txt).

## Amendment prediction score

The appended `Amendment predictions (sealed)` section was committed as
`36d39c85` before restore code.

| Prediction cluster | Result | Score |
| --- | --- | --- |
| Exact snapshot hash and byte parity; no names dependency | exact hash/cmp; two-field build passes | **hit** |
| Restore only deterministic `describe` law coverage; keep collect-names removal and `fn` debt | R166a–h active; dispositions/debt exact | **hit** |
| Two-field `Custom`; one introspection val; zero assertions/names sites; `Expert.make ?leaf_name` only | census above | **hit** |

Amendment subtotal: **3 hits, 0 partials, 0 misses**.

## Final recommendation

**Promote S′.** It removes S's arbitrary and allocation-bearing static-name
mechanism, preserves R's smallest effect representation, and restores only the
honest operation needed by T5. `describe` adds a function and public contract,
not metadata to each blueprint node. Snapshot parity, constructor/opacity
coverage, and all four mandatory gates make that boundary executable.
