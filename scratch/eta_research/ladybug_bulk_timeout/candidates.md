# Candidates

## Bulk Insert / Batch Parameters

| Candidate | Why plausible | Evidence needed to win | Falsifier | Status |
| --- | --- | --- | --- | --- |
| A. Keep only scalar per-row Connection.exec | Already works and has no new API | Batch evidence fails or is not measurably better | UNWIND $rows works and is much faster | Dominated |
| B. Add a small row-batch parameter helper | Reuses Value.List plus heterogenous Value.Struct binding and keeps Cypher explicit | Runtime insert through UNWIND $rows AS row succeeds | LadybugDB cannot project row fields in write queries | Accepted |
| C. Add Connection.copy_from / generic bulk loader | Matches the reviewer suggestion and could hide batching | Native COPY/appender API or a proven identifier-safe Cypher builder | No native API and graph labels/properties remain app-owned Cypher | Deferred |

## Connection-Level Query Timeouts

| Candidate | Why plausible | Evidence needed to win | Falsifier | Status |
| --- | --- | --- | --- | --- |
| A. Keep timeout only on Pool | Current production path already works | Direct connection remains a low-level synchronous API | Direct users must duplicate Eta cancellation/interrupt protocol | Dominated |
| B. Add direct connection *_with_timeout effect helpers | Eta owns typed timeout, interrupt, and blocking-pool protocol | Slow direct query times out and connection is reusable | Helper cannot preserve typed timeout or leaves connection corrupted | Accepted |
| C. Add optional ?timeout to synchronous Connection.query | Looks close to the feedback wording | Could return same result type without hidden runtime ownership | Return type cannot express effectful timeout without a new hidden thread/runtime | Rejected by type shape |
