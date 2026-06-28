# Results

Status: first orientation probe run on 2026-05-26 under nix develop .#oxcaml.
This is not the B/C/D decision. It only exercises lock contention and compares
same-domain stepping with Effect.blocking.

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_blocking_probe.exe
~~~

Output:

~~~text
direct_p99_us=79528
blocking_p99_us=9
blocking_completed=1
direct_busy=true
blocking_busy=true
~~~

Re-run after removing the premature API widening:

~~~text
direct_p99_us=79511
blocking_p99_us=10
blocking_completed=1
direct_busy=true
blocking_busy=true
~~~

Re-run after FFI hardening:

~~~text
direct_p99_us=79555
blocking_p99_us=2077
blocking_completed=1
direct_busy=true
blocking_busy=true
~~~

Interpretation:

- direct SQLite lock contention has a heartbeat p99 close to the SQLite busy
  timeout, proving it pins the Eio scheduler thread for this workload;
- Eta.Effect.blocking lock contention has a low heartbeat p99 and increments
  the blocking pool completion counter, proving this single call ran through
  Eta's blocking substrate.

Current evidence status:

- A, same-domain synchronous: contradicted for lock-contention queries if the
  co-fiber stall bar is sub-ms. Still pending Rung 0 workload bars before final
  rejection.
- B, per-call Effect.blocking: plausible. Needs F-Floor, F-Cancel, F-Affinity,
  F-Tx, and F-Busy.
- C, connection-pinned worker systhread: plausible. Needs F-Floor and F-Cancel.
- D, pool of connection plus worker pairs: plausible but only worth deeper work
  if workload profile demands many concurrent readers and B/C do not dominate.
- E, Eta.island: pending rejection memo.

Reference evidence:

- Riot SQL pool is actor-managed, but checked-out connection query/execute calls
  run directly in the caller. Riot's SQLite C stub calls sqlite3_step without
  caml_enter_blocking_section. Eta cannot copy that scheduling model because Eta
  is Eio-based and co-fiber fairness is a first-class requirement.

## F-Floor

Question: for the smallest realistic query, does per-call Effect.blocking impose
enough overhead to force a dedicated connection-pinned worker?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_floor_probe.exe
~~~

Output:

~~~text
B_effect_blocking n=2000 mean_us=5.116 stddev_us=4.140 min_us=3.557 p50_us=5.020 p95_us=6.001 p99_us=7.454 max_us=182.529
C_pinned_worker_pipe n=2000 mean_us=4.071 stddev_us=2.155 min_us=3.136 p50_us=3.957 p95_us=4.959 p99_us=6.062 max_us=87.637
~~~

Re-run after implementation and gates showed one noisy outlier run, then five
stable runs:

~~~text
B mean_us=12.022 p50_us=7.304 p99_us=29.266 max_us=3513.383
C mean_us=5.986 p50_us=5.972 p99_us=7.784 max_us=15.290

B mean_us=5.136 p50_us=4.949 p99_us=8.286 max_us=255.869
C mean_us=4.164 p50_us=4.027 p99_us=9.018 max_us=93.349

B mean_us=5.379 p50_us=4.919 p99_us=7.925 max_us=630.826
C mean_us=4.033 p50_us=3.828 p99_us=5.781 max_us=89.642

B mean_us=5.218 p50_us=5.150 p99_us=7.595 max_us=184.543
C mean_us=4.037 p50_us=3.918 p99_us=5.230 max_us=84.852

B mean_us=5.360 p50_us=5.140 p99_us=9.398 max_us=185.505
C mean_us=4.116 p50_us=3.747 p99_us=9.207 max_us=92.858

B mean_us=5.212 p50_us=5.169 p99_us=7.965 max_us=198.920
C mean_us=3.939 p50_us=3.697 p99_us=6.111 max_us=85.634
~~~

Re-run after FFI hardening:

~~~text
B_effect_blocking n=2000 mean_us=5.072 stddev_us=4.134 min_us=3.626 p50_us=4.799 p95_us=6.342 p99_us=7.735 max_us=179.663
C_pinned_worker_pipe n=2000 mean_us=4.064 stddev_us=1.954 min_us=3.356 p50_us=3.918 p95_us=4.648 p99_us=6.002 max_us=87.136
~~~

Interpretation:

- B is typically about 1.25x to 1.35x C by mean for a prepared primary-key
  lookup, with occasional scheduler outliers.
- B's p99 is usually close enough to C for the preliminary floor threshold, but
  the outlier run shows this evidence should not be overfit.
- Under the preliminary rule from the plan, B still wins this rung on
  simplicity; C would become attractive if a real workload sets a strict
  microsecond tail-latency bar for the smallest query.
