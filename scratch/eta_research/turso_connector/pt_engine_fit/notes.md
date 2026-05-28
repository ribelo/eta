# P-Turso-1 - ENGINE Fit

Status: **Confirmed**

Evidence:
- build log: build.log
- smoke log: smoke.log

The probe compiles a Turso-backed module under the accepted DuckDB P-A
ENGINE.S signature and runs a file-backed create/insert/select/close smoke.

Finding: the missing sqlite3_column_int symbol is avoidable by reading integer
columns through sqlite3_column_int64. No broader ENGINE-shape divergence was
needed in this bounded fixture.

