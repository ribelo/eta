module D = Sqlite_fast_direct.Direct_sqlite
module Rc = Sqlite3.Rc

let default_iterations = 200_000

let iterations =
  if Array.length Sys.argv > 1 then
    int_of_string Sys.argv.(1)
  else
    default_iterations

let expect_sqlite3 label expected actual =
  if actual <> expected then
    failwith
      (label ^ ": expected " ^ Rc.to_string expected ^ ", got " ^ Rc.to_string actual)

let expect_sqlite3_ok label rc = expect_sqlite3 label Rc.OK rc
let expect_sqlite3_row label rc = expect_sqlite3 label Rc.ROW rc
let expect_sqlite3_done label rc = expect_sqlite3 label Rc.DONE rc

let direct_zero_param db =
  let stmt = D.prepare db "SELECT 1" in
  let total = ref 0 in
  for _ = 1 to iterations do
    D.expect_row "direct zero step" (D.step stmt);
    total := !total + D.column_int stmt 0;
    D.expect_done "direct zero drain" (D.step stmt);
    D.expect_ok "direct zero reset" (D.reset stmt)
  done;
  D.expect_ok "direct zero finalize" (D.finalize stmt);
  !total

let direct_one_param db =
  let stmt = D.prepare db "SELECT ?" in
  let total = ref 0 in
  for i = 1 to iterations do
    D.expect_ok "direct one bind" (D.bind_int stmt 1 i);
    D.expect_row "direct one step" (D.step stmt);
    total := !total + D.column_int stmt 0;
    D.expect_done "direct one drain" (D.step stmt);
    D.expect_ok "direct one reset" (D.reset stmt);
    D.expect_ok "direct one clear" (D.clear_bindings stmt)
  done;
  D.expect_ok "direct one finalize" (D.finalize stmt);
  !total

let direct_eight_param db =
  let stmt = D.prepare db "SELECT ? + ? + ? + ? + ? + ? + ? + ?" in
  let total = ref 0 in
  for i = 1 to iterations do
    D.expect_ok "direct p1" (D.bind_int stmt 1 i);
    D.expect_ok "direct p2" (D.bind_int stmt 2 2);
    D.expect_ok "direct p3" (D.bind_int stmt 3 3);
    D.expect_ok "direct p4" (D.bind_int stmt 4 4);
    D.expect_ok "direct p5" (D.bind_int stmt 5 5);
    D.expect_ok "direct p6" (D.bind_int stmt 6 6);
    D.expect_ok "direct p7" (D.bind_int stmt 7 7);
    D.expect_ok "direct p8" (D.bind_int stmt 8 8);
    D.expect_row "direct eight step" (D.step stmt);
    total := !total + D.column_int stmt 0;
    D.expect_done "direct eight drain" (D.step stmt);
    D.expect_ok "direct eight reset" (D.reset stmt);
    D.expect_ok "direct eight clear" (D.clear_bindings stmt)
  done;
  D.expect_ok "direct eight finalize" (D.finalize stmt);
  !total

let sqlite3_zero_param db =
  let stmt = Sqlite3.prepare db "SELECT 1" in
  let total = ref 0 in
  for _ = 1 to iterations do
    expect_sqlite3_row "sqlite3 zero step" (Sqlite3.step stmt);
    total := !total + Sqlite3.column_int stmt 0;
    expect_sqlite3_done "sqlite3 zero drain" (Sqlite3.step stmt);
    expect_sqlite3_ok "sqlite3 zero reset" (Sqlite3.reset stmt)
  done;
  expect_sqlite3_ok "sqlite3 zero finalize" (Sqlite3.finalize stmt);
  !total