- C remains plausible if F-Cancel or F-Affinity contradict B.
- The C probe uses a private Mutex/Condition queue plus a pipe wake-up. Eta.Channel
  is not used because its public contract is same-domain only.

Current status after F-Floor:

- A: contradicted for lock-contention under the preliminary co-fiber bar.
- B: leading, but must still survive F-Cancel, F-Affinity, F-Tx, and F-Busy.
- C: dominated on floor simplicity unless B fails a later rung.
- D: deferred until workload or later evidence requires reader/writer asymmetry.
- E: rejected by island_rejection.md.

## F-Cancel

Question: can the leading B path arrange cancellation with sqlite3_interrupt,
return the blocking worker, and leave the connection reusable?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_cancel_probe.exe
~~~

Output:

~~~text
naive_timeout_elapsed_us=80770.684
naive_timeout_observed=true
interrupt_elapsed_us=5071.541
interrupt_sent=true
query_interrupted=true
connection_reusable=true
blocking_active=0
blocking_completed=2
~~~

Re-run after FFI hardening:

~~~text
naive_timeout_elapsed_us=80689.338
naive_timeout_observed=true
interrupt_elapsed_us=5054.785
interrupt_sent=true
query_interrupted=true
connection_reusable=true
blocking_active=0
blocking_completed=2
~~~

Interpretation:

- Plain Effect.timeout around a started blocking SQLite call is non-preemptive;
  it returned after the SQLite busy timeout, not at the 5 ms Eta timeout.
- A wrapper that starts an interrupting sibling can call sqlite3_interrupt and
  make a long recursive query return in about 5 ms.
- After interruption, the connection handled SELECT 1 and the blocking pool had
  no active worker left.
- B survives this rung only if the production API owns this interrupt-on-timeout
  protocol. Plain Effect.timeout is insufficient for SQL deadlines.

## F-Affinity

Question: under the assumed serialized SQLite threading mode, does B survive
concurrent per-call blocking steps on one sqlite3 handle?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_affinity_probe.exe
~~~

Output:

~~~text
affinity_iterations_per_fiber=1000
affinity_total_ok=2000
affinity_elapsed_us=11845.214
connection_reusable=true
blocking_active=0
blocking_completed=2000
~~~

Re-run after FFI hardening:

~~~text
affinity_iterations_per_fiber=1000
affinity_total_ok=2000
affinity_elapsed_us=9316.064
connection_reusable=true
blocking_active=0
blocking_completed=2000
~~~

Stronger disconfirming re-run after the review:

~~~text
affinity_iterations_per_fiber=100000
affinity_total_ok=200000
held_open_rows=2
held_open_contender_ok=20000
long_step_sum=20000100000
long_step_contender_ok=2000
affinity_elapsed_us=1067975.060
connection_reusable=true
blocking_active=0
blocking_completed=222002
~~~

Interpretation:

- The stronger run prints one line per sub-scenario instead of only an aggregate.
- Primary-key concurrency: two fibers ran 100k prepared primary-key lookups each
  on the same sqlite3 handle through Effect.blocking; affinity_total_ok=200000.
- Held-open interleaving: one statement stayed open while a contender stepped
  another statement on the same handle; held_open_rows=2 and
  held_open_contender_ok=20000.
- Long-step overlap: one recursive query ran while short statements contended on
  the same handle; long_step_sum=20000100000 and long_step_contender_ok=2000.
- No wrong rows or SQLite errors were observed, and the connection stayed
  reusable.
- This supports B under serialized SQLite. It does not prove B is safe if
  SQLite is configured in multi-thread mode; that would force connection
  affinity.

## F-Scan

Question: does the B decision still hold for a 200k-row scan, or does per-row
blocking handoff erase the low-allocation connector win?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_scan_probe.exe
~~~

Output:

~~~text
A_same_domain_released_runtime rows=200000 count=200000 sum=20000100000 wall_ms=28.514 allocated_bytes=3209832 minor_words=0 promoted_words=0 major_words=0 heartbeat_p99_us=28500.008 heartbeat_max_us=28500.008 blocking_completed_delta=0
B_per_row_blocking rows=200000 count=200000 sum=20000100000 wall_ms=773.205 allocated_bytes=698347320 minor_words=86507333 promoted_words=16918 major_words=16918 heartbeat_p99_us=27.107 heartbeat_max_us=1866.983 blocking_completed_delta=200001
B_materialized_one_blocking rows=200000 count=200000 sum=20000100000 wall_ms=33.193 allocated_bytes=12848784 minor_words=1048575 promoted_words=557855 major_words=557855 heartbeat_p99_us=2049.850 heartbeat_max_us=2049.850 blocking_completed_delta=1
B_batch_1024_blocking rows=200000 count=200000 sum=20000100000 wall_ms=32.011 allocated_bytes=3945944 minor_words=0 promoted_words=0 major_words=0 heartbeat_p99_us=39.028 heartbeat_max_us=39.028 blocking_completed_delta=196
~~~

