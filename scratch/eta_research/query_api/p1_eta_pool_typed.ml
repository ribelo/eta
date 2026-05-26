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

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
           cause)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"query-api-typed-eta"
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
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true Users.name;
          column ~not_null:true Users.active;
        ]
      |> compile)
  in
  let insert id name active =
    Q.Insert.(
      into Users.table
      |> value Users.id id
      |> value Users.name name
      |> value Users.active active
      |> compile)
  in
  let active_users =
    Q.Select.(
      from Users.table Q.Projection.(t2 Users.id Users.name)
      |> where Q.Expr.(eq Users.active true)
      |> order_by Users.id
      |> compile)
  in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.run_schema ~blocking_pool ~timeout pool create
           |> Eta.Effect.bind (fun () ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 1 "Ada" true))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 2 "Grace" true))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.execute_compiled ~blocking_pool ~timeout pool
                    (insert 3 "Inactive" false))
           |> Eta.Effect.bind (fun _ ->
                  Q.Eta_pool.select ~blocking_pool ~timeout pool active_users)
           |> Eta.Effect.bind (fun rows ->
                  Q.Eta_pool.fold_select ~blocking_pool ~timeout ~batch_size:1 pool
                    active_users ~init:0 ~f:(fun acc (id, _) -> acc + id)
                  |> Eta.Effect.bind (fun sum ->
                         Q.Eta_pool.shutdown pool
                         |> Eta.Effect.bind (fun () ->
                                Eta.Effect.Blocking.Pool.shutdown blocking_pool
                                |> Eta.Effect.map (fun () -> (rows, sum))))))
  in
  let rows, sum = run_ok rt program in
  Printf.printf "typed_eta_rows=%d first=%s sum=%d sql=%s params=%d\n%!"
    (List.length rows)
    (match rows with [] -> "none" | (_, name) :: _ -> name)
    sum
    (Q.Compiled.select_sql active_users)
    (List.length (Q.Compiled.select_params active_users))

