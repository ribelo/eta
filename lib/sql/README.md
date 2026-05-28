# Eta SQL

Eta SQL is Eta's SQL package. It contains:

- `Sqlite`: a low-level SQLite connector over libsqlite3;
- `Eta_sql`: explicit SQL values, rows, schema/query builders, migrations, and
  the Eta-native SQLite execution surface;
- `Eta_sql.Eta_pool`: the single public pool, transaction, and runner surface
  for SQLite.

This package is not an ORM. Applications own their data model and state; Eta SQL
owns rendering, binding, execution, decoding, pooling, and migration mechanics.

## SQLite Execution Model

SQLite is synchronous embedded I/O. Eta applications should use `Eta_sql.Eta_pool`
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
- transactions are expressed by holding one internal pool connection for the
  whole transaction body while exposing the same runner verbs;
- `SQLITE_BUSY` stays visible as a SQLite result code so callers can use
  `Eta.Effect.retry` and `Eta.Schedule`.

For scans, the measured tradeoff is explicit: same-domain stepping was the cost
optimum in the 200k-row fixture (about 28.5 ms and 3.2 MB allocated), but it
held the calling Eio domain for the whole scan. Batched `Effect.blocking` at
1024 rows paid about 12% wall time and 23% allocation in that run (about
32.0 ms and 3.9 MB allocated) while keeping heartbeat p99/max near 39 us. This
package optimizes for co-fiber fairness, so `Eta_sql.Eta_pool.fold` uses bounded
blocking batches.

## Eta Usage

```ocaml
module Q = Eta_sql
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
  let create_items =
    Q.Eta_schema.(
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
  Q.Eta_pool.create ~blocking_pool ~default_timeout:(Eta.Duration.ms 250)
    ~max_size:4 (S.default_config "app.db")
  |> Eta.Effect.bind (fun pool ->
         Q.Eta_pool.run_schema pool create_items
         |> Eta.Effect.bind (fun () ->
                Q.Eta_pool.execute_compiled pool insert_item)
         |> Eta.Effect.bind (fun _ ->
                Q.Eta_pool.select pool select_items))
```

`Eta_sql.Eta_pool` is the only public execution surface. `Connection` and the
old synchronous pool are internal implementation details; callers run raw SQL,
compiled typed statements, schema statements, scans, and transactions through
the same runner verbs.

Typed builder values compile before execution. Use `Select.compile`,
`Insert.compile`, `Update.compile`, `Delete.compile`, and
`Eta_schema.compile`, then route those values through `Eta_sql.Eta_pool.select`,
`Eta_sql.Eta_pool.fold_select`, `Eta_sql.Eta_pool.execute_compiled`, or
`Eta_sql.Eta_pool.run_schema`. That keeps table/column type safety on the same
path as the blocking-pool timeout and cancellation protocol.

The typed SELECT builder supports ordinary predicates, chainable N-table joins,
DISTINCT, COUNT, SUM, AVG, MIN, MAX, GROUP BY, aggregate HAVING predicates,
subquery predicates, CTEs, and ROW_NUMBER window projections. INSERT supports
ON CONFLICT DO NOTHING, ON
CONFLICT DO UPDATE from excluded values, and RETURNING through
`Eta_sql.Eta_pool.returning`. UPDATE and DELETE also expose typed RETURNING.

`Eta_sql.Eta_pool.create` accepts `?blocking_pool` and `?default_timeout`.
Individual operations accept `?timeout` to override the pool default. If neither
is present the operation fails loudly instead of inventing a timeout. The
cancellation contract is unchanged: the operation races the blocking SQLite
call against `sqlite3_interrupt`, so an outer `Eta.Effect.timeout` does not
leave an in-flight `sqlite3_step` waiting for SQLite's busy timeout.

Transactions use the same verbs as pool execution:

```ocaml
Q.Eta_pool.with_transaction pool (fun tx ->
  Q.Eta_pool.execute_compiled tx insert_item
  |> Eta.Effect.bind (fun _ -> Q.Eta_pool.select tx select_items))
```

The transaction callback receives a `Eta_pool.tx Eta_pool.runner`; the pool
itself is a `Eta_pool.pool Eta_pool.runner`. Those phantom runner kinds do not
unify, so transaction-only helper functions cannot accidentally accept a pool
runner.

## Typed Builder

Start a source with `Source.from` and extend it with `Source.join`. Use
`Scope.column` with `Scope.self`, `Scope.left`, and `Scope.right` to promote a
column only when the target scope contains its origin. That keeps N-table joins
chainable without a polymorphic cast. Self-joins should use table aliases:
create the alias with `Table.alias`, then create alias-qualified columns with
`Table.column`.

