# P6 — Encryption Probe

**Status**: completed (paper analysis)
**Hypothesis H-6**: Encryption at rest integrates cleanly with connector lifecycle.
**Verdict**: ✅ **CONFIRMED** — Encryption is transparent to the C API.

## Analysis

Turso supports encryption at rest via the `sqlite3_key()` function or by passing an encryption key at database open time.

### Key Findings

1. **Transparent to C API**: Encryption is handled internally by Turso. The C API remains the same.

2. **Key at open time**: The encryption key is passed when opening the database:
   ```c
   sqlite3_open_v2("encrypted.db", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
   sqlite3_key(db, "my-secret-key", 13);
   ```

3. **No API changes**: The connector doesn't need to change the C API calls. Just add the key parameter.

4. **Pool integration**: Encryption key is per-database, not per-connection. The pool can share the key.

### Implications for Connector Design

- **Add `?encryption_key` parameter**: `Database.open ~encryption_key:"..." path`
- **Key stored in pool**: The pool stores the key and passes it when creating connections.
- **No new primitives**: Encryption is transparent to Eta.

## Verdict

H-6 is confirmed. Encryption integrates cleanly with the connector lifecycle.
