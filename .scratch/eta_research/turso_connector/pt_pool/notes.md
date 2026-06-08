# P-Turso-4 - File-backed Pool Fit

Status: **Partial**

Evidence:
- build log: build.log
- pool log: pool.log

Safe ordering works:
- create file-backed Turso handle
- create Eta.Pool over that handle
- use pooled resource for SELECT 1
- shutdown pool
- close database handle

Unsafe ordering is not supported:
- child process created pool and used it successfully
- child closed the database while the pool was still live
- later use did not complete; parent killed/observed the child as signaled

Recommendation: preserve the accepted lifecycle invariant. Database must
outlive Pool; production Turso should not attempt to tolerate closing the
database while pooled connections remain reachable.

