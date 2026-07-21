# Follow-up 1: DX-E20b — the representation fix (Keep | Drop | Replace)

Your self-rejection was verified and upheld: the ~10.49 minor words/record
identity-path allocation is real (orchestrator reproduced it bit-for-bit),
and the `option` representation makes it unfixable. The experiment is NOT
killed — behavior is proven and the metric use case is compelling. The
orchestrator held E20 and sealed E20b on this branch: **change only the
transform representation so identity is allocation-free by construction.**

Everything in `objective.md` still applies except where this file
overrides it.

## The redesign (contract)

```ocaml
type 'a Effect.intercept = Keep | Drop | Replace of 'a

val intercept_log :
  (Capabilities.log_record -> Capabilities.log_record Effect.intercept) ->
  ('a, 'err) t -> ('a, 'err) t
val intercept_metric :
  (Capabilities.metric_point -> Capabilities.metric_point Effect.intercept) ->
  ('a, 'err) t -> ('a, 'err) t
```

`Keep` = pass unchanged (immediate, no boxing). `Drop` = the old `None`
(immediate, short-circuits). `Replace r` = substitute (allocates only when
the record actually changes). The exact type/constructor names are yours
to settle in the docs-first step within this sketch — the review will
judge them; whatever you choose, identity must be allocation-free.

## What changes, what carries

- **Carries unchanged in substance:** the whole behavioral suite from E20
  (pipeline order, drop semantics, shorthand parity, `with_logger`
  interplay both orders, redaction, metric enrichment, raising-transform
  defect capture, jsoo parity) — update only for the new representation.
- **Changes:** the transform type, both signatures, the emission walker
  (it must not box or cons per record on the `Keep` path), all docs that
  said `option`/`None`, the review packet snippets, the bench row's
  identity callback.
- **Journal:** add an `E20b predictions (sealed)` section as a NEW entry
  before your first code commit. Do not edit E20's sealed predictions.

## The gate (pre-registered, orchestrator-sealed)

- `Keep`-identity intercept: **zero minor-word increment** on the
  watchlist denominator pair
  (`overhead.eta.log.100k.{no_intercept,identity_intercept}` — same
  harness, updated to the variant). If irreducible walker overhead exists,
  report it raw — do not tune the number toward the bar; the gate
  re-evaluates, but the sealed bar is zero.
- `Replace` allocates only the variant block (≤ 3 words/record).
- Wall time: no regression (identity ≤ baseline within noise).
- Behavior: the carried suite passes; parity with E20's proven semantics.

## Protocol

Same as objective.md steps 1–8 adjusted: docs-first on the new type/docs;
the same four gates; red-team updated (the two E20 probes re-run against
the variant); review packet updated (redact/metric pairs now with
`Keep`/`Drop`/`Replace` spellings, plus one snippet whose only job is
readability of the three constructors); report updated with a section
scoring BOTH prediction sets (E20's original and E20b's amendment) and
your promote/hold/kill recommendation — metric half's fate argued
separately as before.

## Done means

`E20b READY FOR REVIEW` / `E20b BLOCKED: <reason>` /
`E20b STOP: <§4.6 condition>`. Same scope fence as objective.md. This file
stays uncommitted, like objective.md.
