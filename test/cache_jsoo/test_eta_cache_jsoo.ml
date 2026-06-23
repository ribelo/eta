module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

module Int_cache = Eta_cache.Make (struct
  type t = int

  let equal = Int.equal
  let hash = Hashtbl.hash
end)

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let fail message = failwith message
let pp_err fmt _ = Format.pp_print_string fmt "<cache-error>"
let pp_cause cause = Format.asprintf "%a" (Eta.Cause.pp pp_err) cause

let finish done_ f value =
  try
    f value;
    done_ ()
  with exn ->
    set_exit_code 1;
    log ("eta_cache_jsoo failed: " ^ Printexc.to_string exn)

let run eff ~on_result =
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime eff ~on_result

let expect_ok = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> fail ("expected Ok, got " ^ pp_cause cause)

let expect_ok_int label expected = function
  | Eta.Exit.Ok actual when actual = expected -> ()
  | Eta.Exit.Ok actual ->
      fail (Printf.sprintf "%s: expected Ok %d, got Ok %d" label expected actual)
  | Eta.Exit.Error cause ->
      fail (Printf.sprintf "%s: expected Ok %d, got %s" label expected (pp_cause cause))

let expect_fail label pred = function
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Error cause ->
      fail (Printf.sprintf "%s: expected typed failure, got %s" label (pp_cause cause))
  | Eta.Exit.Ok value ->
      fail (Printf.sprintf "%s: expected typed failure, got Ok %d" label value)

let expect_interrupt label = function
  | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause -> ()
  | Eta.Exit.Error cause ->
      fail (Printf.sprintf "%s: expected interrupt, got %s" label (pp_cause cause))
  | Eta.Exit.Ok value ->
      fail (Printf.sprintf "%s: expected interrupt, got Ok %d" label value)

let expect_die label = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      fail (Printf.sprintf "%s: expected defect, got %s" label (pp_cause cause))
  | Eta.Exit.Ok value ->
      fail (Printf.sprintf "%s: expected defect, got Ok %d" label value)

