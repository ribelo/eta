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

let setup db =
  S.exec db
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL)";
  S.exec db "INSERT INTO users (name, active) VALUES ('Ada', 1)";
  S.exec db "INSERT INTO users (name, active) VALUES ('Grace', 1)";
  S.exec db "INSERT INTO users (name, active) VALUES ('Inactive', 0)"

let sql_ok = function
  | Ok value -> value
  | Error err -> failwith (Q.show_error err)

let setup_conn conn =
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
    (fun (name, active) ->
      ignore
        (Q.Connection.execute_compiled conn
           Q.Insert.(
             into Users.table
             |> value Users.name name
             |> value Users.active active
             |> compile)
        |> sql_ok))
    [ ("Ada", true); ("Grace", true); ("Inactive", false) ]

let run_builder db =
  let rows =
    Q.Select.(
      from Users.table Q.Projection.(t2 Users.id Users.name)
      |> where Q.Expr.(eq Users.active true)
      |> order_by Users.id
      |> compile
      |> Q.Connection.select db
      |> sql_ok)
  in
  let updated =
    Q.Update.(
      table Users.table
      |> set Users.name "Ada Lovelace"
      |> where Q.Expr.(eq Users.id 1)
      |> compile
      |> Q.Connection.execute_compiled db
      |> sql_ok)
  in
  let deleted =
    Q.Connection.execute_compiled db
      Q.Delete.(
        from Users.table
        |> where Q.Expr.(eq Users.active false)
        |> compile)
    |> sql_ok
  in
  Printf.printf "builder_rows=%d first=%s updated=%d deleted=%d\n%!"
    (List.length rows)
    (match rows with [] -> "none" | (_, name) :: _ -> name)
    updated deleted

module Raw_request = struct
  type ('params, 'row) t = {
    sql : string;
    bind : S.stmt -> 'params -> unit;
    decode : S.stmt -> 'row;
  }

  let check db operation rc =
    match S.check db ~operation rc with
    | Ok () -> ()
    | Error err -> raise (S.Error err)

  let all db request params =
    let stmt = S.prepare db request.sql in
    Fun.protect
      ~finally:(fun () -> ignore (S.finalize stmt))
      (fun () ->
        request.bind stmt params;
        let rec loop acc =
          let rc = S.step stmt in
          if S.rc_equal rc S.row then
            loop (request.decode stmt :: acc)
          else if S.rc_equal rc S.done_ then
            List.rev acc
          else (
            check db "raw request" rc;
            assert false)
        in
        loop [])
end

let run_raw_request db =
  let request =
    Raw_request.
      {
        sql = "SELECT id, name FROM users WHERE active = ? ORDER BY id";
        bind =
          (fun stmt active ->
            check db "raw bind" (S.bind_int stmt 1 (if active then 1 else 0)));
        decode = (fun stmt -> (S.column_int stmt 0, S.column_text stmt 1));
      }
  in
  let rows = Raw_request.all db request true in
  Printf.printf "raw_rows=%d first=%s\n%!"
    (List.length rows)
    (match rows with [] -> "none" | (_, name) :: _ -> name)

module Ppx_generated_shape = struct
  let user_name_by_id db id =
    let stmt = S.prepare db "SELECT name FROM users WHERE id = ?" in
    Fun.protect
      ~finally:(fun () -> ignore (S.finalize stmt))
      (fun () ->
        S.check_exn db ~operation:"generated bind" (S.bind_int stmt 1 id);
        match S.step stmt with
        | rc when S.rc_equal rc S.row ->
            let name = S.column_text stmt 0 in
            let drain_rc = S.step stmt in
            if not (S.rc_equal drain_rc S.done_) then
              S.check_exn db ~operation:"generated drain" drain_rc;
            Some name
        | rc when S.rc_equal rc S.done_ -> None
        | rc ->
            S.check_exn db ~operation:"generated query" rc;
            None)
end

let () =
  let builder_db = Q.Connection.create (S.memory_config ()) |> sql_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close builder_db)
    (fun () ->
      setup_conn builder_db;
      run_builder builder_db);
  let raw_db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close raw_db))
    (fun () ->
      setup raw_db;
      run_raw_request raw_db;
      match Ppx_generated_shape.user_name_by_id raw_db 2 with
      | None -> Printf.printf "generated_name=none\n%!"
      | Some name -> Printf.printf "generated_name=%s\n%!" name)
