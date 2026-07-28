open Eta

module Int_cache = Eta_cache.Make (struct
  type t = int

  let equal = Int.equal
  let hash = Hashtbl.hash
end)

let pp_hidden ppf _ = Format.pp_print_string ppf "<cache-error>"

let run_exit rt eff = Eta_eio.Runtime.run rt eff

let run_ok rt eff =
  match run_exit rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Cause.pp pp_hidden) cause

let check_ok_int label expected = function
  | Exit.Ok actual -> Alcotest.(check int) label expected actual
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Ok, got %a" label (Cause.pp pp_hidden) cause

let expect_fail label pred = function
  | Exit.Error (Cause.Fail err) when pred err -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected typed failure, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok value -> Alcotest.failf "%s: expected failure, got Ok %d" label value

let expect_interrupt label = function
  | Exit.Error cause when Cause.is_interrupt_only cause -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected interrupt, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok value -> Alcotest.failf "%s: expected interrupt, got Ok %d" label value

let expect_die label defect = function
  | Exit.Error (Cause.Die die) when die.Cause.exn == defect -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected defect, got %a" label (Cause.pp pp_hidden)
        cause
  | Exit.Ok value -> Alcotest.failf "%s: expected defect, got Ok %d" label value

let with_runtime ?now_ms f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let sleep duration =
    Eta_test.Test_clock.adjust clock duration;
    Eio.Fiber.yield ()
  in
  let now_ms =
    match now_ms with
    | Some now_ms -> now_ms
    | None -> fun () -> Eta_test.Test_clock.now_ms clock
  in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~sleep ~now_ms ()
  in
  f rt

let make_cache ?(capacity = 16)
    ?(time_to_live = fun _exit _key -> Duration.seconds 60) rt ~lookup =
  run_ok rt (Int_cache.make ~capacity ~lookup ~time_to_live)

let runtime_interrupt_effect () =
  Effect.Expert.make ~leaf_name:"test.cache.interrupt" @@ fun context ->
  let contract = Effect.Expert.contract context in
  contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
  contract.Runtime_contract.cancel cancel_context Exit;
  contract.Runtime_contract.await_cancel ()

