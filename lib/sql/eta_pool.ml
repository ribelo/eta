module Compiled = Dsl.Compiled

type error = [ `Eta_sql of Types.sql_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
type pool
type tx

type pool_state = {
  pool : (Connection.t, error) Eta.Pool.t;
  blocking_pool : Eta.Effect.Blocking.Pool.t option;
  default_timeout : Eta.Duration.t option;
}

type tx_state = {
  conn : Connection.t;
  blocking_pool : Eta.Effect.Blocking.Pool.t option;
  default_timeout : Eta.Duration.t option;
}

type _ runner =
  | Pool_runner : pool_state -> pool runner
  | Tx_runner : tx_state -> tx runner

type t = pool runner

let lift_sql_result = function
  | Ok value -> Eta.Effect.pure value
  | Result.Error err -> Eta.Effect.fail (`Eta_sql err)

let blocking_result ?blocking_pool ?name f =
  Eta.Effect.blocking ?pool:blocking_pool ?name f
  |> Eta.Effect.bind lift_sql_result

let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
  let interrupt () = Sqlite.interrupt (Connection.sqlite conn) in
  let check_not_cancelled = Eta.Effect.sync Eio.Fiber.check in
  let query =
    Eta.Effect.blocking ?pool:blocking_pool ~name ~on_cancel:interrupt f
    |> Eta.Effect.map (function
         | Ok value -> `Query_ok value
         | Result.Error err -> `Query_error err)
  in
  let interrupt =
    Eta.Effect.delay timeout
      (Eta.Effect.sync interrupt |> Eta.Effect.map (fun () -> `Timed_out))
  in
  Eta.Effect.race [ query; interrupt ]
  |> Eta.Effect.bind (function
       | `Query_ok value -> check_not_cancelled |> Eta.Effect.map (fun () -> value)
       | `Query_error err ->
           check_not_cancelled
           |> Eta.Effect.bind (fun () -> Eta.Effect.fail (`Eta_sql err))
       | `Timed_out -> Eta.Effect.fail `Timeout)

let acquire_connection ?blocking_pool sqlite =
  blocking_result ?blocking_pool ~name:"sqlite.open" (fun () ->
      Connection.create sqlite)

let release_connection ?blocking_pool conn =
  Eta.Effect.blocking ?pool:blocking_pool ~name:"sqlite.close" (fun () ->
      Connection.close conn)

