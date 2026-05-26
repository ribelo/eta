module Q = Sql
module S = Sqlite

module Manual_users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T

  let id = column "id" Q.int
  let name = column "name" Q.text
  let active = column "active" Q.bool
end

[%%eta.sql.table
type users = {
  id : int [@primary_key];
  name : string [@not_null];
  active : bool [@not_null];
}]

[%%eta.sql.table
type teams = {
  team_pk : int [@primary_key];
  team_name : string [@unique];
}]

[%%eta.sql.table
type memberships = {
  membership_pk : int [@primary_key];
  membership_team : int [@references Teams.team_pk] [@on_delete "CASCADE"];
  membership_role : string [@not_null] [@default "'member'"];
}]

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<sql>"))
           cause)

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    Eta.Effect.Blocking.Pool.create ~name:"query-api-schema-ppx"
      {
        max_threads = 2;
        max_queued = 16;
        queue_policy = Eta.Effect.Blocking.Pool.Wait;
        shutdown_policy = Eta.Effect.Blocking.Pool.Drain;
      }
  in
  let timeout = Eta.Duration.ms 250 in
  let manual_sql =
    Q.Select.(
      from Manual_users.table
        Q.Projection.(t3 Manual_users.id Manual_users.name Manual_users.active)
      |> where Q.Expr.(eq Manual_users.active true)
      |> order_by Manual_users.id
      |> compile
      |> Q.Compiled.select_sql)
  in
  let ppx_select =
    Q.Select.(
      from Users.table Users.all
      |> where Q.Expr.(eq Users.active true)
      |> order_by Users.id
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
  let metadata_sql = Q.Schema.to_sql Memberships.schema in
  let metadata_ok =
    contains metadata_sql "\"membership_pk\" INTEGER PRIMARY KEY"
    && contains metadata_sql "REFERENCES \"teams\" (\"team_pk\")"
    && contains metadata_sql "ON DELETE CASCADE"
    && contains metadata_sql "\"membership_role\" TEXT NOT NULL DEFAULT 'member'"
  in
  let program =
    Q.Eta_pool.create ~blocking_pool ~max_size:1 (S.memory_config ())
    |> Eta.Effect.bind (fun pool ->
           Q.Eta_pool.run_schema ~blocking_pool ~timeout pool
             Q.Schema.(Users.schema |> compile)
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
                  Q.Eta_pool.select ~blocking_pool ~timeout pool ppx_select)
           |> Eta.Effect.bind (fun rows ->
                  Q.Eta_pool.shutdown pool
                  |> Eta.Effect.bind (fun () ->
                         Eta.Effect.Blocking.Pool.shutdown blocking_pool
                         |> Eta.Effect.map (fun () -> rows))))
  in
  let rows = run_ok rt program in
  let first =
    match rows with
    | first :: _ -> first
    | [] -> failwith "expected rows"
  in
  let sql_equal = String.equal manual_sql (Q.Compiled.select_sql ppx_select) in
  if not sql_equal then failwith "PPX select SQL drifted from manual table SQL";
  if not metadata_ok then failwith "PPX schema metadata SQL drifted";
  Printf.printf "schema_ppx_rows=%d first=%s active=%b sql_equal=%b sql=%s\n%!"
    (List.length rows) first.name first.active sql_equal
    (Q.Compiled.select_sql ppx_select);
  Printf.printf "schema_ppx_metadata=%b sql=%s\n%!"
    metadata_ok metadata_sql
