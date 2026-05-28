# LadybugDB Connector - Results

Status: lab closed for implementation planning under OBJECTIVE_LADYBUGDB.md v2.

The earlier P1-P8 paper-analysis verdicts are not accepted evidence for this lab. This file tracks only captured run logs or explicit Untested blockers.

## Probe Ledger

| Probe | Status | Evidence |
| --- | --- | --- |
| P0 API survey | Accepted prior probe | p0_api_survey/notes.md; re-run locally with LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p0_api_survey/p0_link_probe.exe |
| P-Lbug-1 Arrow C-data NODE decoder | Confirmed | p_lbug_1/notes.md; p_lbug_1/p_lbug_1.log |
| P-Lbug-2 cancellation under Effect.timeout | Confirmed | p_lbug_2/notes.md; p_lbug_2/p_lbug_2.log |
| P-Lbug-3 Cypher parameterization | Partial | p_lbug_3/notes.md; p_lbug_3/p_lbug_3.log |
| P-Lbug-4 error surface inventory | Partial | p_lbug_4/notes.md; p_lbug_4/p_lbug_4.log |
| P-Lbug-5 fairness under Effect.blocking | Partial | p_lbug_5/notes.md; p_lbug_5/p_lbug_5.log |
| P-Lbug-6 Pool fit | Partial | p_lbug_6/notes.md; p_lbug_6/p_lbug_6.log |

## Summary By Probe

### P-Lbug-1 - Arrow C-data NODE Decoder

Confirmed. LadybugDB 0.17.0 exposes query results through Arrow C-data. For MATCH (p:Person {name: 'Ada'}) RETURN p, the Arrow schema is a root struct with a single p child; p is a struct containing _ID, _LABEL, and declared primitive properties. The fixture decodes label, internal id, id, name, age, and active into an OCaml record and records ocaml_node.assertions=pass.

Surprise: NODE values are not opaque in this Arrow path.

Unmeasured: REL/PATH, nulls, lists, maps, UUID/bytes, nested values, multi-row/multi-chunk decoding, and zero-copy guarantees beyond direct C-data buffer reads.

### P-Lbug-2 - Cancellation Under Effect.timeout

Confirmed. Effect.timeout plus Effect.blocking ~on_cancel:lbug_connection_interrupt returned Timeout after about 200ms and left the same connection reusable.

Surprise: the binding must treat interrupted query returns as controlled values/errors. Raising from the worker after timeout produced Concurrent[Die(...); Fail(Timeout)] in an earlier fixture attempt.

Unmeasured: repeated cancellation loop, interrupt latency distribution, prepared-statement cancellation.

### P-Lbug-3 - Cypher Parameterization

Partial. Named parameters work for string, int64, double, bool, null, list, and map values. Empty string, long string, and large int64 edge cases passed.

Untested blocker: bytes/blob parameters. The visible LadybugDB C API has lbug_value_get_blob but no lbug_value_create_blob or prepared_statement_bind_blob symbol.

Surprises:

- Map parameters can be returned, but direct field projection syntax tried first failed with an unhelpful unknown execution error.
- lbug_value_destroy owns values returned by lbug_value_create_*; manually freeing those pointers double-freed.

### P-Lbug-4 - Error Surface Inventory

Partial. The useful diagnostics are on lbug_query_result_get_error_message, not lbug_get_last_error. The C API has only LbugSuccess/LbugError as structured state, so typed categories require string classification.

Observed strings:

- Parser exception -> Query_syntax
- Binder exception -> Type_mismatch
- duplicated primary key Runtime exception -> Integrity_violation
- Interrupted. -> Timeout_or_interrupt
- closed raw handle in isolated child -> closed/invalid connection behavior, not a supported operation

Unmeasured: OOM, filesystem/open failures, full retry taxonomy.

### P-Lbug-5 - Fairness Under Effect.blocking

Partial. A 5-second run with 16 heartbeat fibers at 1ms intervals while a long LadybugDB query ran through Effect.blocking produced p99 jitter 0.054ms and max jitter 4.366ms; the query timed out and the connection stayed reusable.

The requested 30-second window did not emit a summary under an outer timeout, so the full P-Lbug-5 timing obligation remains unproven.

### P-Lbug-6 - Pool Fit

Partial. Eta.Pool fits the safe Database -> Pool -> Connection lifecycle shape. Safe ordering passed: use pooled connection, Pool.shutdown, then database close.

Unsafe database close while the pool remained alive did not crash in the isolated child, but subsequent pooled connection use failed. The driver should enforce or document pool shutdown before database close.

## ADR

See adr.md.

## Journal

See V-Lbug-Connector at the bottom of journal.md.

## Final Stop/Continue State

No hard stop was triggered.

Implementation can begin against adr.md, with the Partial and Untested gaps carried into the implementation backlog rather than hidden as Confirmed evidence.
