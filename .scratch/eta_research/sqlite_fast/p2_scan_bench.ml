module S = Sqlite_fast_direct.Direct_sqlite

let default_rows = 50_000

let rows =
  if Array.length Sys.argv > 1 then
    int_of_string Sys.argv.(1)
  else
    default_rows

let expect_done label rc = S.expect_done label rc
let expect_ok label rc = S.expect_ok label rc
let expect_row label rc = S.expect_row label rc

let int_rows_sink = ref []
let pair_rows_sink = ref []

let clear_sinks () =
  int_rows_sink := [];
  pair_rows_sink := []

let setup rows =
  let db = S.open_memory () in
  S.exec db "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)";
  S.exec db "BEGIN";
  let insert = S.prepare db "INSERT INTO items (id, name) VALUES (?, ?)" in
  for i = 1 to rows do
    expect_ok "bind insert id" (S.bind_int insert 1 i);
    expect_ok "bind insert name" (S.bind_text insert 2 ("name-" ^ string_of_int i));
    expect_done "insert row" (S.step insert);
    expect_ok "reset insert" (S.reset insert);
    expect_ok "clear insert" (S.clear_bindings insert)
  done;
  expect_ok "finalize insert" (S.finalize insert);
  S.exec db "COMMIT";
  db

let drain_or_fail label stmt rc =
  if rc = S.done_ then
    ()
  else
    failwith (label ^ ": expected DONE, got " ^ S.rc_name rc)

let direct_int_sum db =
  let stmt = S.prepare db "SELECT id FROM items ORDER BY id" in
  let total = ref 0 in
  let count = ref 0 in
  let running = ref true in
  while !running do
    let rc = S.step stmt in
    if rc = S.row then (
      total := !total + S.column_int stmt 0;
      incr count
    ) else if rc = S.done_ then
      running := false
    else
      failwith ("direct_int_sum: " ^ S.rc_name rc)
  done;
  expect_ok "finalize direct_int_sum" (S.finalize stmt);
  !total + !count

let eager_int_rows db =
  let stmt = S.prepare db "SELECT id FROM items ORDER BY id" in
  let rows = ref [] in
  let running = ref true in
  while !running do
    let rc = S.step stmt in
    if rc = S.row then
      rows := S.column_int stmt 0 :: !rows
    else if rc = S.done_ then
      running := false
    else
      failwith ("eager_int_rows: " ^ S.rc_name rc)
  done;
  expect_ok "finalize eager_int_rows" (S.finalize stmt);
  let materialized = !rows in
  int_rows_sink := materialized;
  List.fold_left ( + ) 0 materialized

let direct_pair_sum db =
  let stmt = S.prepare db "SELECT id, name FROM items ORDER BY id" in
  let total = ref 0 in
  let running = ref true in
  while !running do
    let rc = S.step stmt in
    if rc = S.row then (
      let id = S.column_int stmt 0 in
      let name = S.column_text stmt 1 in
      total := !total + id + String.length name
    ) else if rc = S.done_ then
      running := false
    else
      failwith ("direct_pair_sum: " ^ S.rc_name rc)
  done;
  expect_ok "finalize direct_pair_sum" (S.finalize stmt);
  !total

let eager_pair_rows db =
  let stmt = S.prepare db "SELECT id, name FROM items ORDER BY id" in
  let rows = ref [] in
  let running = ref true in
  while !running do
    let rc = S.step stmt in
    if rc = S.row then
      rows := (S.column_int stmt 0, S.column_text stmt 1) :: !rows
    else if rc = S.done_ then
      running := false
    else
      failwith ("eager_pair_rows: " ^ S.rc_name rc)
  done;
  expect_ok "finalize eager_pair_rows" (S.finalize stmt);
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
    ~finally:(fun () -> expect_ok "close db" (S.close db))
    (fun () ->
      measure "direct_int_sum" (fun () -> direct_int_sum db);
      measure "eager_int_rows" (fun () -> eager_int_rows db);
      measure "direct_pair_sum" (fun () -> direct_pair_sum db);
      measure "eager_pair_rows" (fun () -> eager_pair_rows db))
