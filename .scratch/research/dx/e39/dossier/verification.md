# Endpoint verification artifacts

> S′ parity, representation, law, and gate artifacts are indexed in
> [`addendum-sprime.md`](addendum-sprime.md). The sections below preserve the
> original S/R verification record.

## Snapshot parity (BEFORE ↔ S)

[`../evidence/snapshot-parity-s.txt`](../evidence/snapshot-parity-s.txt) records:

```text
master e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
slim   e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
cmp=byte-identical
```

The compared bytes are committed as `describe-master.txt` and
`describe-slim.txt`.

## Dishonesty probe (BEFORE → S)

- [`../evidence/dishonesty-master.txt`](../evidence/dishonesty-master.txt): a
  committed `Expert.make ~capabilities:[]` leaf reports
  `uses_clock=false` while executing one sleep.
- [`../evidence/dishonesty-s-compile.txt`](../evidence/dishonesty-s-compile.txt):
  the same source is rejected because `~capabilities` no longer exists.

The probe source existed at pre-deletion commit `ba1275f4` and was deliberately
deleted with the obsolete API at S; the two committed outputs preserve both
sides.

## Mandatory gates

All four mandatory gates passed on both endpoint trees. Exact commands,
timestamps, and statuses are committed under:

- [`../evidence/gates-s/`](../evidence/gates-s/README.md)
- [`../evidence/gates-r/`](../evidence/gates-r/README.md)

| Gate | S | R |
| --- | ---: | ---: |
| `nix develop -c dune build @install` | 0 | 0 |
| `nix develop -c dune runtest --force` | 0 | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 | 0 |
| mainline JS targets with dedicated `_build-mainline` | 0 | 0 |

R's full suites include the named-span, span-kind, and `fn` location witnesses;
see [`../evidence/tracing-r.md`](../evidence/tracing-r.md).

## Law registry

The census-complete registry records explicit removal dispositions at
`.scratch/research/dx/e22/review/LAWS.md:345-351`: S dispositions for R61,
R93 audit, R130, CD-E22-001, and CD-E22-018 capability prose; R dispositions
for R93 `collect_names` and CD-E22-014 introspection prose. Surviving `fn` rows
remain registered.
