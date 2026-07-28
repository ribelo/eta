# Consumer, dependency, and honesty evidence

The exhaustive, file-by-file source artifact is
[`../evidence/source-audit.md`](../evidence/source-audit.md). It records the
search roots and exclusions, every consumer with source location, the complete
producer/reader dependency map, verbatim public claims, and the tracing stop
check. This dossier page is its decision table, not a replacement for it.

## Consumer map

| Surface | Self-test | Boundary | Documentation | In-repository real production/runtime consumer | Structural need found |
| --- | --- | --- | --- | ---: | --- |
| `Effect.audit` | dominant; audit algebra and red-team tests | one raw-audit `eta_blocking` footprint check | MLI/research | **0** | none beyond static test contracts |
| `Effect.describe` | snapshot, audit failure text, and construction-benchmark anti-elision | 0 | MLI/research | **0** | T5's minimal deterministic, non-evaluating printable-blueprint surface; not observed demand |
| `Effect.collect_names` | two name-order tests and API-DX example harness | 0 | public DX preflight guidance | **0** | statically present-name preflight/documentation, explicitly incomplete |
| seven `Eta_test` assertions | one positive-path helper test | **0** | MLI/research | **0** | none; `blocking_common` used raw `audit`, not an assertion |

Primary evidence: source audit §§1.1–1.5. The census found **seven**, not the
objective's stated four, public assertion values; all seven were removed.
In-repository zero use was not treated as proof by itself. Follow-up review
corrected the original census: `bench/effect_construction/construction_sink.ml`
also called `describe` as anti-elision infrastructure. It does not establish
application demand. The structural case for `describe` is T5's printability
principle, not consumer frequency; no application/runtime use was found in the
searched repository. The census cannot establish absence among external
consumers.

## Dependency map and stop check

Before deletion, `Custom` stored `eval`, `leaf_name`, a propagated `names` list,
and a six-boolean `footprint`. Evaluation matched `Custom { eval; _ }` and read
neither metadata aggregate. `audit` was the sole public semantic reader of the
footprint; tests and assertions read it through `audit`.

Runtime tracing did **not** read `Custom.names`. `Effect.named` captured its
ordinary `name` argument in the evaluator closure and passed that value directly
to `Runtime_instrument.with_span ~name`. Endpoint R's executable tracing
witness is [`../evidence/tracing-r.md`](../evidence/tracing-r.md). The objective's
names/tracing stop condition was therefore not met.

The documented `all` special case aggregated every prebuilt child's names and
footprints at construction, unlike `map_par`. S removed both footprint machinery
and this `all` names aggregation while retaining the general `collect_names`
surface. R removed the remaining propagated names mechanism.

Primary evidence: source audit §§2.1–2.5.

## Honesty audit

| Claim | What its own contract conceded | Footgun assessment before deletion |
| --- | --- | --- |
| `audit` flags | static spine only; `true` may over-report; `false` cannot exclude bind/sync/custom work | quasi-effect-row with both false positives and false negatives |
| `assert_pure_eff` / `assert_no_*` | inherited static-only limits | names suggested assurance stronger than the admitted evidence; `pure` was strongest |
| `Expert.make ~capabilities` | author declaration was unverifiable and could omit behavior | writable false declaration |
| `collect_names` | continuations are not forced; not a runtime inventory | honest but incomplete preflight list |
| `describe` | opaque custom nodes stay leaves; bind continuation unforced | honest deterministic static tree, not runtime behavior |

The complete quoted contracts and hedges are in source audit §3. S removes the
first three rows. R also removes the last two public aggregate/tree surfaces;
S′ restores only `describe` while retaining R's `collect_names` deletion.