Interpretation:

- Per-row B is rejected for scans. It is about 29x slower than same-domain
  stepping here and allocates about 702 MB for 200k rows.
- A' same-domain released-runtime scanning preserves connector allocation but
  stalls the calling Eio domain for the whole scan, about 30 ms in this run.
- One-call materialization is fast but allocates the whole result and showed a
  1.5 ms heartbeat max.
- Batched B at 1024 rows kept wall time near A'/materialized, preserved low
  allocation, avoided full result materialization, and kept heartbeat p99 under
  the preliminary 1 ms bar.
- Production Eta_pool scan APIs must not perform one blocking handoff per row.
  The supported scan shape is bounded blocking batches.

Design rationale:

- A' is the cost optimum for this fixture: 28.514 ms wall, about 3.2 MB
  allocated, and no blocking-pool handoffs.
- Batched B pays about 12% wall time and about 23% allocation in this run:
  32.011 ms wall and about 3.9 MB allocated.
- That cost buys co-fiber fairness: A' held the calling Eio domain for the
  entire 28.5 ms scan, while batched B kept heartbeat p99/max at about 39 us.
- If the workload profile is later revised so co-fiber jitter does not matter,
  A' should be reopened as a deliberate same-domain scan strategy.

## F-Fanout

Question: what happens when mixed ad-hoc queries and batched scans outnumber a
max_threads=4 SQL blocking pool?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_fanout_probe.exe
~~~

Output:

~~~text
fanout_scan_fibers=8
fanout_query_fibers=8
fanout_query_iterations=1000
fanout_blocking_max_threads=4
fanout_wall_ms=421.351
query_latency_p50_us=154.018
query_latency_p95_us=2681.971
query_latency_p99_us=5006.075
query_latency_max_us=8686.066
scan_wall_p50_us=255548.000
scan_wall_max_us=257240.057
heartbeat_p99_us=602.888
heartbeat_max_us=8332.895
blocking_max_active=4
blocking_max_queued=12
blocking_completed=16448
~~~

Interpretation:

- The pool saturated exactly at max_threads=4 and queued up to 12 jobs, which
  matches 16 runnable SQL fibers over four blocking workers.
- Co-fiber fairness remained inside the preliminary sub-ms p99 bar
  (heartbeat p99 603 us), with one 8.3 ms max outlier.
- Ad-hoc query p99 rose to about 5.0 ms because query jobs queued behind scan
  batches. This is not a correctness problem, but it is capacity planning.
- Production guidance: use a dedicated SQL blocking pool and size
  max_threads for the peak number of concurrently runnable SQL fibers whose
  tail latency matters. If scan fibers and ad-hoc queries share a smaller pool,
  the scheduler stays fair but SQL queueing becomes visible in query latency.

## F-Cancel-Generic

Question: does cancellation from structured concurrency, not only explicit SQL
timeout, interrupt a started sqlite3_step and release the pool slot?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_cancel_generic_probe.exe
~~~

Output after adding the generic blocking cancel hook:

~~~text
generic_cancel_elapsed_us=5120.039
connection_reusable=true
blocking_active=0
blocking_completed=6
~~~

Interpretation:

- The probe starts a long recursive query through Sql.Eta_pool, exits a
  supervisor scope after 5 ms, then verifies that the same max-size-1 pool can
  run SELECT 1.
- Eta.Effect.blocking now accepts ?on_cancel. Sql.Eta_pool passes
  sqlite3_interrupt for every started SQLite job.
- Parent/supervisor cancellation interrupts the running sqlite3_step in about
  5 ms, the connection remains reusable, and the blocking pool has no active
  worker left.
- A lock-contention variant still waited for SQLite's busy timeout in this
  session. That is handled by the BUSY/retry path, not by treating busy-handler
  sleep as a cancellation primitive.

## F-Tx

Question: can B express a transaction by checking out one Eta.Pool connection
for the whole BEGIN..COMMIT span?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_tx_probe.exe
~~~

Output:

~~~text
tx_internal_count=1
observer_count_during_tx=0
final_count_after_commit=1
blocking_active=0
blocking_completed=7
~~~

Re-run after FFI hardening:

~~~text
tx_internal_count=1
observer_count_during_tx=0
final_count_after_commit=1
blocking_active=0
blocking_completed=7
~~~

Interpretation:

