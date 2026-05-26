# eta-sql

`eta-sql` is Eta's SQL package. It contains:

- `Sqlite`: a low-level SQLite connector over libsqlite3;
- `Sql`: explicit SQL values, rows, schema/query builders, pools,
  transactions, and migrations;
- `Sql.Eta_pool`: the Eta-native pool and execution surface for SQLite.

This package is not an ORM. Applications own their data model and state; Eta SQL
owns rendering, binding, execution, decoding, pooling, and migration mechanics.

## SQLite Execution Model

SQLite is synchronous embedded I/O. Eta applications should use `Sql.Eta_pool`
so database work runs through `Eta.Effect.blocking` instead of pinning the Eio
calling domain.

The substrate decision is recorded in
`scratch/eta_research/sqlite_eta_effect/`:

- same-domain SQLite can starve Eio co-fibers under lock contention;
- per-call `Effect.blocking` is within the preliminary floor budget versus a
  pinned worker;
- query deadlines must interrupt SQLite with `sqlite3_interrupt`;
- parent/supervisor cancellation must also interrupt started SQLite work through
  `Effect.blocking ?on_cancel`;
- row scans must use bounded blocking batches, not one blocking handoff per row;
- transactions are expressed by holding one `Eta.Pool` connection for the whole
  transaction body;
- `SQLITE_BUSY` stays visible as a SQLite result code so callers can use
  `Eta.Effect.retry` and `Eta.Schedule`.

For scans, the measured tradeoff is explicit: same-domain stepping was the cost
optimum in the 200k-row fixture (about 28.5 ms and 3.2 MB allocated), but it
held the calling Eio domain for the whole scan. Batched `Effect.blocking` at
1024 rows paid about 12% wall time and 23% allocation in that run (about
32.0 ms and 3.9 MB allocated) while keeping heartbeat p99/max near 39 us. This
package optimizes for co-fiber fairness, so `Sql.Eta_pool.fold` uses bounded
blocking batches.

## Eta Usage

```ocaml
module Q = Sql
module S = Sqlite

module Items = struct
  module T = Q.Table.Make (struct
    let name = "items"
  end)

  include T

  let id = column "id" Q.int
end

let program =
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"sqlite"
      {
        max_threads = 16;
        max_queued = 64;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let create_items =
    Q.Schema.(
      create_table ~if_not_exists:true Items.table
        [ column ~primary_key:true Items.id ]
      |> compile)
  in
  let insert_item =
    Q.Insert.(into Items.table |> value Items.id 1 |> compile)
  in
  let select_items =
    Q.Select.(from Items.table Q.Projection.(one Items.id) |> compile)
  in
  Q.Eta_pool.create ~blocking_pool ~max_size:4 (S.default_config "app.db")
  |> Eta.Effect.bind (fun pool ->
         Q.Eta_pool.run_schema ~blocking_pool ~timeout pool create_items
         |> Eta.Effect.bind (fun () ->
                Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                  insert_item)
         |> Eta.Effect.bind (fun _ ->
                Q.Eta_pool.select ~blocking_pool ~timeout pool select_items))
```

Use `Sql.Pool` only for synchronous/Riot-parity experiments and low-level tests.
Production Eta code should prefer `Sql.Eta_pool`. The top-level synchronous
helpers use `Sql.Pool`; they are not the evidence-backed Eta execution surface.

Typed builder values compile before execution. Use `Select.compile`,
`Insert.compile`, `Update.compile`, `Delete.compile`, and
`Schema.compile`, then route those values through `Sql.Eta_pool.select`,
`Sql.Eta_pool.fold_select`, `Sql.Eta_pool.execute_compiled`, or
`Sql.Eta_pool.run_schema`. That keeps table/column type safety on the same
path as the blocking-pool timeout and cancellation protocol.

The typed SELECT builder supports ordinary predicates, joins, DISTINCT, COUNT,
SUM over integer columns, GROUP BY, HAVING, subquery predicates, CTEs, and
ROW_NUMBER window projections. INSERT supports ON CONFLICT DO NOTHING, ON
CONFLICT DO UPDATE from excluded values, and RETURNING through
`Sql.Eta_pool.returning`. UPDATE and DELETE also expose typed RETURNING.

Every `Sql.Eta_pool` operation that runs SQLite requires a `~timeout`. This is
part of the cancellation contract: the operation races the blocking SQLite call
against `sqlite3_interrupt`, so an outer `Eta.Effect.timeout` does not leave an
in-flight `sqlite3_step` waiting for SQLite's busy timeout.

For large reads, use `Sql.Eta_pool.fold_select ?batch_size` instead of
fetching one row per effect. The fold path steps SQLite in bounded blocking
batches and folds typed rows on the caller fiber.

The old public `query_cursor` surface was removed because it looked like
streaming while buffering rows up front. Use `select` for materialized
typed reads and `fold_select` for scans.

Use a dedicated SQL blocking pool for production SQLite work. The fanout probe
ran 8 scan fibers plus 8 ad-hoc query fibers over `max_threads=4`; the pool
saturated at 4 active workers, queued up to 12 jobs, and ad-hoc query p99 rose
to about 5.0 ms while heartbeat p99 stayed below 1 ms. Size `max_threads` for
the peak number of concurrently runnable SQL fibers whose SQL tail latency
matters; otherwise scan batches and ad-hoc queries will queue behind each other.

## Migrations

`Sql.Migrate` resolves SQL files named like `1_create_users.sql`,
`2_add_orders.up.sql`, and `2_add_orders.down.sql`. Non-file directory
entries are ignored. Applied migrations store SHA-256 checksums, detect dirty
rows and checksum drift, and support `run`, `run_to`, and `undo`.

The migration engine is a synchronous prior-art surface, ported by analogy from
Riot/sqlx-style migration mechanics. It is useful for package parity, but it is
separate from the evidence-backed Eta SQLite execution decision above.

## Verification

Focused gate:

```sh
nix develop .#oxcaml -c dune runtest packages/sql --force
nix develop .#oxcaml -c dune exec scratch/eta_research/query_api/p1_eta_pool_typed.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/query_api/p2_query_surface.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/sqlite_eta_effect/sqlite_scan_probe.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/sqlite_eta_effect/sqlite_fanout_probe.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/sqlite_eta_effect/sqlite_cancel_generic_probe.exe
```

Release/install gates:

```sh
nix develop .#oxcaml -c dune build @install
nix develop .#oxcaml -c dune build --profile release packages/sql packages/eta
```
