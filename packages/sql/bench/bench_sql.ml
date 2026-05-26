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
  let nickname = column "nickname" (Q.nullable Q.text)
end

let expect_ok = function
  | Ok value -> value
  | Error err -> failwith (Q.show_error err)

let repeat n f =
  for i = 1 to n do
    f i
  done

let select_query () =
  Q.Select.(
    from Users.table Q.Projection.(t3 Users.id Users.name Users.nickname)
    |> where Q.Expr.(and_ (gt Users.id 10) (like Users.name "A%"))
    |> order_by ~desc:true Users.name
    |> limit 10)

let render_select () =
  ignore (Q.Select.to_sql (select_query ()))

let compile_insert () =
  ignore
    Q.Insert.(
      into Users.table
      |> value Users.name "Ada"
      |> value Users.active true
      |> value Users.nickname None
      |> compile)

let render_schema () =
  ignore
    Q.Schema.(
      create_table Users.table
        [
          column ~primary_key:true Users.id;
          column ~not_null:true Users.name;
          column ~not_null:true Users.active;
          column Users.nickname;
        ]
      |> to_sql)

let sqlite_roundtrip rows =
  let conn = Q.Connection.create (S.memory_config ()) |> expect_ok in
  Fun.protect
    ~finally:(fun () -> Q.Connection.close conn)
    (fun () ->
      Q.Connection.run_schema conn
        Q.Schema.(
          create_table Users.table
            [
              column ~primary_key:true Users.id;
              column ~not_null:true Users.name;
              column ~not_null:true Users.active;
              column Users.nickname;
            ]
          |> compile)
      |> expect_ok;
      repeat rows (fun i ->
          ignore
            (Q.Connection.execute_compiled conn
               Q.Insert.(
                 into Users.table
                 |> value Users.name ("user-" ^ string_of_int i)
                 |> value Users.active (i land 1 = 0)
                 |> value Users.nickname None
                 |> compile)
            |> expect_ok));
      ignore
        (Q.Connection.select conn (Q.Select.compile (select_query ()))
        |> expect_ok))

let workloads =
  let item name run =
    { Bench_lib.name = "sql." ^ name; run; samples = None }
  in
  [
    item "select.render.100k" (fun () -> repeat 100_000 (fun _ -> render_select ()));
    item "insert.compile.100k" (fun () -> repeat 100_000 (fun _ -> compile_insert ()));
    item "schema.render.100k" (fun () -> repeat 100_000 (fun _ -> render_schema ()));
    item "sqlite.memory_roundtrip.100" (fun () -> sqlite_roundtrip 100);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
