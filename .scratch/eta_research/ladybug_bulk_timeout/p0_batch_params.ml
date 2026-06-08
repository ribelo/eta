module L = Eta_ladybug

let failf fmt = Format.kasprintf failwith fmt

let ok = function
  | Ok value -> value
  | Error err -> failf "%a" L.pp_error err

let timed f =
  let start = Unix.gettimeofday () in
  let value = f () in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  (value, elapsed_ms)

let count conn label =
  let query =
    L.Query.raw
      ~cypher:("MATCH (p:" ^ label ^ ") RETURN count(p) AS c")
      ~decode:L.Decode.(int "c")
      ()
  in
  match L.Connection.query conn query |> ok with
  | [ value ] -> value
  | values -> failf "expected one count row for %s, got %d" label (List.length values)

let setup conn label =
  L.Connection.exec conn
    ("CREATE NODE TABLE " ^ label
   ^ "(id INT64, name STRING, active BOOL, PRIMARY KEY(id))")
  |> ok

let per_row_insert conn n =
  setup conn "PerRowPerson";
  for i = 1 to n do
    L.Connection.exec
      ~params:
        [
          L.Param.int "id" (Int64.of_int i);
          L.Param.string "name" ("person-" ^ string_of_int i);
          L.Param.bool "active" (i mod 2 = 0);
        ]
      conn
      "CREATE (:PerRowPerson {id: $id, name: $name, active: $active})"
    |> ok
  done;
  count conn "PerRowPerson"

let rows n =
  List.init n (fun index ->
      let i = index + 1 in
      [
        ("id", L.Value.Int (Int64.of_int i));
        ("name", L.Value.String ("person-" ^ string_of_int i));
        ("active", L.Value.Bool (i mod 2 = 0));
      ])

let run_batch_candidate conn ~label ~cypher n =
  setup conn label;
  match L.Connection.exec ~params:[ L.Param.rows "rows" (rows n) ] conn cypher with
  | Error err -> Error (L.show_error err)
  | Ok () -> Ok (count conn label)

let batch_candidates n conn =
  [
    ( "row_dot",
      "BatchDotPerson",
      "UNWIND $rows AS row CREATE (:BatchDotPerson {id: row.id, name: row.name, active: row.active})"
    );
    ( "row_subscript",
      "BatchSubscriptPerson",
      "UNWIND $rows AS row CREATE (:BatchSubscriptPerson {id: row['id'], name: row['name'], active: row['active']})"
    );
    ( "row_set",
      "BatchSetPerson",
      "UNWIND $rows AS row CREATE (p:BatchSetPerson) SET p.id = row.id, p.name = row.name, p.active = row.active"
    );
  ]
  |> List.map (fun (name, label, cypher) ->
         let result, elapsed_ms =
           timed (fun () -> run_batch_candidate conn ~label ~cypher n)
         in
         (name, result, elapsed_ms))

let () =
  match L.available () with
  | Error (L.Library_unavailable message) ->
      Printf.printf "ladybug_available=false message=%S\n" message
  | Error err -> failf "%a" L.pp_error err
  | Ok () ->
      let n = 1_000 in
      let db = L.Database.open_memory () |> ok in
      Fun.protect
        ~finally:(fun () -> ignore (L.Database.close db))
        (fun () ->
          let conn = L.Connection.connect db |> ok in
          Fun.protect
            ~finally:(fun () -> ignore (L.Connection.close conn))
            (fun () ->
              let per_row_count, per_row_ms = timed (fun () -> per_row_insert conn n) in
              Printf.printf "ladybug_available=true\n";
              Printf.printf "rows=%d\n" n;
              Printf.printf "per_row.count=%Ld\n" per_row_count;
              Printf.printf "per_row.ms=%.3f\n" per_row_ms;
              batch_candidates n conn
              |> List.iter (fun (name, result, elapsed_ms) ->
                     match result with
                     | Ok count ->
                         Printf.printf "%s.status=pass\n" name;
                         Printf.printf "%s.count=%Ld\n" name count;
                         Printf.printf "%s.ms=%.3f\n" name elapsed_ms;
                         Printf.printf "%s.speedup_vs_per_row=%.2f\n" name
                           (per_row_ms /. max elapsed_ms 0.000001)
                     | Error message ->
                         Printf.printf "%s.status=fail\n" name;
                         Printf.printf "%s.error=%S\n" name message)))
