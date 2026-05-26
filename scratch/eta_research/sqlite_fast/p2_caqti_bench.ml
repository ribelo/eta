module Req = struct
  include Caqti_type.Std
  include Caqti_request.Infix
end

module type Db = Caqti_blocking.CONNECTION

let default_count = 50_000

let count =
  if Array.length Sys.argv > 1 then
    int_of_string Sys.argv.(1)
  else
    default_count

let create_items =
  Req.(unit ->. unit) "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"

let begin_tx = Req.(unit ->. unit) "BEGIN"
let commit_tx = Req.(unit ->. unit) "COMMIT"
let insert_item = Req.(t2 int string ->. unit) "INSERT INTO items (id, name) VALUES (?, ?)"
let select_ids = Req.(unit ->* int) "SELECT id FROM items ORDER BY id"
let select_pairs = Req.(unit ->* t2 int string) "SELECT id, name FROM items ORDER BY id"
let zero_param = Req.(unit ->! int) "SELECT 1"
let one_param = Req.(int ->! int) "SELECT ?"

let eight_param =
  Req.(t8 int int int int int int int int ->! int)
    "SELECT ? + ? + ? + ? + ? + ? + ? + ?"

let or_fail = Caqti_blocking.or_fail

let connect () =
  Caqti_blocking.connect (Uri.of_string "sqlite3::memory:")
  |> or_fail

let disconnect (module Db : Db) = Db.disconnect ()

let exec (module Db : Db) req arg = Db.exec req arg |> or_fail
let find (module Db : Db) req arg = Db.find req arg |> or_fail
let fold (module Db : Db) req f arg acc = Db.fold req f arg acc |> or_fail
let collect_list (module Db : Db) req arg = Db.collect_list req arg |> or_fail

let setup db rows =
  exec db create_items ();
  exec db begin_tx ();
  for i = 1 to rows do
    exec db insert_item (i, "name-" ^ string_of_int i)
  done;
  exec db commit_tx ()

let int_rows_sink = ref []
let pair_rows_sink = ref []

let clear_sinks () =
  int_rows_sink := [];
  pair_rows_sink := []

let caqti_fold_int_sum db =
  fold db select_ids (fun id acc -> acc + id + 1) () 0

let caqti_collect_int_rows db =
  let rows = collect_list db select_ids () in
  int_rows_sink := rows;
  List.fold_left ( + ) 0 rows

let caqti_fold_pair_sum db =
  fold db select_pairs (fun (id, name) acc -> acc + id + String.length name) () 0

let caqti_collect_pair_rows db =
  let rows = collect_list db select_pairs () in
  pair_rows_sink := rows;
  List.fold_left (fun acc (id, name) -> acc + id + String.length name) 0 rows

let caqti_zero_param db =
  let total = ref 0 in
  for _ = 1 to count do
    total := !total + find db zero_param ()
  done;
  !total

let caqti_one_param db =
  let total = ref 0 in
  for i = 1 to count do
    total := !total + find db one_param i
  done;
  !total

let caqti_eight_param db =
  let total = ref 0 in
  for i = 1 to count do
    total := !total + find db eight_param (i, 2, 3, 4, 5, 6, 7, 8)
  done;
  !total

let measure name kind f =
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
    "%s %s=%d result=%d wall_ms=%.3f allocated_bytes=%.0f minor_words=%.0f promoted_words=%.0f major_words=%.0f minor_collections=%d major_collections=%d\n%!"
    name
    kind
    count
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
  let db = connect () in
  Fun.protect
    ~finally:(fun () -> disconnect db)
    (fun () ->
      setup db count;
      measure "caqti_fold_int_sum" "rows" (fun () -> caqti_fold_int_sum db);
      measure "caqti_collect_int_rows" "rows" (fun () -> caqti_collect_int_rows db);
      measure "caqti_fold_pair_sum" "rows" (fun () -> caqti_fold_pair_sum db);
      measure "caqti_collect_pair_rows" "rows" (fun () -> caqti_collect_pair_rows db);
      measure "caqti_zero_param" "iterations" (fun () -> caqti_zero_param db);
      measure "caqti_one_param" "iterations" (fun () -> caqti_one_param db);
      measure "caqti_eight_param" "iterations" (fun () -> caqti_eight_param db))