let sqlite3_one_param db =
  let stmt = Sqlite3.prepare db "SELECT ?" in
  let total = ref 0 in
  for i = 1 to iterations do
    expect_sqlite3_ok "sqlite3 one bind" (Sqlite3.bind_int stmt 1 i);
    expect_sqlite3_row "sqlite3 one step" (Sqlite3.step stmt);
    total := !total + Sqlite3.column_int stmt 0;
    expect_sqlite3_done "sqlite3 one drain" (Sqlite3.step stmt);
    expect_sqlite3_ok "sqlite3 one reset" (Sqlite3.reset stmt);
    expect_sqlite3_ok "sqlite3 one clear" (Sqlite3.clear_bindings stmt)
  done;
  expect_sqlite3_ok "sqlite3 one finalize" (Sqlite3.finalize stmt);
  !total

let sqlite3_eight_param db =
  let stmt = Sqlite3.prepare db "SELECT ? + ? + ? + ? + ? + ? + ? + ?" in
  let total = ref 0 in
  for i = 1 to iterations do
    expect_sqlite3_ok "sqlite3 p1" (Sqlite3.bind_int stmt 1 i);
    expect_sqlite3_ok "sqlite3 p2" (Sqlite3.bind_int stmt 2 2);
    expect_sqlite3_ok "sqlite3 p3" (Sqlite3.bind_int stmt 3 3);
    expect_sqlite3_ok "sqlite3 p4" (Sqlite3.bind_int stmt 4 4);
    expect_sqlite3_ok "sqlite3 p5" (Sqlite3.bind_int stmt 5 5);
    expect_sqlite3_ok "sqlite3 p6" (Sqlite3.bind_int stmt 6 6);
    expect_sqlite3_ok "sqlite3 p7" (Sqlite3.bind_int stmt 7 7);
    expect_sqlite3_ok "sqlite3 p8" (Sqlite3.bind_int stmt 8 8);
    expect_sqlite3_row "sqlite3 eight step" (Sqlite3.step stmt);
    total := !total + Sqlite3.column_int stmt 0;
    expect_sqlite3_done "sqlite3 eight drain" (Sqlite3.step stmt);
    expect_sqlite3_ok "sqlite3 eight reset" (Sqlite3.reset stmt);
    expect_sqlite3_ok "sqlite3 eight clear" (Sqlite3.clear_bindings stmt)
  done;
  expect_sqlite3_ok "sqlite3 eight finalize" (Sqlite3.finalize stmt);
  !total

let measure name f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let before_bytes = Gc.allocated_bytes () in
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  let after_bytes = Gc.allocated_bytes () in
  let after = Gc.quick_stat () in
  Printf.printf
    "%s iterations=%d result=%d wall_ms=%.3f allocated_bytes=%.0f minor_words=%.0f promoted_words=%.0f major_words=%.0f minor_collections=%d major_collections=%d\n%!"
    name
    iterations
    result
    ((t1 -. t0) *. 1000.0)
    (after_bytes -. before_bytes)
    (after.minor_words -. before.minor_words)
    (after.promoted_words -. before.promoted_words)
    (after.major_words -. before.major_words)
    (after.minor_collections - before.minor_collections)
    (after.major_collections - before.major_collections)

let () =
  let direct_db = D.open_memory () in
  let sqlite3_db = Sqlite3.db_open ":memory:" in
  Fun.protect
    ~finally:(fun () ->
      D.expect_ok "direct close" (D.close direct_db);
      if not (Sqlite3.db_close sqlite3_db) then
        failwith "sqlite3 close failed")
    (fun () ->
      measure "direct_zero_param" (fun () -> direct_zero_param direct_db);
      measure "sqlite3_zero_param" (fun () -> sqlite3_zero_param sqlite3_db);
      measure "direct_one_param" (fun () -> direct_one_param direct_db);
      measure "sqlite3_one_param" (fun () -> sqlite3_one_param sqlite3_db);
      measure "direct_eight_param" (fun () -> direct_eight_param direct_db);
      measure "sqlite3_eight_param" (fun () -> sqlite3_eight_param sqlite3_db))

