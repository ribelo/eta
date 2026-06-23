open Eta

let run_exit rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok a -> a
  | Exit.Error _ ->
      failwith "cache effect failed unexpectedly: the cache effect itself should never fail"

let make_lookup ?(slow = true) () : (int, int, [> `Lookup_failed ]) Cache_probe.lookup =
  {
    run =
      (fun key ->
        let wait = if slow then Effect.sleep (Duration.ms 5) else Effect.unit in
        wait |> Effect.bind (fun () -> Effect.pure (key * 100)));
    calls = 0;
    fail_next = false;
  }

let with_rt f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f rt

(* Build the cache inside the runtime (creation needs the runtime contract),
   then run the body. *)
let with_cache
    ?(capacity = 0)
    ?(ttl_ms = fun (_ : (int, _) Exit.t) -> 1_000_000)
    ?(now_ms = fun () -> 0)
    ?slow
    f =
  with_rt (fun rt ->
      run_exit rt
        (Cache_probe.create ~capacity ~ttl_ms ~now_ms
           ~lookup:(make_lookup ?slow ())
         |> Effect.bind f))

let seq_gets c ks f =
  (* Left-fold a list of gets, ignoring each Exit, then run [f]. *)
  let rec loop acc = function
    | [] -> f acc
    | k :: rest ->
        Cache_probe.get c k |> Effect.bind (fun _exit -> loop (_exit :: acc) rest)
  in
  loop [] ks

(* --- single-flight tests ------------------------------------------------- *)

let test_single_flight_exactly_once () =
  let calls = ref 0 and got = ref [] in
  with_cache (fun c ->
      Effect.all (List.init 8 (fun _ -> Cache_probe.get c 7))
      |> Effect.bind (fun results ->
             calls := c.lookup.calls;
             got := results;
             Effect.unit));
  let vals = List.map Exit.get_success !got in
  Alcotest.(check int) "lookup ran exactly once" 1 !calls;
  Alcotest.(check (list (option int)))
    "all 8 getters received the same value"
    (List.init 8 (fun _ -> Some 700)) vals

let test_hit_does_not_recompute () =
  let calls = ref 0 in
  with_cache ~slow:false (fun c ->
      seq_gets c [ 3; 3 ] (fun _ -> (calls := c.lookup.calls; Effect.unit)));
  Alcotest.(check int) "second get served from cache" 1 !calls

let test_failure_cached_and_replayed () =
  let calls = ref 0 and all_failed = ref false in
  with_cache (fun c ->
      c.lookup.fail_next <- true;
      Effect.all (List.init 6 (fun _ -> Cache_probe.get c 9))
      |> Effect.bind (fun results ->
             calls := c.lookup.calls;
             all_failed := List.for_all Exit.is_error results;
             Effect.unit));
  Alcotest.(check int) "failing lookup ran exactly once" 1 !calls;
  Alcotest.(check bool) "every getter received the cached failure" true !all_failed

(* lookup-cancellation (a cancelled lookup must free its slot for retry) is
   NOT covered here. In Eta, interruption is not a catchable typed failure
   ([Effect.catch] explicitly excludes interruption; effect.mli:161). Current
   Eta does expose [on_interrupt] and exit-aware finalizers, but this fixture
   has not exercised removing a [Pending] entry through those cleanup hooks.
   The recommendation's interruption claim is therefore Unproven — see verdict. *)

let test_invalidate_forces_recall () =
  let calls = ref 0 in
  with_cache ~slow:false (fun c ->
      Cache_probe.get c 1
      |> Effect.bind (fun _ ->
             Cache_probe.invalidate c 1
             |> Effect.bind (fun () ->
                    Cache_probe.get c 1
                    |> Effect.bind (fun _ -> calls := c.lookup.calls; Effect.unit))));
  Alcotest.(check int) "invalidate forced a second lookup" 2 !calls

let test_ttl_expiry_recalls () =
  let calls1 = ref 0 and calls2 = ref 0 and calls3 = ref 0 in
  let clock = ref 0 in
  with_cache ~ttl_ms:(fun _ -> 10_000) ~now_ms:(fun () -> !clock) ~slow:false
    (fun c ->
      Cache_probe.get c 4
      |> Effect.bind (fun _ ->
             calls1 := c.lookup.calls;
             clock := 10_000;
             Cache_probe.get c 4
             |> Effect.bind (fun _ -> calls2 := c.lookup.calls; Effect.unit)));
  with_cache ~ttl_ms:(fun _ -> 0) ~now_ms:(fun () -> 0) ~slow:false (fun c ->
      seq_gets c [ 5; 5 ] (fun _ -> (calls3 := c.lookup.calls; Effect.unit)));
  Alcotest.(check int) "first get computed" 1 !calls1;
  Alcotest.(check int) "expired entry recomputed" 2 !calls2;
  Alcotest.(check int) "ttl 0 never caches" 2 !calls3

let test_capacity_eviction () =
  let calls = ref 0 in
  with_cache ~capacity:2 ~slow:false (fun c ->
      (* insert 1,2,3 (evicts oldest 1); survivors 2,3 hit; evicted 1 recomputes *)
      seq_gets c [ 1; 2; 3; 2; 3; 1 ] (fun _ -> (calls := c.lookup.calls; Effect.unit)));
  (* 3 distinct misses (1,2,3) + 1 recompute of evicted 1 = 4; 2 and 3 hit. *)
  Alcotest.(check int) "evicted oldest recomputes; survivors cached" 4 !calls

let () =
  Alcotest.run "eta_cache_fixture"
    [
      ( "single_flight",
        [
          Alcotest.test_case "exactly once under contention" `Quick
            test_single_flight_exactly_once;
          Alcotest.test_case "hit does not recompute" `Quick
            test_hit_does_not_recompute;
          Alcotest.test_case "failure cached and replayed" `Quick
            test_failure_cached_and_replayed;
        ] );
      ( "invalidation_and_ttl",
        [
          Alcotest.test_case "invalidate forces recall" `Quick
            test_invalidate_forces_recall;
          Alcotest.test_case "ttl expiry recalls; ttl 0 never caches" `Quick
            test_ttl_expiry_recalls;
        ] );
      ( "eviction",
        [
          Alcotest.test_case "capacity evicts oldest" `Quick test_capacity_eviction;
        ] );
    ]
