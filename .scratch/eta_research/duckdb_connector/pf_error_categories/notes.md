# P-F — Error Union with Real SQLite Retry Logic

**Status**: completed (real code + test with retry logic)
**Run log**: `scratch/eta_research/duckdb_connector/pf_error_categories/error.log`

## Test Design

Fixed the previous flawed test (pattern-matching on designed union without call-site analysis):
- **Before**: Designed a union and proved it's exhaustive
- **After**: Wrote actual retry logic that branches on BUSY vs LOCKED, mapped real SQLite codes through the union, verified retry behavior is preserved

## Error Mapping

| SQLite Code | Meaning | Union Mapping | Retry Behavior |
|-------------|---------|---------------|----------------|
| 5 | BUSY | Common:Connection_error | Retry with backoff |
| 6 | LOCKED | Common:Transaction_error | Retry immediate |
| 10 | IOERR | Common:Io_error | Retry with backoff |
| 19 | CONSTRAINT | Common:Constraint_violation | Fail immediately |
| 99 | Unknown | Sqlite variant | Fail immediately |

## Key Finding

**The union preserves retry-relevant categories.**

BUSY (code 5) and LOCKED (code 6) are mapped to DIFFERENT Common variants (Connection_error vs Transaction_error), allowing retry logic to distinguish them and apply different strategies.

## Verdict

**CONFIRMED** — The error union preserves the categories that real retry/backoff logic depends on.

## Artifacts

- Run log: `scratch/eta_research/duckdb_connector/pf_error_categories/error.log`
- Source: `scratch/eta_research/duckdb_connector/pf_error_categories/pf_error_probe.ml`
- Command: `nix develop .#oxcaml --command dune exec scratch/eta_research/duckdb_connector/pf_error_categories/pf_error_probe.exe`