let mixed_interrupt_failure_cause () =
  Eta.Cause.concurrent [ Eta.Cause.interrupt; Eta.Cause.fail (`Mixed 1) ]

let mixed_interrupt_failure_effect () =
  Eta.Effect.Expert.make ~leaf_name:"test.cache.mixed_interrupt" @@ fun _context ->
  Eta.Exit.Error (mixed_interrupt_failure_cause ())

let expect_mixed_interrupt_failure label = function
  | Eta.Exit.Error cause
    when Eta.Cause.equal ( = ) (mixed_interrupt_failure_cause ()) cause ->
      ()
  | Eta.Exit.Error cause ->
      fail
        (Printf.sprintf "%s: expected mixed interrupt/failure, got %s" label
           (pp_cause cause))
  | Eta.Exit.Ok value ->
      fail
        (Printf.sprintf "%s: expected mixed interrupt/failure, got Ok %d" label
           value)

let runtime_interrupt_effect () =
  Eta.Effect.Expert.make ~leaf_name:"test.cache.interrupt" @@ fun context ->
  let contract = Eta.Effect.Expert.contract context in
  contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
  contract.Eta.Runtime_contract.cancel cancel_context Exit;
  contract.Eta.Runtime_contract.await_cancel ()

let make_cache ?(capacity = 16)
    ?(time_to_live = fun _exit _key -> Eta.Duration.seconds 60) lookup =
  Int_cache.make ~capacity ~lookup ~time_to_live

let rec get_keys cache acc = function
  | [] -> Eta.Effect.pure (List.rev acc)
  | key :: rest ->
      Int_cache.get cache key
      |> Eta.Effect.bind (fun value -> get_keys cache (value :: acc) rest)

let run_test done_ program check =
  run program ~on_result:(finish done_ (fun result -> check (expect_ok result)))

let test_single_flight done_ =
  let calls = ref 0 in
  let lookup key =
    Eta.Effect.sync (fun () -> incr calls)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.delay (Eta.Duration.ms 1)
             (Eta.Effect.pure (key * 10)))
  in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.all [ Int_cache.get cache 4; Int_cache.get cache 4 ]
           |> Eta.Effect.map (fun values -> (values, !calls)))
  in
  run_test done_ program @@ fun (values, calls) ->
  if values <> [ 40; 40 ] then fail "single-flight values mismatch";
  if calls <> 1 then fail "single-flight lookup count mismatch"

let test_typed_failure_caching done_ =
  let calls = ref 0 in
  let lookup _key =
    Eta.Effect.sync (fun () -> incr calls)
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail (`Missing 1))
  in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.all
             [
               Eta.Effect.exit (Int_cache.get cache 9);
               Eta.Effect.exit (Int_cache.get cache 9);
             ]
           |> Eta.Effect.map (fun exits -> (exits, !calls)))
  in
  run_test done_ program @@ fun (exits, calls) ->
  List.iter (expect_fail "cached failure" (( = ) (`Missing 1))) exits;
  if calls <> 1 then fail "typed failure lookup count mismatch"

let test_ttl_zero done_ =
  let calls = ref 0 in
  let lookup key = Eta.Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let program =
    make_cache ~time_to_live:(fun _exit _key -> Eta.Duration.zero) lookup
    |> Eta.Effect.bind (fun cache ->
           Int_cache.get cache 6
           |> Eta.Effect.bind (fun first ->
                  Int_cache.get cache 6
                  |> Eta.Effect.map (fun second -> (first, second, !calls))))
  in
  run_test done_ program @@ fun (first, second, calls) ->
  if (first, second, calls) <> (61, 62, 2) then fail "ttl zero mismatch"

let test_ttl_expiry done_ =
  let calls = ref 0 in
  let lookup key = Eta.Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let program =
    make_cache ~time_to_live:(fun _exit _key -> Eta.Duration.ms 1) lookup
    |> Eta.Effect.bind (fun cache ->
           Int_cache.get cache 5
           |> Eta.Effect.bind (fun first ->
                  Eta.Effect.delay (Eta.Duration.ms 5) (Int_cache.get cache 5)
                  |> Eta.Effect.map (fun second -> (first, second, !calls))))
  in
  run_test done_ program @@ fun (first, second, calls) ->
  if (first, second, calls) <> (51, 52, 2) then fail "ttl expiry mismatch"

let test_invalidate done_ =
  let calls = ref 0 in
  let lookup key = Eta.Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Int_cache.get cache 1
           |> Eta.Effect.bind (fun first ->
                  Int_cache.invalidate cache 1
                  |> Eta.Effect.bind (fun () ->
                         Int_cache.get cache 1
                         |> Eta.Effect.map (fun second -> (first, second, !calls)))))
  in
  run_test done_ program @@ fun (first, second, calls) ->
  if (first, second, calls) <> (11, 12, 2) then fail "invalidate mismatch"

let test_invalidate_all done_ =
  let calls = ref 0 in
  let lookup key = Eta.Effect.sync (fun () -> incr calls; key * 10 + !calls) in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           get_keys cache [] [ 1; 2 ]
           |> Eta.Effect.bind (fun before ->
                  Int_cache.invalidate_all cache
                  |> Eta.Effect.bind (fun () ->
                         get_keys cache [] [ 1; 2 ]
                         |> Eta.Effect.map (fun after -> (before, after, !calls)))))
  in
  run_test done_ program @@ fun (before, after, calls) ->
  if before <> [ 11; 22 ] || after <> [ 13; 24 ] || calls <> 4 then
    fail "invalidate_all mismatch"

let test_refresh done_ =
  let source = ref 1 in
  let calls = ref 0 in
  let lookup _key = Eta.Effect.sync (fun () -> incr calls; !source) in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Int_cache.get cache 1
           |> Eta.Effect.bind (fun first ->
                  Eta.Effect.sync (fun () -> source := 2)
                  |> Eta.Effect.bind (fun () ->
                         Int_cache.refresh cache 1
                         |> Eta.Effect.bind (fun refreshed ->
                                Int_cache.get cache 1
                                |> Eta.Effect.map (fun cached ->
                                       (first, refreshed, cached, !calls))))))
  in
  run_test done_ program @@ fun (first, refreshed, cached, calls) ->
  if (first, refreshed, cached, calls) <> (1, 2, 2, 2) then fail "refresh mismatch"

let test_lru_eviction done_ =
  let calls = ref 0 in
  let lookup key = Eta.Effect.sync (fun () -> incr calls; key) in
  let program =
    make_cache ~capacity:2 lookup
    |> Eta.Effect.bind (fun cache ->
           get_keys cache [] [ 1; 2; 1; 3; 1; 2 ]
           |> Eta.Effect.map (fun _values -> !calls))
  in
  run_test done_ program @@ fun calls ->
  if calls <> 4 then fail "LRU eviction lookup count mismatch"

let test_stats done_ =
  let calls = ref 0 in
  let lookup key =
    Eta.Effect.sync (fun () -> incr calls)
    |> Eta.Effect.bind (fun () ->
           if key = 9 then Eta.Effect.fail `Bad else Eta.Effect.pure key)
  in
  let program =
    make_cache ~capacity:10
      ~time_to_live:(fun _exit _key -> Eta.Duration.ms 1)
      lookup
    |> Eta.Effect.bind (fun cache ->
           Int_cache.get cache 1
           |> Eta.Effect.bind (fun _ ->
                  Int_cache.get cache 1
                  |> Eta.Effect.bind (fun _ ->
                         Eta.Effect.delay (Eta.Duration.ms 5) (Int_cache.get cache 1)
                         |> Eta.Effect.bind (fun _ ->
                                Eta.Effect.exit (Int_cache.get cache 9)
                                |> Eta.Effect.bind (fun failure ->
                                       Int_cache.stats cache
                                       |> Eta.Effect.map (fun stats ->
                                              (failure, stats, !calls)))))))
  in
  run_test done_ program @@ fun (failure, stats, calls) ->
  expect_fail "stats failure" (( = ) `Bad) failure;
  if calls <> 3 then fail "stats lookup count mismatch";
  if stats.Int_cache.hits <> 1 || stats.misses <> 3 || stats.loads <> 3
     || stats.load_failures <> 1 || stats.evictions <> 0
     || stats.expirations <> 1 || stats.current_size <> 2
  then fail "stats counters mismatch"

let test_defect_not_cached done_ =
  let calls = ref 0 in
  let lookup _key =
    Eta.Effect.sync (fun () ->
        incr calls;
        raise (Failure "boom"))
  in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.exit (Int_cache.get cache 1)
           |> Eta.Effect.bind (fun first ->
                  Eta.Effect.exit (Int_cache.get cache 1)
                  |> Eta.Effect.map (fun second -> (first, second, !calls))))
  in
  run_test done_ program @@ fun (first, second, calls) ->
  expect_die "first defect" first;
  expect_die "second defect" second;
  if calls <> 2 then fail "defect lookup count mismatch"

let test_interruption_retry done_ =
  let calls = ref 0 in
  let lookup _key =
    Eta.Effect.sync (fun () -> incr calls; !calls)
    |> Eta.Effect.bind (function
         | 1 ->
             Eta.Effect.yield
             |> Eta.Effect.bind (fun () -> runtime_interrupt_effect ())
         | _ -> Eta.Effect.pure 42)
  in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.all
             [
               Eta.Effect.exit (Int_cache.get cache 1);
               Eta.Effect.exit (Int_cache.get cache 1);
             ]
           |> Eta.Effect.bind (fun interrupted ->
                  Eta.Effect.exit (Int_cache.get cache 1)
                  |> Eta.Effect.map (fun retried -> (interrupted, retried, !calls))))
  in
  run_test done_ program @@ fun (interrupted, retried, calls) ->
  List.iter (expect_interrupt "interrupted waiter") interrupted;
  expect_ok_int "retried after interruption" 42 retried;
  if calls <> 2 then fail "interruption retry lookup count mismatch"

let test_mixed_interruption_failure_retry done_ =
  let calls = ref 0 in
  let lookup _key =
    Eta.Effect.sync (fun () -> incr calls; !calls)
    |> Eta.Effect.bind (function
         | 1 -> mixed_interrupt_failure_effect ()
         | _ -> Eta.Effect.pure 42)
  in
  let program =
    make_cache lookup
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.exit (Int_cache.get cache 1)
           |> Eta.Effect.bind (fun mixed ->
                  Eta.Effect.exit (Int_cache.get cache 1)
                  |> Eta.Effect.map (fun retried -> (mixed, retried, !calls))))
  in
  run_test done_ program @@ fun (mixed, retried, calls) ->
  expect_mixed_interrupt_failure "first mixed lookup" mixed;
  expect_ok_int "retried after mixed interruption" 42 retried;
  if calls <> 2 then fail "mixed interruption lookup count mismatch"

let tests =
  [
    ("single-flight", test_single_flight);
    ("typed failure caching", test_typed_failure_caching);
    ("TTL zero", test_ttl_zero);
    ("TTL expiry", test_ttl_expiry);
    ("invalidate", test_invalidate);
    ("invalidate_all", test_invalidate_all);
    ("refresh", test_refresh);
    ("LRU eviction", test_lru_eviction);
    ("stats", test_stats);
    ("defect retry", test_defect_not_cached);
    ("interruption retry", test_interruption_retry);
    ("mixed interruption + typed failure retry", test_mixed_interruption_failure_retry);
  ]

let rec run_tests = function
  | [] -> log "eta_cache_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_cache_jsoo failed: " ^ Printexc.to_string exn)
