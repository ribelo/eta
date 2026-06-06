open Eta

module Island = Eta_par.Island

let reclaim_eio_backend () =
  Gc.full_major ();
  Gc.compact ()

let run_linux_eio ?fallback f =
  reclaim_eio_backend ();
  Fun.protect ~finally:reclaim_eio_backend (fun () ->
      Eio_linux.run ?fallback ~queue_depth:64 ~n_blocks:1 f)

let run_eio f =
  match Sys.getenv_opt "EIO_BACKEND" with
  | Some ("linux" | "io-uring") -> run_linux_eio f
  | None | Some "" ->
      run_linux_eio ~fallback:(fun _ -> Eio_main.run f) f
  | _ -> Eio_main.run f

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec search pos =
    if n_len = 0 then true
    else if pos + n_len > h_len then false
    else at pos 0 || search (pos + 1)
  in
  search 0

let rec cause_has_die_message expected = function
  | Cause.Die die -> contains_substring (Printexc.to_string die.exn) expected
  | Cause.Fail _ | Cause.Interrupt _ -> false
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.exists (cause_has_die_message expected) causes
  | Cause.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Suppressed { primary; finalizer } ->
      cause_has_die_message expected primary
      || finalizer_has_die_message expected finalizer

and finalizer_has_die_message expected = function
  | Cause.Finalizer.Die die ->
      contains_substring (Printexc.to_string die.exn) expected
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> false
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      List.exists (finalizer_has_die_message expected) causes
  | Cause.Finalizer.Finalizer cause -> finalizer_has_die_message expected cause
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      finalizer_has_die_message expected primary
      || finalizer_has_die_message expected finalizer

let check_die_message label expected cause =
  Alcotest.(check bool) label true (cause_has_die_message expected cause)

let with_island_runtime ?domains f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Island.Pool.create ?domains () in
  Fun.protect
    ~finally:(fun () -> Island.Pool.shutdown pool)
    (fun () ->
      let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
      f rt pool)

type island_error =
  | Odd of int
  | Invalid_payload of string

type parse_input = {
  parse_id : int;
  payload : string;
}

type schema_input = {
  schema_version : int;
  required : int;
  values : int list;
}

type hash_input = {
  hash_seed : int;
  rounds : int;
  bytes : string;
}

type island_entry = {
  entry_input : int;
  entry_ms : int;
}

let island_square n = n * n

let island_order_work n =
  let rec burn acc i =
    if i = 0 then acc
    else burn (((acc lxor (i * 33)) + n) land 0x3fffffff) (i - 1)
  in
  ignore (burn 0 (((n mod 3) + 1) * 250));
  n * 10

let island_even_result n =
  if n mod 2 = 0 then Ok (n / 2) else Error (Odd n)

let island_settled_work n =
  if n = 0 then failwith "worker died"
  else if n mod 2 = 0 then Ok (n * 2)
  else Error (Odd n)

let island_specific_worker_error n =
  if n = 0 then failwith "specific worker error" else Ok n

let island_parse_work input =
  let len = String.length input.payload in
  let rec count_colons i acc =
    if i = len then acc
    else
      let acc = if Char.equal input.payload.[i] ':' then acc + 1 else acc in
      count_colons (i + 1) acc
  in
  input.parse_id + len + count_colons 0 0

let island_schema_work input =
  let rec sum acc = function
    | [] -> acc
    | x :: xs -> sum (acc + x) xs
  in
  input.schema_version + input.required + sum 0 input.values

let island_hash_work input =
  let len = String.length input.bytes in
  let rec loop i acc =
    if i = input.rounds then acc
    else
      let byte = Char.code input.bytes.[i mod len] in
      loop (i + 1) (((acc lxor byte) * 16_777_619) land 0x3fffffff)
  in
  loop 0 input.hash_seed

let island_entry_probe n =
  let started_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  Thread.delay 0.05;
  { entry_input = n; entry_ms = started_ms }

let island_sleep_ms ms =
  Thread.delay (float_of_int ms /. 1000.0);
  ms

let test_island_single_uses_explicit_pool () =
  with_island_runtime @@ fun rt pool ->
  Alcotest.(check int)
    "single island" 49
    (run_ok rt (Island.run ~name:"square" ~pool island_square 7))

let test_island_run_uses_standalone_pool () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Island.Pool.create () in
  Fun.protect
    ~finally:(fun () -> Island.Pool.shutdown pool)
    (fun () ->
      let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
      Alcotest.(check int)
        "standalone pool" 36
        (run_ok rt (Island.run ~name:"standalone" ~pool island_square 6)))

