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

module Driver_blocking = Eta_sql_driver.Make (struct
  type driver_error = Types.sql_error
  type nonrec error = error

  let map_error err = `Eta_sql err

  let detach_started_error =
    `Eta_sql
      (Types.Pool_error
         "Eta_sql.Pool: Detach_started blocking pools cannot be used with leased connections")
end)

let blocking_result = Driver_blocking.blocking_result

let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
  let interrupt () = Sqlite.interrupt (Connection.sqlite conn) in
  Driver_blocking.leased_blocking_result_timeout ?blocking_pool ~name
    ~on_cancel:interrupt ~timeout ~on_timeout:`Timeout f

let deadline_of_timeout timeout =
  Unix.gettimeofday () +. Eta.Duration.to_seconds_float timeout

let remaining_timeout deadline =
  let remaining_ms =
    int_of_float (ceil ((deadline -. Unix.gettimeofday ()) *. 1000.0))
  in
  if remaining_ms <= 0 then None else Some (Eta.Duration.ms remaining_ms)

let timed_blocking_result_until ?blocking_pool ~deadline ~conn ~name f =
  match remaining_timeout deadline with
  | None -> Eta.Effect.fail `Timeout
  | Some timeout -> timed_blocking_result ?blocking_pool ~timeout ~conn ~name f

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

let reject_runner_detach_started : type kind. kind runner -> (unit, error) Eta.Effect.t =
 fun runner ->
  match runner with
  | Pool_runner state ->
      Driver_blocking.reject_detach_started_blocking_pool state.blocking_pool
  | Tx_runner state ->
      Driver_blocking.reject_detach_started_blocking_pool state.blocking_pool

let with_connection_timeout : type kind a.
    kind runner ->
    timeout:Eta.Duration.t ->
    (Connection.t -> (a, error) Eta.Effect.t) ->
    (a, error) Eta.Effect.t =
 fun runner ~timeout body ->
  reject_runner_detach_started runner |> Eta.Effect.bind (fun () ->
  match runner with
  | Pool_runner state ->
      Eta.Pool.with_resource state.pool (fun conn ->
          Eta.Effect.scoped
            (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
               ~release:(fun () ->
                 timed_blocking_result ?blocking_pool:state.blocking_pool ~timeout
                   ~conn ~name:"sqlite.ensure_autocommit" (fun () ->
                     Connection.ensure_autocommit conn)
                 |> Eta.Effect.catch (fun err ->
                        Eta.Effect.blocking ?pool:state.blocking_pool
                          ~name:"sqlite.close_dirty" (fun () ->
                            Connection.close conn)
                        |> Eta.Effect.bind (fun () -> Eta.Effect.fail err)))
            |> Eta.Effect.bind (fun () -> body conn)))
  | Tx_runner state -> body state.conn)

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
        "Eta_sql.Pool: operation requires ?timeout or pool ?default_timeout"

let raw_with_connection runner body =
  let timeout = resolve_timeout runner None in
  with_connection_timeout runner ~timeout body

let raw_query ?timeout runner sql params =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.query"
        (fun () -> Connection.Raw.query conn sql params))

let typed_select ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.select"
        (fun () -> Connection.Typed.select conn query))

let typed_returning ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.returning"
        (fun () -> Connection.Typed.returning conn query))

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
  match Types.sqlite_result (Sqlite.prepare_result db (Compiled.select_sql query)) with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match
        Types.bind_dynamic_values db stmt
          (Compiled.select_params query)
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
        | Ok () -> Types.unexpected_sqlite_step ~operation:"query" rc
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
        | Ok () -> Types.unexpected_sqlite_step ~operation:"select" rc
        | Result.Error err -> Result.Error err
  in
  loop batch_size []

