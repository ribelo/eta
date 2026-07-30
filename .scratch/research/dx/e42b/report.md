# DX-E42b report — hygiene batch

Evidence is compared with the sealed, unedited prediction section in
[`journal.md`](journal.md) at commit `2354e551`.

## Result

All four items reached their adjudicated shape:

1. SQL table syntax moved from `ppx_eta` to the new `ppx_eta_sql` package while
   retaining the public extension name `eta.sql.table`.
2. The package map assigns all 48 public packages exactly once under four
   precedence-bearing support-tier rules.
3. `Mutable_ref.update` and `update_and_get` now state their pure, retryable
   callback contract and API-DX records the accepted footgun.
4. The `race` flip condition did not fire; the name remains and its interface
   now states the divergence from JavaScript `Promise.race`.

## Final gates

All four exact gates passed on the final implementation tree on their first
attempt:

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo` | PASS |

Focused pre-gate evidence also passed: all 11 shared PPX/SQL-table tests, the
OxCaml type-error snapshot suite, and all 648 core Eio tests including the new
forced CAS-retry witness.

## 1. `ppx_sql` split

### Evidence and actuals

- `lib/ppx/ppx_eta.ml` contains no `sql`, `Eta_sql`, or `eta.sql` reference. It
  registers only `eta.fn`, `eta.sync`, and `eta.result`, and retains the
  `eta_error` deriver.
- `lib/ppx_sql/ppx_eta_sql.ml` registers only `eta.sql.table`; its Dune library
  is `(kind ppx_rewriter)` with only `ppxlib` as a library dependency.
- `dune-project` and root opam census both moved from 47 to 48 packages. Public
  name, package, and generated module line up as `ppx_eta_sql` / `ppx_eta_sql` /
  `Ppx_eta_sql`.
- The shared PPX suite now preprocesses with both rewriters. The hand-written
  type-error driver selects `ppx_eta_sql` for all six `sql_*` cases and
  `ppx_eta` for the remaining PPX cases.
- `test/type_errors/expected_compile.txt` is byte-stable: the focused snapshot
  gate passed with no diff, so no transformation name leaked into rejection
  output.
- `CHANGELOG.md`, `README.md`, and `lib/sql/README.md` document the package move
  without renaming `eta.sql.table`.

The consumer census found no PPX stanza or extension use in `test/sql_common`
or `test/connectors_loader`; there was nothing to migrate in those directories.
The indirect/shared and hand-written driver consumers were migrated instead.

### Prediction score and verdict

| sealed prediction | actual | score |
| --- | --- | --- |
| 47 → 48 packages; `ppx_eta` 4 → 3 rules; new SQL rewriter has 1 rule | exact | **HIT** |
| 10–16 item paths | 13 including its journal record | **HIT** |
| six SQL rejection snapshots remain byte-stable | no snapshot diff | **HIT** |
| promote strict split with unchanged extension name | exact | **HIT** |
| reservation: miss an indirect or hand-written consumer | explicit source/preprocessor census found and split the hand-written driver | **HIT** |

Verdict: the package split is complete, dependency-minimal, and user syntax is
stable.

## 2. Docs-level tiering

### Evidence and actuals

`docs/packages.md` defines ordered rules: explicit labs designation, universal
backend-neutral core, external-boundary integrations, then general-purpose
batteries. A mechanical comparison against root opam files reports 48 rows, 48
unique names, no missing package, no extra package, and no duplicate. Counts are
core 1, batteries 11, integrations 36, labs 0. The empty labs tier is explicit:
no package had evidence of an unstable/experimental contract, so the map does
not invent one.

The lightweight red team attempted two misclassifications:

- `eta_eio` as core fails because core must be backend-neutral and universal;
  its named Eio runtime boundary selects integrations.
- `eta_schema_yojson` as batteries fails because the codec rule takes
  precedence and selects integrations.

The same rules settle `ppx_eta_sql` versus `ppx_eta` and preserve `eta_test` as
general-purpose testing support. `README.md` already contained the required
public link, so its wording needed no tier-item change.

### Prediction score and verdict

| sealed prediction | actual | score |
| --- | --- | --- |
| exhaustive 48-row map | 48/48, exact and disjoint | **HIT** |
| one product-doc path because README already links it | only `docs/packages.md` | **HIT** |
| external boundary and explicit labs precedence make tiers derivable | rules resolve every row; labs is explicitly empty | **HIT** |
| reservation: backend adapters fit both core/batteries and integrations | `eta_eio` red team has one rule-derived answer | **HIT** |

Verdict: the production circumference is publicly visible without moving any
package or letting usage frequency redefine core.

## 3. `Mutable_ref` purity contract

### Evidence and actuals

Both public val docs say the callback **must be pure**, must be safe to run
zero-to-many times, may be evaluated again after CAS failure, and multiplies
logging, sends, and external increments when effectful. No type or
implementation changed. `docs/api-dx.md` adds one accepted-and-mitigated
footgun: compute only the replacement in the callback and perform effects after
the update.

The red-team bug puts a send inside the callback. The named test
`CAS retry may re-execute callbacks` forces two domains to compute from the same
old value. For both `update` and `update_and_get`, exactly two updates commit
after exactly three callback evaluations. This distinguishes callback effects
from committed state changes and registers the new claims as R177.

OxCaml locality, uniqueness, portability, and contention modes do not express
semantic purity. `once` is specifically incompatible with a retrying CAS loop,
which needs a `many` callback. Prose is therefore the current enforceable
boundary rather than a misleading mode annotation.

### Prediction score and verdict

| sealed prediction | actual | score |
| --- | --- | --- |
| two vals documentation-touched; zero type/value-count change | exact | **HIT** |
| footgun delta +1 documented / +0 removed | exact | **HIT** |
| exactly two product paths | four product/evidence paths: mli, API-DX, named test, law registry | **MISS** |
| promote the loud pure/zero-to-many/CAS/effect-multiplication wording | exact | **HIT** |
| reservation: explain surprising zero-to-many cardinality and CAS reason | both docs state the cardinality and retry mechanism | **HIT** |

The path deviation is required by the repository's prospective executable-law
policy; it does not alter the adjudicated prose-only API or implementation.
Verdict: the callback hazard is explicit and has a discriminating witness.

## 4. `race` naming

### Evidence and actuals

The executable census finds 120 call lines in 78 tracked `.ml`/`.mli` files
under `lib`, `test`, `examples`, and `bench`: 50 generated typecheck fixtures
and 70 non-fixture calls. No additional unqualified call was found.

Teaching and tests consistently describe first-success behavior:

- `effect.mli`: first child to produce a value;
- `docs/concurrency-guide.md`: first child to succeed;
- `examples/README.md`: success wins even when another branch fails earlier;
- named tests: early failure is ignored until success, simultaneous
  success/failure returns the winner, all failures return concurrent causes,
  and race succeeds iff any child succeeds.

No caller comment, test, or red-team note records surprise at failure not
winning. Implementation inspection confirms errors are collected until the
first success, and an all-error run returns `Cause.concurrent`. Loser finalizer
diagnostics remain a distinct post-winner failure path. The pre-registered flip
condition therefore did not fire: `race` remains, with an explicit
`Promise.race` divergence sentence. R178 and R179 register the two clarified
claims to existing discriminating tests.

### Prediction score and verdict

| sealed prediction | actual | score |
| --- | --- | --- |
| 120 call lines, 50 fixtures and 70 non-fixtures | exact | **HIT** |
| keep `race`; add one JS-divergence sentence | exact | **HIT** |
| zero val rename and one documentation-touched val | exact | **HIT** |
| reservation: familiar JS name still invites first-settlement reading | interface now names `Promise.race` and the all-fail consequence | **HIT** |

Verdict: evidence supports retaining the short established name while making
the semantic difference impossible to miss at the interface.

## Mechanical census

| surface | before | after | delta |
| --- | ---: | ---: | ---: |
| public packages (`dune-project` and root opam files) | 47 | 48 | +1 |
| `ppx_eta` extension rules | 4 | 3 | -1 |
| `ppx_eta_sql` extension rules | 0 | 1 | +1 |
| total PPX extension rules | 4 | 4 | 0 |
| `eta_error` derivers in `ppx_eta` | 1 | 1 | 0 |
| tier rows / unique packages | 0 / 0 | 48 / 48 | +48 / +48 |
| `Mutable_ref` vals documentation-touched | 0 | 2 | +2 |
| `Effect.race` vals documentation-touched | 0 | 1 | +1 |
| public val additions/removals/type changes | 0 | 0 | 0 |
| documented footguns added / removed | 0 / 0 | 1 / 0 | +1 / +0 |
| registered external law clusters | 179 | 182 | +3 |
| covered registry rows | 295 | 298 | +3 |

Type-error snapshot stability: **PASS, byte-stable**. Race call-site count:
**120**. Overall sealed-prediction score: **14 HIT, 1 MISS**.

The final implementation, evidence, and report change 20 paths, with 1,116
additions and 550 deletions (1,666 line events). Registry source-pointer refresh
after the four-line `race` doc insertion accounts for 342 of those line events.

## Deviations

1. The branch arrived with an orchestrator predictions commit in the
   scope-fenced global DX journal. It was not read or edited. The required local
   E42b journal was sealed independently before implementation.
2. `test/sql_common` and `test/connectors_loader` were named as expected PPX
   consumers but contain neither a preprocessing stanza nor the SQL extension;
   no no-op dependency was added.
3. Mutable_ref needed a named test and registry row beyond the predicted two
   product docs because changed law-bearing mli prose cannot rely on historical
   coverage debt.
4. The first focused PPX command named a nonexistent `test/ppx_eio/runtest`
   target. The corrected focused `dune runtest test/ppx_eio test/type_errors
   --force` passed; this was not a required-gate failure class. All exact final
   gates passed first attempt.

## Recommendations

- **PPX split — PROMOTE:** package ownership, dependencies, consumers, docs, and snapshots agree.
- **Package tiers — PROMOTE:** all 48 packages are classified by reproducible precedence rules.
- **Mutable_ref purity — PROMOTE:** the accepted footgun is loud, mitigated, and executable evidence proves multiplication.
- **Race naming — PROMOTE:** retain `race`; no surprise evidence met the rename condition, and the JS divergence is explicit.

## Follow-up 1 outcome

All five independent-review findings were justified and fixed. The original PPX
split remained unchanged and upheld.

1. **Mutable_ref cardinality:** the earlier “zero-to-many” wording is superseded
   by “at least once, possibly many times” in both mli docs and API-DX. The false
   phrase originated in the orchestrator objective and was copied in good faith;
   implementation inspection shows `f old` always precedes the first CAS. R177
   now states the corrected claim.
2. **Tier derivability:** the rules now classify by the package's primary public
   contract. Incidental bridge/native-harness types do not turn Eta-owned
   general functionality into an Integration. `eta_stream` and `eta_test` retain
   Batteries with explicit Eio bridge notes; `ppx_eta_sql` is Integration because
   SQL language/protocol generation is its primary contract. The journal
   re-derives all 48 packages, and the `eta_eio`/`eta_schema_yojson` red-team
   attempts still have one answer.
3. **SQL README:** both table-extension preprocess examples now use
   `(pps ppx_eta_sql)`; no stale `(pps ppx_eta)` table instruction remains.
4. **Registry pointers:** R43-R51 and R98 now point to their actual Queue test
   registrations. The registry header requires a whole-file pointer refresh
   after mid-file insertions; all pointers shifted by the expanded race tests and
   race mli wording were refreshed in the same follow-up.
5. **Race qualification:** the interface now distinguishes selection from final
   return: a cancelled-loser finalizer diagnostic replaces the selected value
   with an error. The named early-error test covers typed failure, defect,
   interruption, and finalizer causes losing to success. The all-failure test
   retains all four mixed causes, so broad R179 is now discriminated; new R180
   registers the post-winner cleanup-diagnostic path.

The law registry is amended to **183 registered external clusters** and **299
covered rows**. The focused `test/core_eio` suite passed all 648 cases before the
full gates.

All four required follow-up gates passed on the final implementation and test
tree, each on its first attempt:

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo` | PASS |

Follow-up recommendation for every item: **PROMOTE**. The review blockers are
closed without changing package ownership, public extension spelling, public
types, or the retained `race` name.
