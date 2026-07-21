# DX-E20 review packet

| Artifact | Review purpose |
| --- | --- |
| `redact-old.ml` | Strong baseline: a delegating logger that scrubs attributes |
| `redact-new.ml` | Inline `intercept_log` scrub independent of sink selection |
| `metric-old.ml` | Strong baseline: a delegating meter installed at runtime construction |
| `metric-new.ml` | Lexical per-subtree tenant enrichment with `intercept_metric` |
| `intercept-results.ml` | Readability probe for `Keep`, `Drop`, and `Replace` |
| `QUESTIONS.md` | Teach-back questions and reviewer key |

The old examples are intentionally competent object wrappers, not strawmen.
Review the metric pair separately: the log half does not depend on retaining the
metric half.
