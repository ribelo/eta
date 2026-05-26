module Q = Sql
module S = Sqlite

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
  let active = column "active" Q.bool
end

module ActiveUsers = struct
  module T = Q.Table.Make (struct
    let name = "active_users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
end

module Eight = struct
  module T = Q.Table.Make (struct
    let name = "eight"
  end)

  include T

  let c1 = column "c1" Q.int
  let c2 = column "c2" Q.int
  let c3 = column "c3" Q.int
  let c4 = column "c4" Q.int
  let c5 = column "c5" Q.int
  let c6 = column "c6" Q.int
  let c7 = column "c7" Q.int
  let c8 = column "c8" Q.int
end

let sql_ok = function
  | Ok value -> value
  | Error err -> failwith (Q.show_error err)

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
           cause)

let setup_sync conn =
  Q.Connection.run_schema conn
    Q.Schema.(
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true Users.name;
          column ~not_null:true Users.active;
        ]
      |> compile)
  |> sql_ok;
  List.iter
    (fun (id, name, active) ->
      ignore
        (Q.Connection.execute_compiled conn
           Q.Insert.(
             into Users.table
             |> value Users.id id
             |> value Users.name name
             |> value Users.active active
             |> compile)
        |> sql_ok))
    [ (1, "Ada", true); (2, "Grace", true); (3, "Inactive", false) ]

let run_sync_surface () =
  let db = Q.Connection.create (S.memory_config ()) |> sql_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close db)
    (fun () ->
      setup_sync db;
      let active_ids =
        Q.Select.(
          from Users.table Q.Projection.(one Users.id)
          |> where Q.Expr.(eq Users.active true)
          |> compile)
      in
      let subquery_names =
        Q.Select.(
          from Users.table Q.Projection.(one Users.name)
          |> where Q.Expr.(in_select Users.id active_ids)
          |> order_by Users.id
          |> compile
          |> Q.Connection.select db
          |> sql_ok)
      in
      let active_rows =
        Q.Select.(
          from Users.table Q.Projection.(t2 Users.id Users.name)
          |> where Q.Expr.(eq Users.active true)
          |> compile)
      in
      let cte_rows =
        Q.Select.(
          from ActiveUsers.table Q.Projection.(t2 ActiveUsers.id ActiveUsers.name)
          |> with_cte ~name:"active_users" active_rows
          |> order_by ActiveUsers.id
          |> compile
          |> Q.Connection.select db
          |> sql_ok)
      in
      let row_numbers =
        Q.Select.(
          from Users.table Q.Projection.(row_number ~order_by:Users.id ())
          |> order_by Users.id
          |> compile
          |> Q.Connection.select db
          |> sql_ok)
      in
      let grouped =
        Q.Select.(
          from Users.table Q.Projection.(count ())
          |> group_by Users.active
          |> having Q.Expr.(count_ge 2)
          |> compile
          |> Q.Connection.select db
          |> sql_ok)
      in
      Printf.printf "surface_subquery=%d cte=%d window_last=%d grouped=%d\n%!"
        (List.length subquery_names)
        (List.length cte_rows)
        (match List.rev row_numbers with last :: _ -> last | [] -> 0)
        (match grouped with count :: _ -> count | [] -> 0))

let run_eta_surface env =
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"query-api-surface"
      {
        max_threads = 2;
        max_queued = 16;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let create =
    Q.Schema.(
      create_table Eight.table
        [
          column ~primary_key:true Eight.c1;
          column Eight.c2;
          column Eight.c3;
          column Eight.c4;
          column Eight.c5;
          column Eight.c6;
          column Eight.c7;
          column Eight.c8;
        ]
      |> compile)
  in
  let insert base =
    Q.Insert.(
      into Eight.table
      |> value Eight.c1 base
      |> value Eight.c2 (base + 1)
      |> value Eight.c3 (base + 2)
      |> value Eight.c4 (base + 3)
      |> value Eight.c5 (base + 4)
      |> value Eight.c6 (base + 5)
      |> value Eight.c7 (base + 6)
      |> value Eight.c8 (base + 7)
      |> compile)
  in
  let upsert =
    Q.Insert.(
      into Eight.table
      |> value Eight.c1 10
      |> value Eight.c2 100
      |> on_conflict_update [ Eight.c1 ] ~set:[ Eight.c2 ]
      |> returning Q.Projection.(t2 Eight.c1 Eight.c2))
  in
  let select_eight =
    Q.Select.(
      from Eight.table
        Q.Projection.(
          t8 Eight.c1 Eight.c2 Eight.c3 Eight.c4 Eight.c5 Eight.c6 Eight.c7
            Eight.c8)
      |> order_by Eight.c1
      |> compile)
  in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.run_schema ~blocking_pool ~timeout pool create
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 10))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.returning ~blocking_pool ~timeout pool upsert)
           |> Eta.Effect.bind (fun returning ->
                  Q.Eta_pool.with_transaction ~blocking_pool ~timeout pool
                    (fun tx ->
                      Q.Eta_pool.tx_execute_compiled ~blocking_pool ~timeout tx
                        (insert 20)
                      |> Eta.Effect.bind (fun _ ->
                             Q.Eta_pool.tx_fold_select ~blocking_pool ~timeout
                               ~batch_size:1 tx select_eight ~init:0
                               ~f:(fun acc (c1, _, _, _, _, _, _, c8) ->
                                 acc + c1 + c8)))
                  |> Eta.Effect.map (fun tx_sum -> (returning, tx_sum)))
           |> Eta.Effect.bind (fun (returning, tx_sum) ->
                  Q.Eta_pool.shutdown pool
                  |> Eta.Effect.bind (fun () ->
                         Eta.Effect.Blocking.Pool.shutdown blocking_pool
                         |> Eta.Effect.map (fun () -> (returning, tx_sum)))))
  in
  let returning, tx_sum = run_ok rt program in
  Printf.printf "surface_returning=%d upsert_c2=%d tx_eight_sum=%d\n%!"
    (List.length returning)
    (match returning with [ (_, c2) ] -> c2 | _ -> 0)
    tx_sum

let () =
  run_sync_surface ();
  Eio_main.run run_eta_surface
