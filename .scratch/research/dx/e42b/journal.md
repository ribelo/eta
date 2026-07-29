# DX-E42b sealed predictions

These predictions were written before any E42b implementation or contract edit.
This section is immutable after the predictions commit.

## 1. `ppx_sql` split

- **Expected census/path delta:** public packages rise from 47 to 48. The
  `ppx_eta` transformation falls from four extension rules to three (`fn`,
  `sync`, `result`) while retaining the `eta_error` deriver; the new
  `ppx_eta_sql` transformation owns exactly one rule, `eta.sql.table`. I expect
  10-16 implementation/plumbing/consumer/changelog paths to change, three of
  them new (`lib/ppx_sql/ppx_eta_sql.ml`, `lib/ppx_sql/dune`, and generated
  `ppx_eta_sql.opam`). The six SQL rejection snapshots should be byte-stable.
- **Expected verdict shape:** promote a strict package split with no SQL
  dependency in either rewriter and no user-facing extension rename.
- **Likeliest review reservation:** the split driver may be omitted from an
  indirect shared-test or hand-written type-error invocation even when direct
  Dune PPX consumers build.

## 2. Docs-level tiering

- **Expected census/path delta:** `docs/packages.md` adds a 48-row exhaustive,
  disjoint map after the PPX split. `README.md` already contains the intended
  link, so I expect one product-doc path rather than changing link wording.
  Likely ties are runtime/platform packages such as `eta_eio` and developer
  helpers such as `eta_test`; dependency on an external runtime/protocol breaks
  the former toward integrations, while test/developer-only purpose breaks the
  latter toward batteries unless explicitly unstable.
- **Expected verdict shape:** promote four precedence-bearing rules that classify
  all packages mechanically, with labs taking precedence for explicitly unstable
  surfaces and integrations taking precedence over general-purpose utility when
  an external protocol/service/driver/codec/platform is involved.
- **Likeliest review reservation:** “batteries” and “integrations” can overlap for
  backend adapters unless the external-boundary precedence is explicit.

## 3. `Mutable_ref` purity contract

- **Expected census/path delta:** two existing public vals are documentation-
  touched with zero type/value-count change; `docs/api-dx.md` gains one accepted-
  and-mitigated footgun, for a footgun delta of +1 documented / +0 removed. I
  expect exactly two product paths to change.
- **Expected verdict shape:** promote loud prose saying the callback must be pure,
  may execute zero-to-many times because CAS retries, and duplicates effects such
  as logging, sends, and increments when impure; retain both types unchanged.
- **Likeliest review reservation:** “zero-to-many” may look surprising for a call
  that normally evaluates at least once, so the wording must distinguish the
  callback contract from successful call completion and state the CAS reason.

## 4. `race` naming

- **Expected census/path delta:** the baseline search finds 120 executable
  `Effect.race`/backend-alias call lines across `lib`, `test`, `examples`, and
  `bench`; 50 are generated typecheck fixtures, leaving 70 non-fixture lines.
  I expect no val rename and one documentation-touched val in `effect.mli`.
- **Expected verdict shape:** keep `race`: tests explicitly named “ignores early
  failure until success”, “first success”, and the success invariant teach the
  divergence as intentional behavior rather than caller surprise. Add the
  explicit `Promise.race` contrast and verified all-fail consequence.
- **Likeliest review reservation:** the familiar JavaScript name still invites a
  first-settlement reading despite current concurrency-guide/example wording;
  the interface sentence must be unmistakable and match composite-cause behavior.

# Execution record

## 1. `ppx_sql` split actuals

The package census is 47 → 48 in both `dune-project` and root opam files.
`ppx_eta.ml` contains no `sql`, `Eta_sql`, or `eta.sql` reference and registers
only `fn`, `sync`, and `result`; `ppx_eta_sql.ml` registers only
`eta.sql.table`. Both Dune libraries depend only on `ppxlib`. The only
SQL-extension preprocessing consumer found by source census is the shared PPX
suite, which now loads both rewriters. The six SQL type-error cases now select
the `ppx_eta_sql` executable explicitly; their focused OxCaml snapshot test
passed with no change to `expected_compile.txt`. `test/sql_common` and
`test/connectors_loader` contain no PPX preprocessing stanza or SQL extension
use, so there was no consumer entry to migrate there. Product implementation,
plumbing, consumer, and package-move documentation touched 12 paths; this
journal makes 13 for the item, within the sealed band. The focused
`test/ppx_eio` suite also passed all 11 tests. The reservation was addressed by
a repo-wide extension/preprocessor census plus the hand-written type-error
driver split, rather than direct Dune consumers alone.

## 2. Docs-level tiering actuals

The public-package census compares the support-tier table mechanically against
the 48 root opam files: 48 rows, 48 unique names, no missing names, no extras,
and no duplicates. Counts are core 1, batteries 11, integrations 36, labs 0.
The tier rules are ordered so labs requires an explicit instability designation,
core requires universal backend-neutral use, an external boundary then wins
integrations, and batteries is the general-purpose remainder. The pre-existing
README link already points to this map, so only `docs/packages.md` changed.

Tie record and lightweight red team: `eta_eio` can be argued core because an
ordinary native program needs a runtime, but the universal/backend-neutral core
rule rejects it and its named Eio runtime boundary selects integrations.
`eta_schema_yojson` can be argued batteries because it extends a general schema
library, but the external-codec rule selects integrations. The same precedence
settles the less obvious `ppx_eta_sql` (SQL-specific integration) versus
`ppx_eta` (general Eta tooling), while `eta_test` remains batteries because its
purpose is general Eta testing rather than implementing a service or protocol.
No package had existing evidence of an explicit unstable/experimental promise,
so inventing labs membership would have been a vibes-based stability downgrade;
the map records the tier as intentionally empty. The two attempted
misclassifications therefore have only one answer under the published rules.