let health_check ?blocking_pool conn =
  Eta.Effect.blocking ?pool:blocking_pool ~name:"sqlite.ping" (fun () ->
      Connection.ping conn)
  |> Eta.Effect.bind (fun healthy ->
         if healthy then
           Eta.Effect.unit
         else
           Eta.Effect.fail
             (`Eta_sql (Types.Pool_error "connection health check failed")))

let create ?blocking_pool ?default_timeout ?name ?(max_size = 10) ?max_idle
    ?idle_lifetime ?max_lifetime sqlite =
  Eta.Pool.create ?name ~kind:"sql" ~max_size ?max_idle ?idle_lifetime
    ?max_lifetime ~acquire:(acquire_connection ?blocking_pool sqlite)
    ~release:(release_connection ?blocking_pool)
    ~health_check:(health_check ?blocking_pool) ()
  |> Eta.Effect.map (fun pool ->
         Pool_runner { pool; blocking_pool; default_timeout })

let with_connection : type kind a.
    kind runner -> (Connection.t -> (a, error) Eta.Effect.t) -> (a, error) Eta.Effect.t =
 fun runner body ->
  match runner with
  | Pool_runner state -> Eta.Pool.with_resource state.pool body
  | Tx_runner state -> body state.conn

let blocking_pool : type kind. kind runner -> _ = function
  | Pool_runner state -> state.blocking_pool
  | Tx_runner state -> state.blocking_pool

let default_timeout : type kind. kind runner -> _ = function
  | Pool_runner state -> state.default_timeout
  | Tx_runner state -> state.default_timeout

let resolve_timeout runner override =
  match (override, default_timeout runner) with
  | Some timeout, _ -> timeout
  | None, Some timeout -> timeout
  | None, None ->
      invalid_arg
        "Eta_sql.Eta_pool: operation requires ?timeout or pool ?default_timeout"

let query ?timeout runner sql params =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.query"
        (fun () -> Connection.query conn sql params))

let select ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.select"
        (fun () -> Connection.select conn query))

let returning ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.returning"
        (fun () -> Connection.returning conn query))

let prepare_dynamic_statement conn sql params =
  Connection.if_open conn @@ fun () ->
  Connection.touch conn;
  let db = Connection.sqlite conn in
  match Types.sqlite_result (Sqlite.prepare_result db sql) with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match Types.bind_dynamic_values db stmt params with
      | Ok () -> Ok stmt
      | Result.Error err ->
          ignore (Sqlite.finalize stmt);
          Result.Error err)

let prepare_typed_statement conn (query : _ Compiled.select) =
  Connection.if_open conn @@ fun () ->
  Connection.touch conn;
  let db = Connection.sqlite conn in
  match Types.sqlite_result (Sqlite.prepare_result db query.sql) with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match
        Types.bind_dynamic_values db stmt
          (List.map Compiled.value_of_param query.params)
      with
      | Ok () -> Ok stmt
      | Result.Error err ->
          ignore (Sqlite.finalize stmt);
          Result.Error err)

let finalize_dynamic_statement conn stmt =
  Types.finalize_result (Connection.sqlite conn) stmt (Ok ())

let fetch_batch conn stmt batch_size =
  let db = Connection.sqlite conn in
  let rec loop remaining acc =
    if remaining = 0 then Ok (List.rev acc, false)
    else
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (remaining - 1) (Types.materialize_row stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then Ok (List.rev acc, true)
      else
        match Types.check_sqlite db ~operation:"query" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error err
  in
  loop batch_size []

let fetch_typed_batch conn stmt batch_size decode =
  let db = Connection.sqlite conn in
  let rec loop remaining acc =
    if remaining = 0 then Ok (List.rev acc, false)
    else
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (remaining - 1) (decode stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then Ok (List.rev acc, true)
      else
        match Types.check_sqlite db ~operation:"select" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error err
  in
  loop batch_size []

let fold ?timeout ?(batch_size = 1024) runner sql params ~init ~f =
  if batch_size <= 0 then invalid_arg "Eta_sql.Eta_pool.fold: batch_size must be > 0";
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      Eta.Effect.scoped
        (Eta.Effect.acquire_release
           ~acquire:
             (timed_blocking_result ?blocking_pool ~timeout ~conn
                ~name:"sqlite.fold.prepare" (fun () ->
                  prepare_dynamic_statement conn sql params))
           ~release:(fun stmt ->
             timed_blocking_result ?blocking_pool ~timeout ~conn
               ~name:"sqlite.fold.finalize" (fun () ->
                 finalize_dynamic_statement conn stmt))
        |> Eta.Effect.bind (fun stmt ->
               let rec loop acc =
                 timed_blocking_result ?blocking_pool ~timeout ~conn
                   ~name:"sqlite.fold.batch" (fun () ->
                     fetch_batch conn stmt batch_size)
                 |> Eta.Effect.bind (fun (rows, done_) ->
                        let acc = List.fold_left f acc rows in
                        if done_ then Eta.Effect.pure acc else loop acc)
               in
               loop init)))

let fold_select ?timeout ?(batch_size = 1024) runner (query : _ Compiled.select)
    ~init ~f =
  if batch_size <= 0 then
    invalid_arg "Eta_sql.Eta_pool.fold_select: batch_size must be > 0";
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      Eta.Effect.scoped
        (Eta.Effect.acquire_release
           ~acquire:
             (timed_blocking_result ?blocking_pool ~timeout ~conn
                ~name:"sqlite.select_fold.prepare" (fun () ->
                  prepare_typed_statement conn query))
           ~release:(fun stmt ->
             timed_blocking_result ?blocking_pool ~timeout ~conn
               ~name:"sqlite.select_fold.finalize" (fun () ->
                 finalize_dynamic_statement conn stmt))
        |> Eta.Effect.bind (fun stmt ->
               let rec loop acc =
                 timed_blocking_result ?blocking_pool ~timeout ~conn
                   ~name:"sqlite.select_fold.batch" (fun () ->
                     fetch_typed_batch conn stmt batch_size query.decode)
                 |> Eta.Effect.bind (fun (rows, done_) ->
                        let acc = List.fold_left f acc rows in
                        if done_ then Eta.Effect.pure acc else loop acc)
               in
               loop init)))

let execute ?timeout runner sql params =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.execute"
        (fun () -> Connection.execute conn sql params))

let execute_compiled ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn
        ~name:"sqlite.execute_compiled" (fun () ->
          Connection.execute_compiled conn query))

let execute_script ?timeout runner sql =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn
        ~name:"sqlite.execute_script" (fun () ->
          Connection.execute_script conn sql))

let run_schema ?timeout runner schema =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection runner (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.schema"
        (fun () -> Connection.run_schema conn schema))

let with_transaction ?timeout (Pool_runner state as runner) body =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = state.blocking_pool in
  Eta.Pool.with_resource state.pool (fun conn ->
      let committed = ref false in
      Eta.Effect.scoped
        (Eta.Effect.acquire_release
           ~acquire:
             (timed_blocking_result ?blocking_pool ~timeout ~conn
                ~name:"sqlite.begin_transaction" (fun () ->
                  Connection.begin_transaction conn))
           ~release:(fun () ->
             if !committed then Eta.Effect.unit
             else
               timed_blocking_result ?blocking_pool ~timeout ~conn
                 ~name:"sqlite.rollback" (fun () -> Connection.rollback conn))
        |> Eta.Effect.bind (fun () ->
               body
                 (Tx_runner { conn; blocking_pool; default_timeout = Some timeout })
               |> Eta.Effect.bind (fun value ->
                      timed_blocking_result ?blocking_pool ~timeout ~conn
                        ~name:"sqlite.commit" (fun () -> Connection.commit conn)
                      |> Eta.Effect.map (fun () ->
                             committed := true;
                             value)))))

let shutdown ?deadline (Pool_runner state) = Eta.Pool.shutdown ?deadline state.pool
let stats (Pool_runner state) = Eta.Pool.stats state.pool