`Expr` is the typed value carrier for predicates, projections, and aggregate
HAVING. The inventory includes literal and column values, `eq`/`ne`/`gt`/`ge`/
`lt`/`le` column-vs-literal predicates, `eq_col`/`gt_col`/`ge_col`/`lt_col`/
`le_col`, `eq_expr`/`gt_expr` and the other expression comparisons, `add`,
`sub`, `mul`, `div`, `between`, `in_values`, `in_select`, `exists`, `case`,
boolean `and_`/`or_`/`not_`, and aggregate expressions `count`, `sum_int`,
`sum_float`, `avg`, `min`, and `max`.

`Projection.one` projects a column, `Projection.expr` projects an arbitrary
typed expression, and `Projection.t2` through `Projection.t8` combine projection
values. That makes mixed column/expression/aggregate selects expressible.

For large reads, use `Eta_sql.Eta_pool.fold_select ?batch_size` instead of
fetching one row per effect. The fold path steps SQLite in bounded blocking
batches and folds typed rows on the caller fiber.

The old public `query_cursor` surface was removed because it looked like
streaming while buffering rows up front. Use `select` for materialized
typed reads and `fold_select` for scans.

## Optional Eta_schema PPX

The `ppx_eta` package includes optional table-declaration sugar for Eta SQL.
It does not create a parallel query system; it expands to the same generative
table module, typed columns, schema artifact, and compiled `Eta_sql.Eta_pool` path
shown above.

```ocaml
[%%eta.sql.table
type users = {
  id : int [@primary_key];
  name : string [@not_null];
  active : bool [@not_null];
}]
```

This generates:

- `type users_row = { id : int; name : string; active : bool }`
- `module Users`, with `Users.table`, `Users.id`, `Users.name`, and
  `Users.active`
- `Users.all`, an all-column projection returning `users_row`
- `Users.schema`, a `Eta_sql.Eta_schema.create_table` artifact preserving supported
  column attributes

The input declaration is syntax for the PPX; the row type users write against is
the generated `users_row`:

```ocaml
let print_user (row : users_row) =
  Printf.printf "%s\\n" row.name
```

Supported field types are `int`, `int64`, `string`, `bool`, `float`, `bytes`,
and nullable forms such as `string option`. Supported column attributes are
`[@primary_key]`, `[@not_null]`, `[@unique]`, `[@default "..."]`, and
`[@references Other.column]` with optional `[@on_delete "..."]` and
`[@on_update "..."]`.

The schema PPX is intentionally small. JSON columns, custom decoders, sum
types, generated `CHECK` constraints, and generated indexes still use manual
table modules or explicit `Eta_sql.Eta_schema` values.

Use it by adding the PPX to the target that declares tables:

```lisp
(preprocess
 (pps ppx_eta))
```

Queries remain ordinary typed builder values:

```ocaml
let active_users =
  Q.Select.(
    from Users.table Users.all
    |> where Q.Expr.(eq Users.active true)
    |> order_by Users.id
    |> compile)
```

`Users.all` is the record-producing projection. Partial projections keep the
ordinary builder behavior, so
`Q.Projection.(t2 (one Users.id) (one Users.name))` returns `int * string`.

Use a dedicated SQL blocking pool for production SQLite work. The fanout probe
ran 8 scan fibers plus 8 ad-hoc query fibers over `max_threads=4`; the pool
saturated at 4 active workers, queued up to 12 jobs, and ad-hoc query p99 rose
to about 5.0 ms while heartbeat p99 stayed below 1 ms. Size `max_threads` for
the peak number of concurrently runnable SQL fibers whose SQL tail latency
matters; otherwise scan batches and ad-hoc queries will queue behind each other.

## Migrations

`Eta_sql.Migrate` resolves SQL files named like `1_create_users.sql`,
`2_add_orders.up.sql`, and `2_add_orders.down.sql`. Non-file directory
entries are ignored. Applied migrations store SHA-256 checksums, detect dirty
rows and checksum drift, and support `run`, `run_to`, and `undo`.

The migration engine is a synchronous prior-art surface, ported by analogy from
Riot/sqlx-style migration mechanics. It is useful for package parity, but it is
separate from the evidence-backed Eta SQLite execution decision above.

## Verification

Focused gate:

```sh
nix develop -c dune runtest lib/sql test/sql test/ppx --force
```

Release/install gates:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
```
