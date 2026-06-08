# P-Lbug-4 - Error Surface Inventory

Status: Partial
Verdict: Partial - the C API can expose useful error strings for syntax, type mismatch, integrity violation, and timeout/interrupt, but the useful text is on the failed query-result handle, not lbug_get_last_error. Closed-handle behavior is not a recoverable typed error.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_4/p_lbug_4.log

Command used:

nix develop -c env LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p_lbug_4/p_lbug_4_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_4.log.

## What Was Tested

- Syntax error: malformed MATCH.
- Type mismatch: adding INT64 and STRING.
- Integrity violation: duplicate primary key value.
- Timeout/interrupt: connection query timeout on an expensive query.
- Closed/invalid connection: child process destroys a connection and then queries through the same raw handle.
- Error variant sketch for the driver.

## Evidence

Relevant lines from p_lbug_4.log:

    syntax_error.state=LbugError
    syntax_error.error=unknown
    syntax_error.result_error=Parser exception: Invalid input <MATCH (p:Person RETURN>...
    type_mismatch.state=LbugError
    type_mismatch.error=unknown
    type_mismatch.result_error=Binder exception: Cannot match a built-in function for given function +(INT64,STRING)...
    integrity_violation.state=LbugError
    integrity_violation.error=unknown
    integrity_violation.result_error=Runtime exception: Found duplicated primary key value 1...
    timeout_interrupt.state=LbugError
    timeout_interrupt.error=unknown
    timeout_interrupt.result_error=Interrupted.
    closed_connection_child.exit=10
    closed_connection_child.class=closed_handle_error_or_setup_failure

## Interpretation

- Query failures all return only the coarse lbug_state value LbugError.
- lbug_get_last_error is not sufficient for query failure diagnostics in these fixtures; it returned unknown.
- The lbug_query_result handle still exists on these LbugError paths and contains the actionable error string.
- The driver should classify errors by inspecting the query-result error string before destroying the result.
- Closed raw handles are not a safe public operation. The production driver should make closed handles unrepresentable or guard them in OCaml state before calling C.

## Recommended Error Variant

- Connection_closed_or_invalid
- Query_syntax
- Type_mismatch
- Integrity_violation
- Timeout_or_interrupt
- Other of string

The mapping is not truly lossless because the C API exposes no structured error codes beyond LbugSuccess/LbugError.

## Surprise Findings

- lbug_query_result_get_error_message is useful even when lbug_connection_query returns LbugError.
- lbug_get_last_error was not useful for these query failures.
- Querying a destroyed connection in a child process returned an error exit rather than crashing in this run, but this remains unsafe raw-handle behavior rather than a driver contract.

## What Was Not Measured

- OOM.
- Filesystem/open failures.
- Retry-relevant transient categories beyond timeout/interrupt.
- Whether every parser/binder/runtime error string is stable enough for long-term classification.

## Stop/Continue Decision

P-Lbug-4 is Partial but does not trigger a stop condition. Continue to P-Lbug-5.
