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

## 3. `Mutable_ref` purity contract actuals

Both public docs now say **must be pure**, zero-to-many, CAS retry, and that
logging, sends, and external increments multiply. `docs/api-dx.md` adds one
accepted-and-mitigated footgun and removes none (+1/+0): compute only the
replacement in the callback, then perform effects after the update. Types and
implementation are unchanged, so the val census delta is zero and exactly two
vals are documentation-touched.

The multiplying-effect bug is this shape:

```ocaml
Mutable_ref.update state (fun current ->
    send audit_channel "incrementing";
    current + 1)
```

Under one forced CAS collision, two successful updates evaluate that callback
three times, so the send occurs three times for two committed increments. The
new named test `CAS retry may re-execute callbacks` constructs exactly that
barrier for both `update` and `update_and_get`, and the focused 648-test
`test/core_eio` run passed. The new law-bearing wording is registered as R177.
This evidence requirement changed four product/evidence paths rather than the
sealed prediction's two docs-only paths; it preserves the adjudicated
prose-only API/implementation outcome while satisfying the repository's
same-change executable-law policy.

OxCaml modes cannot express semantic purity. Locality, uniqueness, portability,
and contention constrain value lifetime, aliasing, and cross-domain safety, not
whether a closure logs, sends, or mutates a separately available handle. The
linearity axis is also the wrong tool: `once` promises at-most-one invocation,
while a CAS loop specifically requires a `many` callback and may invoke it
again. With no effect/purity type that rejects all observable callback actions,
an annotation would either fail to enforce the contract or reject valid pure
closures for unrelated capture reasons. The adjudicated prose contract,
reinforced by a deterministic retry witness, is therefore the precise current
choice for future re-examination.

## 4. `race` naming actuals

The executable call-site census is 120 call lines in 78 tracked `.ml`/`.mli`
files under `lib`, `test`, `examples`, and `bench`: 50 mechanically repeated
typecheck fixtures and 70 non-fixture calls. No unqualified additional call was
found. Existing teaching is consistent: `effect.mli` said the first child to
produce a value wins, `docs/concurrency-guide.md` says first child to succeed,
and `examples/README.md` explicitly says a successful branch wins even when
another branch fails earlier. The API-DX references use `race` as a concurrency
primitive without making first-settlement claims.

The surprise search found no caller comment, test, red-team note, or failure
report saying that an early typed failure was unexpectedly ignored. Instead,
named executable evidence deliberately asserts `race ignores early failure
until success`, `race simultaneous success/failure returns winner`, `race all
failures returns concurrent causes`, and `race success iff any succeeds`.
Therefore the pre-registered flip condition did **not** fire: `race` is kept and
there is no migration.

Implementation inspection at `lib/eta/effect_concurrent.ml:107-229` confirms
that each `Exit.Error` is collected while results remain; the first `Exit.Ok`
stores the winner and cancels losers, while an all-error run returns
`Cause.concurrent`. Loser finalizer diagnostics remain a separate post-winner
failure path, so the new sentence avoids the inaccurate stronger claim that
race can fail *only* when every child fails. `effect.mli` now says explicitly:
unlike JavaScript's `Promise.race`, a typed failure does not win; it is collected
while waiting for success, and all-child failure returns the causes
concurrently. Existing discriminating tests register the two added claims as
R178 and R179. Actual surface delta: zero renamed/added/removed vals and one
documentation-touched val, exactly as predicted.

# Follow-up 1 review findings

## F1 — callback cardinality

**Justified.** `Mutable_ref.update` and `update_and_get` evaluate `f old`
unconditionally before their first CAS, so every invocation runs the callback
at least once; only the upper bound is unbounded under contention. The false
“zero-to-many” phrase originated in the orchestrator's objective. I copied that
adjudicated wording in good faith, even noting in the sealed reservation that a
normal call runs at least once, but should have challenged the contradiction
against the implementation. Both mli docs and API-DX now say at-least-once,
possibly many, and R177 quotes the corrected claim.

## F2 — tier rules and complete re-derivation

**Justified; resolution (a).** `eta_stream`'s primary contract is Eta-owned
streams/mailboxes/channels/queues; `from_eio_stream` is the explicitly fenced
H-W4 bridge, not the module's organizing contract. `eta_test` primarily provides
deterministic Eta testing; its Eio switch/runtime types are native harness
plumbing. Both therefore remain Batteries under the new primary-contract rule.
An Integration is selected only when the package's primary public contract is
an external boundary. `ppx_eta_sql` is unambiguously Integration because SQL
language/protocol code generation is its primary contract.

Applying the ordered rules to every root opam package re-derives all 48 rows:

| package | derived tier | deciding primary contract |
| --- | --- | --- |
| `eta` | Core | universal backend-neutral Eta contract |
| `eta_blocking` | Batteries | Eta-owned bounded blocking machinery |
| `eta_cache` | Batteries | Eta-owned caching |
| `eta_par` | Batteries | Eta-owned native parallel machinery |
| `eta_redacted` | Batteries | Eta-owned safe value rendering |
| `eta_router` | Batteries | general path matching, not HTTP transport/protocol |
| `eta_schema` | Batteries | format-neutral schemas |
| `eta_schema_test` | Batteries | general schema test support |
| `eta_signal` | Batteries | Eta-owned reactive graphs |
| `eta_stream` | Batteries | backend-neutral stream contract; Eio is one bridge |
| `eta_test` | Batteries | Eta test contract; Eio is harness plumbing |
| `ppx_eta` | Batteries | general Eta syntax/tooling |
| `eta_ai` | Integrations | LLM service/protocol vocabulary |
| `eta_ai_anthropic` | Integrations | Anthropic service protocol |
| `eta_ai_kimi_coding` | Integrations | Kimi service/OAuth protocols |
| `eta_ai_moonshot` | Integrations | Moonshot service protocol |
| `eta_ai_openai` | Integrations | OpenAI service protocols |
| `eta_ai_openai_codec` | Integrations | OpenAI wire codecs |
| `eta_ai_openai_codex` | Integrations | Codex service/OAuth protocols |
| `eta_ai_openai_compat` | Integrations | provider service protocols |
| `eta_ai_openai_realtime_eio` | Integrations | OpenAI WebSocket/Eio boundary |
| `eta_ai_openrouter` | Integrations | OpenRouter service protocol |
| `eta_duckdb` | Integrations | DuckDB driver |
| `eta_eio` | Integrations | Eio runtime adapter |
| `eta_exa` | Integrations | Exa service client |
| `eta_http` | Integrations | HTTP protocol/client contract |
| `eta_http_eio` | Integrations | Eio HTTP transport |
| `eta_http_h1` | Integrations | HTTP/1 codec |
| `eta_http_h2` | Integrations | HTTP/2 implementation |
| `eta_http_js` | Integrations | browser Fetch adapter |
| `eta_http_service` | Integrations | HTTP server contract |
| `eta_http_service_eio` | Integrations | Eio HTTP serving adapter |
| `eta_http_tls_openssl` | Integrations | OpenSSL TLS driver |
| `eta_http_ws` | Integrations | WebSocket protocol codec |
| `eta_js` | Integrations | js_of_ocaml platform facade |
| `eta_js_stream` | Integrations | js_of_ocaml stream platform API |
| `eta_js_test` | Integrations | js_of_ocaml/Node test platform API |
| `eta_jsoo` | Integrations | js_of_ocaml runtime backend |
| `eta_ladybug` | Integrations | LadybugDB driver |
| `eta_linux_input` | Integrations | Linux evdev/uinput platform API |
| `eta_otel` | Integrations | OpenTelemetry protocol exporter |
| `eta_schema_yojson` | Integrations | Yojson codec |
| `eta_sql` | Integrations | SQLite driver/SQL surface |
| `eta_sql_driver` | Integrations | external SQL-driver contract |
| `eta_sql_dsl` | Integrations | SQL language builder |
| `eta_turso` | Integrations | Turso database driver |
| `eta_utop` | Integrations | UTop/Eio developer-runtime adapter |
| `ppx_eta_sql` | Integrations | SQL language/protocol code generation |

The two red-team attempts still resolve uniquely. `eta_eio` cannot be Core
because its primary contract is the external Eio runtime adapter, while
`eta_schema_yojson` cannot be Batteries because its primary contract is a
Yojson codec. The new bridge rule also closes the review's two counterexamples
without becoming a fallback: primary-contract ownership is the deciding test
for every row.

## F3 — stale SQL README preprocessor

**Justified.** The README had a correct `ppx_eta_sql` instruction at lines
183-189 and a second stale `(pps ppx_eta)` block later in the same section. The
second block now also says `(pps ppx_eta_sql)`, and a whole-file search finds no
remaining stale table-preprocessor instruction.

## F4 — shifted registry pointers

**Justified.** R43 pointed at the newly inserted MutableRef registration rather
than its Queue test. R43-R51 and R98 now point to the exact Queue registrations;
a full registry search found no other `core_common_suites.ml` pointer requiring
that shift. The registry header now makes whole-file pointer refresh mandatory
whenever a test is inserted mid-file. The later F5 test expansion also triggered
and received a complete refresh of every shifted `effect_common_suites.ml`
pointer, exercising that rule immediately.

## F5 — qualified race winner and error coverage

**Justified.** A value is selected first, but a cancelled loser's cleanup
diagnostic replaces it with an error. The interface now states that
qualification. It also states the implementation's actual branch rule: every
`Exit.Error` category—typed failure, defect, interruption, or finalizer
cause—loses while race waits for success. The renamed test
`race ignores every early error until success` executes all four categories.
The all-failure test now additionally checks a four-cause mixed census, so R179
keeps its broad wording honestly rather than narrowing to typed failures. R180
registers the post-winner loser-finalizer replacement path.
