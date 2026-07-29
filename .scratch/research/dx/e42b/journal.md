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
