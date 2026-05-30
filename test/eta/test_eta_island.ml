open Eta
open Eta_test
open Test_eta_support

let with_island_runtime ?domains f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Effect.Island.Pool.create ?domains () in
  Fun.protect
    ~finally:(fun () -> Effect.Island.Pool.shutdown pool)
    (fun () ->
      let rt =
        Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~island_pool:pool
          ()
      in
      f rt pool)

type island_error : immutable_data =
  | Odd of int
  | Invalid_payload of string

type parse_input : immutable_data = {
  parse_id : int;
  payload : string;
}

type schema_input : immutable_data = {
  schema_version : int;
  required : int;
  values : int list;
}

type hash_input : immutable_data = {
  hash_seed : int;
  rounds : int;
  bytes : string;
}

type island_entry : immutable_data = {
  entry_input : int;
  entry_ms : int;
}

let (island_square @ portable) n = n * n

let (island_order_work @ portable) n =
  let rec burn acc i =
    if i = 0 then acc
    else burn (((acc lxor (i * 33)) + n) land 0x3fffffff) (i - 1)
  in
  ignore (burn 0 (((n mod 3) + 1) * 250));
  n * 10

let (island_even_result @ portable) n =
  if n mod 2 = 0 then Ok (n / 2) else Error (Odd n)

let (island_settled_work @ portable) n =
  if n = 0 then failwith "worker died"
  else if n mod 2 = 0 then Ok (n * 2)
  else Error (Odd n)

let (island_specific_worker_error @ portable) n =
  if n = 0 then failwith "specific worker error" else Ok n

let (island_parse_work @ portable) input =
  let len = String.length input.payload in
  let rec count_colons i acc =
    if i = len then acc
    else
      let acc = if Char.equal input.payload.[i] ':' then acc + 1 else acc in
      count_colons (i + 1) acc
  in
  input.parse_id + len + count_colons 0 0

let (island_schema_work @ portable) input =
  let rec sum acc = function
    | [] -> acc
    | x :: xs -> sum (acc + x) xs
  in
  input.schema_version + input.required + sum 0 input.values

let (island_hash_work @ portable) input =
  let len = String.length input.bytes in
  let rec loop i acc =
    if i = input.rounds then acc
    else
      let byte = Char.code input.bytes.[i mod len] in
      loop (i + 1) (((acc lxor byte) * 16_777_619) land 0x3fffffff)
  in
  loop 0 input.hash_seed

let (island_entry_probe @ portable) n =
  let started_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  Thread.delay 0.05;
  { entry_input = n; entry_ms = started_ms }

let test_island_single_uses_runtime_pool () =
  with_island_runtime @@ fun rt _pool ->
  Alcotest.(check int)
    "single island" 49
    (run_ok rt (Effect.island ~name:"square" island_square 7))

let test_island_requires_pool () =
  with_runtime @@ fun rt ->
  match Runtime.run rt (Effect.island ~name:"missing" island_square 3) with
  | Exit.Ok _ -> Alcotest.fail "expected missing island pool to fail"
  | Exit.Error cause ->
      check_die_message "missing pool" "island executor not configured" cause

let test_island_run_pool_override () =
  with_runtime @@ fun rt ->
  let pool = Effect.Island.Pool.create () in
  Fun.protect
    ~finally:(fun () -> Effect.Island.Pool.shutdown pool)
    (fun () ->
      check_exit_ok Alcotest.int "override pool" 36
        (Runtime.run ~island_pool:pool rt
           (Effect.island ~name:"override" island_square 6)))

let test_island_map_preserves_order () =
  with_island_runtime @@ fun rt _pool ->
  let inputs = [ 5; 1; 4; 2; 3 ] in
  Alcotest.(check (list int))
    "input order" [ 50; 10; 40; 20; 30 ]
    (run_ok rt (Effect.Island.map ~f:island_order_work inputs))

