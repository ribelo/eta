# P-Lbug-6 - Pool Fit

Status: Partial
Verdict: Partial - Eta.Pool fits LadybugDB's database/connection split for the safe lifecycle ordering. Unsafe ordering did not crash in the isolated child, but using a pooled connection after closing the database failed, so the driver should enforce pool shutdown before database close.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_6/p_lbug_6.log

Command used:

nix develop -c env LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p_lbug_6/p_lbug_6_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_6.log.

## What Was Tested

- Created an Eta.Pool with LadybugDB connection acquire/release functions.
- Used Pool.with_resource to run RETURN 1 through a pooled connection.
- Safe ordering: Pool.shutdown first, then database close.
- Unsafe ordering in a child process: database close while pool remains alive, then use pool again, then Pool.shutdown.

## Evidence

Relevant lines from p_lbug_6.log:

    safe.use_before_shutdown=true
    safe.pool_shutdown=Ok
    safe.db_closed_after_pool=true
    safe.assertion=pass
    unsafe.use_before_db_close=true
    unsafe.db_closed_while_pool_alive=true
    unsafe.use_after_db_close=error
    unsafe.pool_shutdown_after_db_close=Ok
    unsafe.child_exit=0
    unsafe.completed=true
    verdict=Partial

## Surprise Findings

- Unsafe ordering did not crash in this run, but the next pooled connection use failed.
- Pool.shutdown still completed after the database had already been closed.

## Driver Implication

The public driver should keep the database handle as the parent resource, create pools beneath it, and close resources in this order:

1. Pool.shutdown
2. Connection release/destruction by pool finalizers
3. Database destroy

Do not make database close while a pool is live a supported operation.

## What Was Not Measured

- File-backed databases.
- Concurrent checkouts during database close.
- Pool cancellation while connection acquire is blocked.
- Health-check eviction of broken LadybugDB connections after unsafe ordering.

## Stop/Continue Decision

P-Lbug-6 is Partial but satisfies the required pool-fit probe with a captured log.
