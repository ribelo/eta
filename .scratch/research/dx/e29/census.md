# DX-E29 Frequency Census — nested `Effect.par`

Completed before the A/B/C decision, per the E28 census method
(`.scratch/research/dx/e28/census.md`).

## Scope and exclusions

Compiled OCaml call sites under exactly `lib/`, `test/`, `examples/`,
`bench/`, `drivers/`, and `http-testsuite/`. Excluded: API definitions
(`lib/eta/effect_concurrent.ml`, `lib/eta/effect.ml`, `effect.mli`),
comments, documentation prose, and snippet strings in
`test/api_dx/api_dx_examples.ml` that are asserted as text, not compiled as
the call shown (four `Effect.par` occurrences inside `{|...|}` blocks and
six inside assertion-message strings).

Spellings covered: `Effect.par`, `Eta.Effect.par`, `Eta_js.Effect.par`, and
the local `E.par` alias. There is no `Syntax` spelling of `par`:
`lib/eta/syntax.mli` only doc-references `Effect.par` (E9b made `and*`
sequential and redirects concurrency to `Effect.par`).

## Search forms

- same-line `par (par` (with optional module qualification);
- multiline `par ( ... par` via PCRE2 dotall paragraph sweep;
- second-argument nests (two `par` call expressions on one line or within
  one paragraph, reviewed manually);
- pipeline nests `|> Effect.par` and `@@ Effect.par` — **none found**;
- partial application / bare-value `par` (`= Effect.par`, `(Effect.par)`) —
  **none found**;
- data-flow nesting (a variable bound to a `par` result passed to another
  `par`) — manual inspection of every multi-`par` file, **none found**;
- `par` fan-out of 4+ — **none found**; maximum observed fan-out is 3.

## Results

### Nested `par` sites (the pain the sugar treats)

Orchestrator's count to verify: **2 sites, one test file.**

Actual: **3 sites, two test files.** The orchestrator undercounted by one:
it missed the right-nested second-argument form at
`test/laws/law_properties.ml:463`.

| # | Site | Shape | Pattern match / use |
|---|---|---|---|
| 1 | `test/core_common/promise_shared.ml:123` | `Effect.par (Effect.par cancelled_waiter live_waiter) controller` | `let* (((), live), won) = ...` — nested-pair pattern |
| 2 | `test/core_common/promise_shared.ml:219` | `Effect.par (Effect.par typed_waiter defect_waiter) controller` | `let+ (typed_observed, defect_observed), (typed_won, defect_won, defect_exit) = ...` — nested-pair pattern over a 2-vs-3 grouping |
| 3 | `test/laws/law_properties.ml:463` | `E.discard (E.par left (E.par right pending))` | results discarded; cleanup-order law |

All three are runtime/test-author infrastructure (promise-resolution
interleavings; a qcheck fail-fast cleanup law), not consumer-shaped
"three fetches concurrently" code. Of the three, only site 1 is a natural
flat-triple shape; site 2's nesting is a semantically meaningful grouping
(two waiters against a controller triple); site 3 discards results.

### Context: flat `par` call expressions

143 compiled `par` call expressions at 140 sites. By tree:

| Tree | Call expressions | Notes |
|---|---:|---|
| `test/` | 88 | includes the 3 nested sites above |
| `bench/` | 53 | 50 are the generated `deep_bind` fixtures (one repeated workload pattern, as in E28); 3 real |
| `lib/` | 2 | both in `lib/eta/bench/bench_eta.ml` |
| `examples/` | 1 | `background_lifecycle.ml:36` |
| `drivers/` | 0 | — |
| `http-testsuite/` | 0 | — |

Nesting rate: 3 nested sites / 140 sites ≈ 2.1%.

## Interpretation (straight)

**The pain is not demonstrated in-repo.** Three nested sites in two test
files, all test-harness machinery; one discards results, one has meaningful
grouping; effectively one plausible flat-triple use. Nothing in `lib/`
product code, `examples/`, `drivers/`, or `http-testsuite/` nests `par`.
No form hunt (spacing, pipeline, partial application, Syntax, data-flow)
surfaced anything the count missed beyond the one right-nested law site.

**What an in-repo census cannot prove for a library.** Eta is consumed by
external consumers; this corpus is the runtime authors' own test/bench
usage, not representative consumer code. E9b made `Effect.par` THE user
spelling for concurrent products, so every downstream consumer with three
or more heterogeneous concurrent fetches is structurally forced into
nested tuples (`((a, b), c)`) or a flattening `map`. The in-repo census
can only reject "demonstrated in-repo pain"; it cannot measure
consumer-side ergonomic pain. The case for the sugar is therefore purely
structural — exactly the shape the objective anticipated — and the
pre-registered review gate, not this census, is where promote-vs-kill is
decided.