- The transaction body saw its uncommitted insert on the checked-out connection.
- A concurrent observer using the same Eta_pool saw 0 during the transaction.
- After commit, the final pooled query saw 1.
- B satisfies transaction pinning when the public API owns transaction scope via
  Eta.Pool.with_resource.

## F-Busy

Question: does SQLITE_BUSY compose with Eta retry and Schedule?

Command:

~~~sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_busy_probe.exe
~~~

Output:

~~~text
busy_attempts=6
rows_affected=1
final_count=1
blocking_active=0
blocking_completed=7
~~~

Re-run after FFI hardening:

~~~text
busy_attempts=6
rows_affected=1
final_count=1
blocking_active=0
blocking_completed=7
~~~

Interpretation:

- A contender with 1 ms SQLite busy timeout retried through Effect.retry and
  Schedule.spaced while another connection held the writer lock.
- After the owner committed, the retrying insert succeeded and the final count
  was 1.
- B satisfies the busy/retry rung as long as production errors preserve the
  SQLite result code so callers can classify BUSY.

## Current Verdict

- Conditionally accepted under the current assumptions: B, Effect.blocking over
  a checked-out Eta.Pool connection, for one-shot query/execute and batched
  scans.
- Required production protocol: Eta_pool SQL operations require an explicit
  timeout and must race the blocking operation against sqlite3_interrupt,
  surfacing Timeout rather than raw SQLITE_INTERRUPT. Started blocking SQLite
  jobs must also install a generic cancellation hook that calls
  sqlite3_interrupt when parent/supervisor cancellation arrives.
- Rejected for scans: one Effect.blocking handoff per row.
- Selected scan shape: bounded batches through Effect.blocking; current typed
  package surface is Sql.Eta_pool.fold_select ?batch_size. The old public
  query_cursor surface was removed because it looked streaming-shaped while
  materializing rows.
- Explicit tradeoff: A' same-domain scans are cheaper on wall time and
  allocation, but batched B buys sub-100 us co-fiber jitter in the scan fixture.
- Dominated for now: C, because its floor is only modestly faster and it adds a
  private thread queue plus wake-up protocol.
- Deferred: D, unless the workload profile later requires explicit reader/writer
  asymmetry.
- Rejected: E, Eta.island.

## Implementation Follow-up

Implemented in `packages/sql`:

- `Sql.Eta_pool.create` accepts an optional Eta blocking pool and opens, pings,
  and closes SQLite connections through `Eta.Effect.blocking`.
- `Sql.Eta_pool.select`, `returning`, `execute_compiled`, `run_schema`, and
  `with_transaction` run checked-out SQLite work through `Effect.blocking`.
- Required per-call `timeout` on Eta_pool query/execute operations races the
  blocking query with `sqlite3_interrupt` and surfaces `Timeout` instead of raw
  `SQLITE_INTERRUPT`.
- `Effect.blocking ?on_cancel` supplies the generic cancellation hook needed for
  parent/supervisor cancellation. Eta_pool uses it to interrupt started SQLite
  work outside the explicit timeout path.
- `Sql.Eta_pool.fold_select ?batch_size` scans typed rows through bounded
  blocking batches rather than per-row handoff or whole-result materialization.
- Public `query_cursor` was removed. Materialized typed reads use
  `Sql.Eta_pool.select`; scans use `Sql.Eta_pool.fold_select`.
- `Sql.Pool`, top-level synchronous helpers, and `Sql.Migrate` remain
  synchronous/Riot-parity and prior-art surfaces. They are not evidence for the
  Eta execution substrate, which is `Sql.Eta_pool`.
- SQLite named result-code and storage-class constants are public so retry and
  decoding code do not use magic integers.
- SQLite stubs release the OCaml runtime around open, close, prepare, reset,
  finalize, exec-script, step, extension loading, backup, and restore calls
  that can block or traverse filesystem state. OCaml strings are copied before
  entering blocking sections.
- Migration checksums use SHA-256 through `mirage-crypto`, matching Riot SQLx
  behavior rather than OCaml's MD5 `Digest`.
- Directory migration sources inspect entries and skip non-files before parsing
  SQL filenames, while unreadable regular `.sql` files surface
  `Read_migration_file_failed`.

Verification commands:

```sh
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_blocking_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_floor_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_cancel_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_cancel_generic_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_affinity_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_scan_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_fanout_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_tx_probe.exe
nix develop .#oxcaml -c dune exec .scratch/research/evidence/eta_research/sqlite_eta_effect/sqlite_busy_probe.exe
nix develop .#oxcaml -c dune runtest packages/sql --force
nix develop .#oxcaml -c dune runtest packages/eta/test --force
nix develop .#oxcaml -c dune build --profile release packages/sql packages/eta
nix develop .#oxcaml -c dune build @install
```