let test_island_map_uses_pool_fanout () =
  with_island_runtime ~domains:8 @@ fun rt _pool ->
  let inputs = List.init 16 Fun.id in
  let results = run_ok rt (Effect.Island.map ~f:island_entry_probe inputs) in
  Alcotest.(check (list int)) "input order" inputs
    (List.map (fun result -> result.entry_input) results);
  let min_start, max_start =
    match results with
    | [] -> Alcotest.fail "expected island entry results"
    | first :: rest ->
        List.fold_left
          (fun (min_start, max_start) result ->
            (min min_start result.entry_ms, max max_start result.entry_ms))
          (first.entry_ms, first.entry_ms)
          rest
  in
  Alcotest.(check bool) "start spread under 200ms" true
    (max_start - min_start < 200)

let test_island_map_result_returns_item_results () =
  with_island_runtime @@ fun rt _pool ->
  match run_ok rt (Effect.Island.map_result ~f:island_even_result [ 2; 3; 4 ])
  with
  | [ Ok 1; Error (Odd 3); Ok 2 ] -> ()
  | _ -> Alcotest.fail "unexpected map_result output"

let test_island_all_settled_returns_worker_died () =
  with_island_runtime @@ fun rt _pool ->
  match
    run_ok rt
      (Effect.Island.all_settled ~f:island_settled_work [ 2; 3; 0; 4 ])
  with
  | [
   Effect.Island.Ok 4;
   Effect.Island.Error (Odd 3);
   Effect.Island.Worker_died die;
   Effect.Island.Ok 8;
  ] ->
      Alcotest.(check string) "worker die kind" "worker_died" die.kind
  | _ -> Alcotest.fail "unexpected all_settled output"

let test_island_worker_died_captures_exception_details () =
  with_island_runtime @@ fun rt _pool ->
  match
    run_ok rt (Effect.Island.all_settled ~f:island_specific_worker_error [ 0 ])
  with
  | [ Effect.Island.Worker_died die ] ->
      Alcotest.(check bool) "worker die message" true
        (contains_substring die.message "specific worker error");
      (match die.backtrace with
      | Some backtrace ->
          Alcotest.(check bool) "worker die backtrace" true
            (String.length backtrace > 0)
      | None -> Alcotest.fail "expected worker die backtrace")
  | _ -> Alcotest.fail "unexpected all_settled output"

let test_island_map_worker_crash_fails_outer_effect () =
  with_island_runtime @@ fun rt _pool ->
  match Runtime.run rt (Effect.Island.map ~f:island_settled_work [ 1; 0 ]) with
  | Exit.Ok _ -> Alcotest.fail "expected worker crash to fail map"
  | Exit.Error cause -> check_die_message "worker crash" "worker died" cause

let test_island_workloads () =
  with_island_runtime @@ fun rt _pool ->
  let parse_inputs =
    [
      { parse_id = 1; payload = "a:b:c" };
      { parse_id = 2; payload = "abc" };
      { parse_id = 3; payload = "x:y" };
    ]
  in
  let schema_inputs =
    [
      { schema_version = 1; required = 10; values = [ 1; 2; 3 ] };
      { schema_version = 2; required = 0; values = [ 5; 5 ] };
    ]
  in
  let hash_inputs =
    [
      { hash_seed = 17; rounds = 24; bytes = "abcdef" };
      { hash_seed = 23; rounds = 32; bytes = "schema" };
      { hash_seed = 31; rounds = 16; bytes = "payload" };
    ]
  in
  Alcotest.(check (list int))
    "parse workload" [ 8; 5; 7 ]
    (run_ok rt (Effect.Island.map ~name:"parse" ~f:island_parse_work parse_inputs));
  Alcotest.(check (list int))
    "schema workload" [ 17; 12 ]
    (run_ok rt
       (Effect.Island.map ~name:"schema" ~f:island_schema_work schema_inputs));
  Alcotest.(check int)
    "hash workload count" 3
    (List.length
       (run_ok rt
          (Effect.Island.map ~name:"hash" ~f:island_hash_work hash_inputs)))


