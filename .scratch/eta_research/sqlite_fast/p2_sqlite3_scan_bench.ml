module Rc = Sqlite3.Rc

let default_rows = 50_000

let rows =
  if Array.length Sys.argv > 1 then
    int_of_string Sys.argv.(1)
  else
    default_rows

let int_rows_sink = ref []
let pair_rows_sink = ref []

let clear_sinks () =
  int_rows_sink := [];
  pair_rows_sink := []

let expect_rc label expected actual =
  if actual <> expected then
    failwith
      (label ^ ": expected " ^ Rc.to_string expected ^ ", got " ^ Rc.to_string actual)

let expect_ok label rc = expect_rc label Rc.OK rc
let expect_done label rc = expect_rc label Rc.DONE rc
let expect_row label rc = expect_rc label Rc.ROW rc

let exec db sql =
  Sqlite3.exec db sql
  |> expect_ok ("exec " ^ sql)

let setup rows =
  let db = Sqlite3.db_open ":memory:" in
  exec db "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)";
  exec db "BEGIN";
  let insert = Sqlite3.prepare db "INSERT INTO items (id, name) VALUES (?, ?)" in
  for i = 1 to rows do
    expect_ok "bind insert id" (Sqlite3.bind_int insert 1 i);
    expect_ok "bind insert name" (Sqlite3.bind_text insert 2 ("name-" ^ string_of_int i));
    expect_done "insert row" (Sqlite3.step insert);
    expect_ok "reset insert" (Sqlite3.reset insert);
    expect_ok "clear insert" (Sqlite3.clear_bindings insert)
  done;
  expect_ok "finalize insert" (Sqlite3.finalize insert);
  exec db "COMMIT";
  db

let direct_int_sum db =
  let stmt = Sqlite3.prepare db "SELECT id FROM items ORDER BY id" in
  let total = ref 0 in
  let count = ref 0 in
  let running = ref true in
  while !running do
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then (
      total := !total + Sqlite3.column_int stmt 0;
      incr count
    ) else if rc = Rc.DONE then
      running := false
    else
      failwith ("sqlite3_direct_int_sum: " ^ Rc.to_string rc)
  done;
  expect_ok "finalize direct_int_sum" (Sqlite3.finalize stmt);
  !total + !count

let eager_int_rows db =
  let stmt = Sqlite3.prepare db "SELECT id FROM items ORDER BY id" in
  let rows = ref [] in
  let running = ref true in
  while !running do
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then
      rows := Sqlite3.column_int stmt 0 :: !rows
    else if rc = Rc.DONE then
      running := false
    else
      failwith ("sqlite3_eager_int_rows: " ^ Rc.to_string rc)
  done;
  expect_ok "finalize eager_int_rows" (Sqlite3.finalize stmt);
  let materialized = !rows in
  int_rows_sink := materialized;
  List.fold_left ( + ) 0 materialized

let direct_pair_sum db =
  let stmt = Sqlite3.prepare db "SELECT id, name FROM items ORDER BY id" in
  let total = ref 0 in
  let running = ref true in
  while !running do
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then (
      let id = Sqlite3.column_int stmt 0 in
      let name = Sqlite3.column_text stmt 1 in
      total := !total + id + String.length name
    ) else if rc = Rc.DONE then
      running := false
    else
      failwith ("sqlite3_direct_pair_sum: " ^ Rc.to_string rc)
  done;
  expect_ok "finalize direct_pair_sum" (Sqlite3.finalize stmt);
  !total

let eager_pair_rows db =
  let stmt = Sqlite3.prepare db "SELECT id, name FROM items ORDER BY id" in
  let rows = ref [] in
  let running = ref true in
  while !running do
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then
      rows := (Sqlite3.column_int stmt 0, Sqlite3.column_text stmt 1) :: !rows
    else if rc = Rc.DONE then
      running := false
    else
      failwith ("sqlite3_eager_pair_rows: " ^ Rc.to_string rc)
  done;
  expect_ok "finalize eager_pair_rows" (Sqlite3.finalize stmt);
  let materialized = !rows in
  pair_rows_sink := materialized;
  List.fold_left (fun acc (id, name) -> acc + id + String.length name) 0 materialized

let measure name f =
  clear_sinks ();
  Gc.compact ();
  let before = Gc.quick_stat () in
  let before_bytes = Gc.allocated_bytes () in
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  let after_bytes = Gc.allocated_bytes () in
  let after = Gc.quick_stat () in
  Printf.printf
    "%s rows=%d result=%d wall_ms=%.3f allocated_bytes=%.0f minor_words=%.0f promoted_words=%.0f major_words=%.0f minor_collections=%d major_collections=%d\n%!"
    name
    rows
    result
    ((t1 -. t0) *. 1000.0)
    (after_bytes -. before_bytes)
    (after.minor_words -. before.minor_words)
    (after.promoted_words -. before.promoted_words)
    (after.major_words -. before.major_words)
    (after.minor_collections - before.minor_collections)
    (after.major_collections - before.major_collections);
  clear_sinks ()

let () =
  let db = setup rows in
  Fun.protect
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then
        failwith "sqlite3 close failed")
    (fun () ->
      measure "sqlite3_direct_int_sum" (fun () -> direct_int_sum db);
      measure "sqlite3_eager_int_rows" (fun () -> eager_int_rows db);
      measure "sqlite3_direct_pair_sum" (fun () -> direct_pair_sum db);
      measure "sqlite3_eager_pair_rows" (fun () -> eager_pair_rows db))

