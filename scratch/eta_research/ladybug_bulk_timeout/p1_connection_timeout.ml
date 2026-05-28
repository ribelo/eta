module L = Eta_ladybug

let failf fmt = Format.kasprintf failwith fmt

let ok = function
  | Ok value -> value
  | Error err -> failf "%a" L.pp_error err

let setup conn =
  L.Connection.exec conn "CREATE NODE TABLE N(id INT64, PRIMARY KEY(id))" |> ok;
  L.Connection.exec conn "UNWIND range(1, 20000) AS i CREATE (:N {id: i})" |> ok

let long_query =
  L.Query.raw
    ~cypher:"MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id) AS s"
    ~decode:L.Decode.(int "s")
    ()

let count_return1 conn =
  let query = L.Query.raw ~cypher:"RETURN 1 AS one" ~decode:L.Decode.(int "one") () in
  match L.Connection.query conn query |> ok with
  | [ 1L ] -> true
  | _ -> false

let () =
  match L.available () with
  | Error (L.Library_unavailable message) ->
      Printf.printf "ladybug_available=false message=%S\n" message
  | Error err -> failf "%a" L.pp_error err
  | Ok () ->
      Eio_main.run @@ fun stdenv ->
      Eio.Switch.run @@ fun sw ->
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
      let db = L.Database.open_memory () |> ok in
      Fun.protect
        ~finally:(fun () -> ignore (L.Database.close db))
        (fun () ->
          let conn = L.Connection.connect db |> ok in
          Fun.protect
            ~finally:(fun () -> ignore (L.Connection.close conn))
            (fun () ->
              setup conn;
              let start = Unix.gettimeofday () in
              let result =
                L.Connection.query_with_timeout ~timeout:(Eta.Duration.ms 100) conn
                  long_query
                |> Eta.Runtime.run rt
              in
              let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
              let reusable = count_return1 conn in
              Printf.printf "ladybug_available=true\n";
              Printf.printf "timeout_ms=100\n";
              Printf.printf "elapsed_ms=%.3f\n" elapsed_ms;
              Printf.printf "connection_reusable=%b\n" reusable;
              match result with
              | Eta.Exit.Error (Eta.Cause.Fail L.Connection.Timeout) ->
                  Printf.printf "result=timeout\n"
              | Eta.Exit.Error (Eta.Cause.Fail (L.Connection.Ladybug err)) ->
                  Printf.printf "result=ladybug_error:%s\n" (L.show_error err)
              | Eta.Exit.Error cause ->
                  let rendered =
                    Format.asprintf "%a"
                      (Eta.Cause.pp (fun fmt -> function
                         | L.Connection.Timeout ->
                             Format.pp_print_string fmt "Timeout"
                         | L.Connection.Ladybug err -> L.pp_error fmt err))
                      cause
                  in
                  Printf.printf "result=unexpected_error:%s\n" rendered
              | Eta.Exit.Ok rows ->
                  Printf.printf "result=ok rows=%d\n" (List.length rows)))
