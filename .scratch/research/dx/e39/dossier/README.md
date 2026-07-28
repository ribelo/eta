# DX-E39 decision dossier

## Endpoint coordinates

| Point | Commit |
| --- | --- |
| E39/master merge-base | `7d8e52364782cecfd4c205d7edae62b750a05803` |
| Endpoint S code | `6c51b9e305d3d1cb492bdd69f3d0784d134c0ca9` |
| Endpoint S review boundary | `f136a68df0f7dcc96e19804eabec25f1aa69b5d2` |
| Endpoint R | `82d1729779e8ac8855f2fc80a0582eda350eaf3a` |
| Endpoint S′ | `563eef245c98f175b5d722304b8cdaa15ee9957a` |

Review ranges:

```text
git diff 7d8e5236..f136a68d   # semantic master/merge-base → S
git diff f136a68d..82d17297   # S → R
git diff f136a68d..563eef24   # S → final S′ review endpoint
```

## Artifact index

- [Consumer, dependency, and honesty evidence](consumer-dependency-honesty.md)
  — decision tables pointing to the exhaustive line-level source audit.
- [Construction cost](cost.md) — protocol, raw JSON links, values, and threshold.
- [Diff statistics](diff-stats.txt) — literal and semantic endpoint ranges.
- [API/representation census and footgun delta](census-footguns.md).
- [Verification](verification.md) — snapshot bytes, dishonest probe, both gate
  sets, tracing, and law dispositions.
- [Recommendation and prediction score](recommendation.md).
- [S′ review addendum](addendum-sprime.md) — adopted findings, corrected
  consumer map, final census/diffs, proofs, and final recommendation.
- [Executor report](../report.md).

Every linked E39 artifact is committed. Raw evidence lives in `../evidence/` so
summaries can be checked without trusting rounded prose.
