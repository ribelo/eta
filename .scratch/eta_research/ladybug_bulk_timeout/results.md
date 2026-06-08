# Results

Status: implemented.

## Evidence Commands

Batch parameter probe:

    nix develop -c dune exec ./scratch/eta_research/ladybug_bulk_timeout/p0_batch_params.exe

Observed:

    ladybug_available=true
    rows=1000
    per_row.count=1000
    per_row.ms=125.474
    row_dot.status=pass
    row_dot.count=1000
    row_dot.ms=26.812
    row_dot.speedup_vs_per_row=4.68
    row_subscript.status=fail
    row_set.status=fail

Direct connection timeout probe:

    nix develop -c dune exec ./scratch/eta_research/ladybug_bulk_timeout/p1_connection_timeout.exe

Observed:

    ladybug_available=true
    timeout_ms=100
    elapsed_ms=100.494
    connection_reusable=true
    result=timeout

Focused production tests:

    nix develop -c _build/default/test/connectors/test_connectors.exe test ladybug 5,6 --show-errors

Observed:

    [OK] ladybug 5 typed query runtime
    [OK] ladybug 6 connection query timeout

Repository gate:

    nix develop -c dune runtest --force

Observed exit code: 1. The failing test is the pre-existing
test/connectors ladybug extension helpers assertion:

    FAIL uninstalled official extension loaded

The new ladybug typed query runtime and connection query timeout tests pass in
the same connector executable.

## Cross-Tab

| Criterion | Per-row exec | Param.rows with UNWIND | Generic copy_from |
| --- | --- | --- | --- |
| Correctness | Proven before this lab | Proven for 1000 heterogenous rows | Untested |
| Runtime cost | 125.474 ms for 1000 rows | 26.812 ms for 1000 rows | Unknown |
| Public API size | No change | Value.Struct, Param.struct_, Param.rows | Larger connection-level loader API |
| Cypher ownership | App-owned | App-owned | Eta would need to own labels/properties or file format |
| Native C support | Existing query API | Existing query API plus lbug_value_create_struct | No public C appender/COPY API found in the audited header |
| Status | Dominated | Accepted | Deferred |

| Criterion | Pool-only timeout | Direct *_with_timeout helpers | Synchronous ?timeout |
| --- | --- | --- | --- |
| Typed timeout | Proven through Pool | Proven through direct Connection helper | Not expressible in same result type |
| Interrupt ownership | Eta-owned only through Pool | Eta-owned for direct connections too | Would require hidden effect/runtime ownership |
| Connection reuse after timeout | Proven in prior Pool-style probe | Proven in p1 and connector test | Untested |
| Status | Dominated for direct users | Accepted | Rejected by type shape |

## Decision Diary

V-Lbug-Bulk-1 - Add row-batch parameters.
Status: ACCEPT.
Decision: Add Value.Struct, Param.struct_, and Param.rows to eta_ladybug. Param.rows renders a list of heterogenous struct values so callers can use explicit Cypher such as UNWIND $rows AS row CREATE (... row.id ...).
Evidence: p0_batch_params inserted 1000 rows with Param.rows and dot projection. It was 4.68x faster than one prepared CREATE per row in the local fixture. The focused connector runtime test inserts two heterogenous rows with int/string/bool fields and reads the count back.
Counterevidence considered: row['id'] projection fails because LadybugDB treats that as LIST_EXTRACT on ANY, and CREATE followed by SET fails for primary-key-required node creation. The accepted recipe is dot projection inside the CREATE map.
Remaining uncertainty: The measurement is 1000 rows in memory, not a full vault reindex. If full reindex remains too slow, the next evidence must compare larger chunks and look for a public native COPY/appender API in a newer LadybugDB C API.
Recommendation for production: Use Param.rows in chunked UNWIND writes. Keep graph labels, property names, and conflict semantics in app-owned Cypher for now.
Confidence: Medium.
Would change if: Large-vault indexing shows Param.rows is still too slow, or LadybugDB exposes a stable public bulk-load C API.

V-Lbug-Bulk-2 - Defer Connection.copy_from.
Status: DEFERRED.
Decision: Do not add Connection.copy_from or a generic graph bulk loader now.
Evidence: The accepted Param.rows path solves the immediate batch-parameter gap with a small API. The audited C header exposes lbug_value_create_struct and query execution, but no public appender/COPY function suitable for an Eta-owned loader.
Counterevidence considered: DuckDB's appender evidence shows a real native loader can beat batched SQL by orders of magnitude. That evidence does not transfer to LadybugDB without a public equivalent.
Remaining uncertainty: LadybugDB may support textual COPY FROM or future C APIs that deserve a first-class wrapper.
Recommendation for production: Keep this deferred until performance evidence from real indexing or a native public API appears.
Confidence: Medium.
Would change if: A representative reindex benchmark shows Param.rows is inadequate or a stable LadybugDB C bulk API appears.

V-Lbug-Timeout-1 - Add direct connection timeout helpers.
Status: ACCEPT.
Decision: Add Connection.query_string_with_timeout, Connection.query_with_timeout, and Connection.exec_with_timeout returning Eta.Effect.t with Connection.timed_error.
Evidence: p1_connection_timeout timed out a direct long query at 100 ms, returned a typed Timeout, and the same connection returned 1 afterward. The focused connector test covers the same behavior through the production API.
Counterevidence considered: Pool.query already had timeout support, but direct Connection is public and direct users would otherwise have to duplicate Effect.blocking, on_cancel, interrupt, and typed timeout mapping.
Remaining uncertainty: The test covers one long query, not repeated cancellation loops or all write/extension operations.
Recommendation for production: Use direct *_with_timeout helpers when a direct connection is deliberate; use Pool for ordinary pooled workflows.
Confidence: High for shape, Medium for exhaustive cancellation stress.
Would change if: Repeated timeout stress shows connection corruption or if direct Connection becomes intentionally internal-only.

## Implementation Follow-Up

Implemented in:

- lib/ladybug/eta_ladybug.mli
- lib/ladybug/eta_ladybug.ml
- lib/ladybug/ladybug_stubs.c
- test/connectors/test_connectors.ml
- test/connectors/dune

The shipped code and this journal agree: Param.rows and direct Connection timeout helpers are implemented; generic copy_from remains deferred. The full repository gate is still blocked by the unrelated LadybugDB extension-helper expectation noted above.