let test_island_map_preserves_order () =
  with_island_runtime @@ fun rt pool ->
  let inputs = [ 5; 1; 4; 2; 3 ] in
  Alcotest.(check (list int))
    "input order" [ 50; 10; 40; 20; 30 ]
    (run_ok rt (Island.map ~pool ~f:island_order_work inputs))

let test_island_map_uses_pool_fanout () =
  with_island_runtime ~domains:8 @@ fun rt pool ->
  let inputs = List.init 16 Fun.id in
  let results = run_ok rt (Island.map ~pool ~f:island_entry_probe inputs) in
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

let test_island_timeout_stops_waiting_for_batch () =
  with_island_runtime @@ fun rt pool ->
  let started = Unix.gettimeofday () in
  match
    Runtime.run rt
      (Island.map ~pool ~f:island_sleep_ms [ 200 ]
      |> Effect.timeout (Duration.ms 10))
  with
  | Exit.Error (Cause.Fail `Timeout) ->
      let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
      Alcotest.(check bool) "timeout returned before island work finished" true
        (elapsed_ms < 150)
  | Exit.Ok _ -> Alcotest.fail "expected island batch timeout"
  | Exit.Error cause ->
      Alcotest.failf "expected timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<island>"))
        cause

let test_island_map_result_returns_item_results () =
  with_island_runtime @@ fun rt pool ->
  match run_ok rt (Island.map_result ~pool ~f:island_even_result [ 2; 3; 4 ])
  with
  | [ Ok 1; Error (Odd 3); Ok 2 ] -> ()
  | _ -> Alcotest.fail "unexpected map_result output"

let test_island_all_settled_returns_worker_died () =
  with_island_runtime @@ fun rt pool ->
  match
    run_ok rt
      (Island.all_settled ~pool ~f:island_settled_work [ 2; 3; 0; 4 ])
  with
  | [
   Island.Ok 4;
   Island.Error (Odd 3);
   Island.Worker_died die;
   Island.Ok 8;
  ] ->
      Alcotest.(check string) "worker die kind" "worker_died" die.kind
  | _ -> Alcotest.fail "unexpected all_settled output"

let test_island_worker_died_captures_exception_details () =
  with_island_runtime @@ fun rt pool ->
  match
    run_ok rt (Island.all_settled ~pool ~f:island_specific_worker_error [ 0 ])
  with
  | [ Island.Worker_died die ] ->
      Alcotest.(check bool) "worker die message" true
        (contains_substring die.message "specific worker error");
      (match die.backtrace with
      | Some backtrace ->
          Alcotest.(check bool) "worker die backtrace" true
            (String.length backtrace > 0)
      | None -> Alcotest.fail "expected worker die backtrace")
  | _ -> Alcotest.fail "unexpected all_settled output"

let test_island_map_worker_crash_fails_outer_effect () =
  with_island_runtime @@ fun rt pool ->
  match Runtime.run rt (Island.map ~pool ~f:island_settled_work [ 1; 0 ]) with
  | Exit.Ok _ -> Alcotest.fail "expected worker crash to fail map"
  | Exit.Error cause -> check_die_message "worker crash" "worker died" cause

let test_island_workloads () =
  with_island_runtime @@ fun rt pool ->
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
    (run_ok rt (Island.map ~name:"parse" ~pool ~f:island_parse_work parse_inputs));
  Alcotest.(check (list int))
    "schema workload" [ 17; 12 ]
    (run_ok rt
       (Island.map ~name:"schema" ~pool ~f:island_schema_work schema_inputs));
  Alcotest.(check int)
    "hash workload count" 3
    (List.length
       (run_ok rt
          (Island.map ~name:"hash" ~pool ~f:island_hash_work hash_inputs)))

let () =
  Alcotest.run "eta_par.island"
    [
      ( "Island",
        [
          Alcotest.test_case "single uses explicit pool" `Quick
            test_island_single_uses_explicit_pool;
          Alcotest.test_case "standalone pool" `Quick
            test_island_run_uses_standalone_pool;
          Alcotest.test_case "map preserves order" `Quick
            test_island_map_preserves_order;
          Alcotest.test_case "map uses pool fanout" `Quick
            test_island_map_uses_pool_fanout;
          Alcotest.test_case "timeout stops waiting for batch" `Quick
            test_island_timeout_stops_waiting_for_batch;
          Alcotest.test_case "map_result returns item results" `Quick
            test_island_map_result_returns_item_results;
          Alcotest.test_case "all_settled returns worker_died" `Quick
            test_island_all_settled_returns_worker_died;
          Alcotest.test_case "worker_died captures exception details" `Quick
            test_island_worker_died_captures_exception_details;
          Alcotest.test_case "map worker crash fails outer eff" `Quick
            test_island_map_worker_crash_fails_outer_effect;
          Alcotest.test_case "workloads" `Quick test_island_workloads;
        ] );
    ]