let mixed_interrupt_failure_cause () =
  Cause.concurrent [ Cause.interrupt; Cause.fail (`Mixed 1) ]

let mixed_interrupt_failure_effect () =
  Effect.Expert.make ~leaf_name:"test.cache.mixed_interrupt" @@ fun _context ->
  Exit.Error (mixed_interrupt_failure_cause ())

let expect_mixed_interrupt_failure label = function
  | Exit.Error cause when Cause.equal ( = ) (mixed_interrupt_failure_cause ()) cause ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "%s: expected mixed interrupt/failure, got %a" label
        (Cause.pp pp_hidden) cause
  | Exit.Ok value ->
      Alcotest.failf "%s: expected mixed interrupt/failure, got Ok %d" label
        value

let test_cold_miss_computes_once () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10) in
  let cache = make_cache rt ~lookup in
  check_ok_int "cold miss value" 70 (run_exit rt (Int_cache.get cache 7));
  Alcotest.(check int) "lookup count" 1 !calls

let test_hit_does_not_recompute () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10) in
  let cache = make_cache rt ~lookup in
  check_ok_int "first get" 30 (run_exit rt (Int_cache.get cache 3));
  check_ok_int "second get" 30 (run_exit rt (Int_cache.get cache 3));
  Alcotest.(check int) "hit reused cached value" 1 !calls

let test_concurrent_same_key_is_single_flight () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key =
    Effect.sync (fun () -> incr calls)
    |> Effect.bind (fun () -> Effect.sleep (Duration.ms 5))
    |> Effect.map (fun () -> key * 10)
  in
  let cache = make_cache rt ~lookup in
  let results =
    run_ok rt (Effect.all (List.init 8 (fun _ -> Int_cache.get cache 4)))
  in
  Alcotest.(check (list int))
    "all waiters received value" (List.init 8 (fun _ -> 40)) results;
  Alcotest.(check int) "lookup ran once" 1 !calls

let test_typed_failure_is_cached_and_replayed () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup _key =
    Effect.sync (fun () -> incr calls)
    |> Effect.bind (fun () -> Effect.fail (`Missing 1))
  in
  let cache = make_cache rt ~lookup in
  let results =
    run_ok rt
      (Effect.all
         [ Effect.to_exit (Int_cache.get cache 9); Effect.to_exit (Int_cache.get cache 9) ])
  in
  List.iter (expect_fail "cached failure" (( = ) (`Missing 1))) results;
  Alcotest.(check int) "failing lookup ran once" 1 !calls

let test_ttl_expiry_recomputes () =
  let now = ref 0 in
  with_runtime ~now_ms:(fun () -> !now) @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let cache =
    make_cache rt ~lookup
      ~time_to_live:(fun _exit _key -> Duration.ms 10)
  in
  check_ok_int "initial value" 51 (run_exit rt (Int_cache.get cache 5));
  now := 9;
  check_ok_int "unexpired value" 51 (run_exit rt (Int_cache.get cache 5));
  now := 10;
  check_ok_int "expired value" 52 (run_exit rt (Int_cache.get cache 5));
  Alcotest.(check int) "expired entry recomputed" 2 !calls

let test_ttl_zero_does_not_cache () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let cache =
    make_cache rt ~lookup
      ~time_to_live:(fun _exit _key -> Duration.zero)
  in
  check_ok_int "first value" 61 (run_exit rt (Int_cache.get cache 6));
  check_ok_int "second value" 62 (run_exit rt (Int_cache.get cache 6));
  Alcotest.(check int) "ttl zero forced both loads" 2 !calls

let test_invalidate_and_invalidate_all () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let cache = make_cache rt ~lookup in
  check_ok_int "key 1 initial" 11 (run_exit rt (Int_cache.get cache 1));
  check_ok_int "key 2 initial" 22 (run_exit rt (Int_cache.get cache 2));
  run_ok rt (Int_cache.invalidate cache 1);
  check_ok_int "key 1 after invalidate" 13 (run_exit rt (Int_cache.get cache 1));
  check_ok_int "key 2 still cached" 22 (run_exit rt (Int_cache.get cache 2));
  run_ok rt (Int_cache.invalidate_all cache);
  check_ok_int "key 1 after invalidate_all" 14 (run_exit rt (Int_cache.get cache 1));
  check_ok_int "key 2 after invalidate_all" 25 (run_exit rt (Int_cache.get cache 2));
  Alcotest.(check int) "lookup calls" 5 !calls

let test_get_if_present_does_not_load () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key * 10) in
  let cache = make_cache rt ~lookup in
  Alcotest.(check bool)
    "absent without load" true
    (Option.is_none (run_ok rt (Int_cache.get_if_present cache 8)));
  Alcotest.(check int) "no lookup" 0 !calls;
  check_ok_int "loaded" 80 (run_exit rt (Int_cache.get cache 8));
  (match run_ok rt (Int_cache.get_if_present cache 8) with
   | Some (Exit.Ok 80) -> ()
   | Some (Exit.Ok value) ->
       Alcotest.failf "unexpected present value %d" value
   | Some (Exit.Error cause) ->
       Alcotest.failf "unexpected present failure %a" (Cause.pp pp_hidden) cause
   | None -> Alcotest.fail "expected present cached value");
  Alcotest.(check int) "still one lookup" 1 !calls

let test_refresh_recomputes_and_updates_cache () =
  with_runtime @@ fun rt ->
  let source = ref 1 in
  let calls = ref 0 in
  let lookup _key = Effect.sync (fun () -> incr calls; !source) in
  let cache = make_cache rt ~lookup in
  check_ok_int "initial" 1 (run_exit rt (Int_cache.get cache 1));
  source := 2;
  check_ok_int "refresh" 2 (run_exit rt (Int_cache.refresh cache 1));
  check_ok_int "cached refreshed" 2 (run_exit rt (Int_cache.get cache 1));
  Alcotest.(check int) "refresh loaded once" 2 !calls

let test_capacity_evicts_least_recently_used () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup key = Effect.sync (fun () -> incr calls; key) in
  let cache = make_cache ~capacity:2 rt ~lookup in
  List.iter
    (fun key -> ignore (run_ok rt (Int_cache.get cache key)))
    [ 1; 2; 1; 3; 1; 2 ];
  Alcotest.(check int)
    "1 was refreshed as MRU, 2 was evicted" 4 !calls

let test_stats_update () =
  let now = ref 0 in
  with_runtime ~now_ms:(fun () -> !now) @@ fun rt ->
  let lookup key =
    if key = 9 then Effect.fail `Bad else Effect.pure key
  in
  let cache =
    make_cache ~capacity:10 rt ~lookup
      ~time_to_live:(fun _exit _key -> Duration.ms 10)
  in
  ignore (run_ok rt (Int_cache.get cache 1));
  ignore (run_ok rt (Int_cache.get cache 1));
  now := 10;
  ignore (run_ok rt (Int_cache.get cache 1));
  expect_fail "stats failure" (( = ) `Bad)
    (run_ok rt (Effect.to_exit (Int_cache.get cache 9)));
  let stats = run_ok rt (Int_cache.stats cache) in
  Alcotest.(check int) "hits" 1 stats.Int_cache.hits;
  Alcotest.(check int) "misses" 3 stats.misses;
  Alcotest.(check int) "loads" 3 stats.loads;
  Alcotest.(check int) "load_failures" 1 stats.load_failures;
  Alcotest.(check int) "evictions" 0 stats.evictions;
  Alcotest.(check int) "expirations" 1 stats.expirations;
  Alcotest.(check int) "current_size" 2 stats.current_size;
  Alcotest.(check int) "size" 2 (run_ok rt (Int_cache.size cache))

let test_lookup_defect_propagates_and_is_not_cached () =
  with_runtime @@ fun rt ->
  let defect = Failure "boom" in
  let calls = ref 0 in
  let lookup _key =
    Effect.sync (fun () ->
        incr calls;
        raise defect)
  in
  let cache = make_cache rt ~lookup in
  expect_die "first defect" defect
    (run_ok rt (Effect.to_exit (Int_cache.get cache 1)));
  expect_die "second defect" defect
    (run_ok rt (Effect.to_exit (Int_cache.get cache 1)));
  Alcotest.(check int) "defect was not cached" 2 !calls

let test_interrupted_lookup_removes_pending_and_retries () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup _key =
    Effect.sync (fun () -> incr calls; !calls)
    |> Effect.bind (function
         | 1 ->
             Effect.yield
             |> Effect.bind (fun () -> runtime_interrupt_effect ())
         | _ -> Effect.pure 42)
  in
  let cache = make_cache rt ~lookup in
  let first_waiters =
    run_ok rt
      (Effect.all
         [ Effect.to_exit (Int_cache.get cache 1); Effect.to_exit (Int_cache.get cache 1) ])
  in
  List.iter (expect_interrupt "cancelled waiter") first_waiters;
  check_ok_int "later get retried" 42 (run_exit rt (Int_cache.get cache 1));
  Alcotest.(check int) "interrupted lookup did not poison key" 2 !calls

let test_mixed_interrupt_failure_is_not_cached () =
  with_runtime @@ fun rt ->
  let calls = ref 0 in
  let lookup _key =
    Effect.sync (fun () -> incr calls; !calls)
    |> Effect.bind (function
         | 1 -> mixed_interrupt_failure_effect ()
         | _ -> Effect.pure 42)
  in
  let cache = make_cache rt ~lookup in
  expect_mixed_interrupt_failure "first lookup"
    (run_ok rt (Effect.to_exit (Int_cache.get cache 1)));
  check_ok_int "later get retried" 42 (run_exit rt (Int_cache.get cache 1));
  Alcotest.(check int) "mixed interruption was not cached" 2 !calls

let () =
  Alcotest.run "eta_cache"
    [
      ( "lookup",
        [
          Alcotest.test_case "cold miss computes once" `Quick
            test_cold_miss_computes_once;
          Alcotest.test_case "hit does not recompute" `Quick
            test_hit_does_not_recompute;
          Alcotest.test_case "concurrent same-key get is single-flight" `Quick
            test_concurrent_same_key_is_single_flight;
          Alcotest.test_case "typed failure is cached and replayed" `Quick
            test_typed_failure_is_cached_and_replayed;
          Alcotest.test_case "defect propagates and is not cached" `Quick
            test_lookup_defect_propagates_and_is_not_cached;
          Alcotest.test_case "interrupted lookup removes pending" `Quick
            test_interrupted_lookup_removes_pending_and_retries;
          Alcotest.test_case "mixed interruption and failure is not cached"
            `Quick test_mixed_interrupt_failure_is_not_cached;
        ] );
      ( "ttl",
        [
          Alcotest.test_case "expiry recomputes" `Quick test_ttl_expiry_recomputes;
          Alcotest.test_case "zero does not cache" `Quick
            test_ttl_zero_does_not_cache;
        ] );
      ( "operations",
        [
          Alcotest.test_case "invalidate and invalidate_all" `Quick
            test_invalidate_and_invalidate_all;
          Alcotest.test_case "get_if_present does not load" `Quick
            test_get_if_present_does_not_load;
          Alcotest.test_case "refresh recomputes and updates" `Quick
            test_refresh_recomputes_and_updates_cache;
          Alcotest.test_case "capacity evicts LRU" `Quick
            test_capacity_evicts_least_recently_used;
          Alcotest.test_case "stats update" `Quick test_stats_update;
        ] );
    ]