let raw_fold ?timeout ?(batch_size = 1024) runner sql params ~init ~f =
  if batch_size <= 0 then
    invalid_arg "Eta_sql.Pool.Raw.fold: batch_size must be > 0";
  let timeout = resolve_timeout runner timeout in
  let deadline = deadline_of_timeout timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      Eta.Effect.scoped
        (Eta.Effect.acquire_release
           ~acquire:
             (timed_blocking_result_until ?blocking_pool ~deadline ~conn
                ~name:"sqlite.fold.prepare" (fun () ->
                  prepare_dynamic_statement conn sql params))
           ~release:(fun stmt ->
             timed_blocking_result ?blocking_pool ~timeout ~conn
               ~name:"sqlite.fold.finalize" (fun () ->
                 finalize_dynamic_statement conn stmt))
        |> Eta.Effect.bind (fun stmt ->
               let rec loop acc =
                 timed_blocking_result_until ?blocking_pool ~deadline ~conn
                   ~name:"sqlite.fold.batch" (fun () ->
                     fetch_batch conn stmt batch_size)
                 |> Eta.Effect.bind (fun (rows, done_) ->
                        let acc = List.fold_left f acc rows in
                        if done_ then Eta.Effect.pure acc else loop acc)
               in
               loop init)))

let typed_fold_select ?timeout ?(batch_size = 1024) runner (query : _ Compiled.select)
    ~init ~f =
  if batch_size <= 0 then
    invalid_arg "Eta_sql.Pool.Typed.fold_select: batch_size must be > 0";
  let timeout = resolve_timeout runner timeout in
  let deadline = deadline_of_timeout timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      Eta.Effect.scoped
        (Eta.Effect.acquire_release
           ~acquire:
             (timed_blocking_result_until ?blocking_pool ~deadline ~conn
                ~name:"sqlite.select_fold.prepare" (fun () ->
                  prepare_typed_statement conn query))
           ~release:(fun stmt ->
             timed_blocking_result ?blocking_pool ~timeout ~conn
               ~name:"sqlite.select_fold.finalize" (fun () ->
                 finalize_dynamic_statement conn stmt))
        |> Eta.Effect.bind (fun stmt ->
               let rec loop acc =
                 timed_blocking_result_until ?blocking_pool ~deadline ~conn
                   ~name:"sqlite.select_fold.batch" (fun () ->
                     fetch_typed_batch conn stmt batch_size
                       (Compiled.select_decode query))
                 |> Eta.Effect.bind (fun (rows, done_) ->
                        let acc = List.fold_left f acc rows in
                        if done_ then Eta.Effect.pure acc else loop acc)
               in
               loop init)))

let raw_execute ?timeout runner sql params =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.execute"
        (fun () -> Connection.Raw.execute conn sql params))

let typed_execute_compiled ?timeout runner query =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn
        ~name:"sqlite.execute_compiled" (fun () ->
          Connection.Typed.execute_compiled conn query))

let raw_execute_script ?timeout runner sql =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn
        ~name:"sqlite.execute_script" (fun () ->
          Connection.Raw.execute_script conn sql))

let typed_run_schema ?timeout runner schema =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = blocking_pool runner in
  with_connection_timeout runner ~timeout (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.schema"
        (fun () -> Connection.Typed.run_schema conn schema))

module Typed = struct
  let select = typed_select
  let returning = typed_returning
  let fold_select = typed_fold_select
  let execute_compiled = typed_execute_compiled
  let run_schema = typed_run_schema
end

module Raw = struct
  let query = raw_query
  let fold = raw_fold
  let execute = raw_execute
  let execute_script = raw_execute_script
  let with_connection = raw_with_connection
end

let with_transaction ?timeout (Pool_runner state as runner) body =
  let timeout = resolve_timeout runner timeout in
  let blocking_pool = state.blocking_pool in
  Driver_blocking.reject_detach_started_blocking_pool blocking_pool
  |> Eta.Effect.bind (fun () ->
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
                        ~name:"sqlite.rollback" (fun () ->
                          Connection.rollback conn)
                      |> Eta.Effect.catch (fun err ->
                             Eta.Effect.blocking ?pool:blocking_pool
                               ~name:"sqlite.close_dirty" (fun () ->
                                 Connection.close conn)
                             |> Eta.Effect.bind (fun () -> Eta.Effect.fail err)))
             |> Eta.Effect.bind (fun () ->
                    body
                      (Tx_runner
                         { conn; blocking_pool; default_timeout = Some timeout })
                    |> Eta.Effect.bind (fun value ->
                           timed_blocking_result ?blocking_pool ~timeout ~conn
                             ~name:"sqlite.commit" (fun () ->
                               Connection.commit conn)
                           |> Eta.Effect.map (fun () ->
                                  committed := true;
                                  value))))))

let shutdown ?deadline (Pool_runner state) = Eta.Pool.shutdown ?deadline state.pool
let stats (Pool_runner state) = Eta.Pool.stats state.pool
