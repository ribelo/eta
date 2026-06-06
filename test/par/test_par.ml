(* Correctness tests for Eta.Par. *)

let check_int = Alcotest.(check int)
let check_int_array = Alcotest.(check (array int))
let check_float_array = Alcotest.(check (array (float 0.0)))

(* --- Pool lifecycle -------------------------------------------------------- *)

let test_pool_run_returns_value () =
  let r =
    Eta.Par.Pool.with_pool ~n_workers:4 (fun pool ->
      Eta.Par.Pool.run pool (fun () -> 42))
  in
  check_int "pool returns value" 42 r

let test_pool_propagates_exceptions () =
  let raised = ref false in
  (try
     Eta.Par.Pool.with_pool ~n_workers:2 (fun pool ->
       Eta.Par.Pool.run pool (fun () -> raise (Failure "boom")))
     |> ignore
   with Failure msg when msg = "boom" -> raised := true);
  Alcotest.(check bool) "exception propagated" true !raised

let test_top_level_run () =
  let r = Eta.Par.run ~n_workers:2 (fun () -> 7) in
  check_int "top-level run" 7 r

(* --- join ----------------------------------------------------------------- *)

let test_join_basic () =
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      let a, b = Eta.Par.join (fun () -> 10) (fun () -> 32) in
      a + b)
  in
  check_int "join sum" 42 r

let test_join_nested () =
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      let a, (b, c) =
        Eta.Par.join
          (fun () -> 1)
          (fun () -> Eta.Par.join (fun () -> 2) (fun () -> 3))
      in
      a + b + c)
  in
  check_int "nested join" 6 r

let test_join3 () =
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      let a, b, c =
        Eta.Par.join3 (fun () -> 1) (fun () -> 2) (fun () -> 3)
      in
      a + b + c)
  in
  check_int "join3" 6 r

(* Recursive fib via join — exercises the work-stealing + nesting path. *)
let rec pfib n =
  if n < 2 then n
  else if n < 20 then
    let rec sfib n = if n < 2 then n else sfib (n - 1) + sfib (n - 2) in
    sfib n
  else
    let a, b = Eta.Par.join (fun () -> pfib (n - 1)) (fun () -> pfib (n - 2)) in
    a + b

let test_join_fib () =
  let r = Eta.Par.run ~n_workers:4 (fun () -> pfib 25) in
  check_int "pfib 25" 75025 r

(* --- par_for / par_iter --------------------------------------------------- *)

let test_par_for () =
  let arr = Array.make 10_000 0 in
  Eta.Par.run ~n_workers:4 (fun () ->
    Eta.Par.par_for ~start:0 ~stop:(Array.length arr) (fun i -> arr.(i) <- i * 2));
  for i = 0 to Array.length arr - 1 do
    check_int (Printf.sprintf "arr.(%d)" i) (i * 2) arr.(i)
  done

let test_par_iter () =
  let n = 5_000 in
  let arr = Array.init n (fun i -> i) in
  let sum = Atomic.make 0 in
  Eta.Par.run ~n_workers:4 (fun () ->
    Eta.Par.par_iter arr (fun x -> ignore (Atomic.fetch_and_add sum x)));
  let expected = n * (n - 1) / 2 in
  check_int "par_iter sum" expected (Atomic.get sum)

(* --- par_map / par_mapi --------------------------------------------------- *)

let test_par_map () =
  let n = 1_000 in
  let arr = Array.init n (fun i -> i) in
  let doubled =
    Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_map arr (fun x -> x * 2))
  in
  let expected = Array.init n (fun i -> i * 2) in
  check_int_array "par_map doubles" expected doubled

let test_par_mapi () =
  let n = 1_000 in
  let arr = Array.init n (fun i -> i) in
  let summed =
    Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_mapi arr (fun i x -> i + x))
  in
  let expected = Array.init n (fun i -> i + i) in
  check_int_array "par_mapi adds index" expected summed

let test_par_map_float_output () =
  let arr = Array.init 1_000 (fun i -> i) in
  let mapped =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.par_map arr (fun i -> Float.of_int i /. 2.0))
  in
  let mapied =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.par_mapi arr (fun i x -> Float.of_int (i + x) /. 4.0))
  in
  check_float_array "par_map float output"
    (Array.init 1_000 (fun i -> Float.of_int i /. 2.0))
    mapped;
  check_float_array "par_mapi float output"
    (Array.init 1_000 (fun i -> Float.of_int (i + i) /. 4.0))
    mapied;
  Alcotest.(check int)
    "par_map returns a float array" Obj.double_array_tag
    (Obj.tag (Obj.repr mapped));
  Alcotest.(check int)
    "par_mapi returns a float array" Obj.double_array_tag
    (Obj.tag (Obj.repr mapied))

(* --- par_reduce ----------------------------------------------------------- *)

let test_par_reduce_sum () =
  let n = 10_000 in
  let arr = Array.init n (fun i -> i) in
  let s =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.par_reduce arr ~init:0 ~map:(fun x -> x) ~combine:( + ))
  in
  let expected = n * (n - 1) / 2 in
  check_int "par_reduce sum" expected s

let test_par_reduce_max () =
  let arr = Array.init 1_000 (fun i -> (i * 7919) mod 1_000_003) in
  let m =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.par_reduce arr ~init:min_int
        ~map:(fun x -> x)
        ~combine:max)
  in
  let expected = Array.fold_left max min_int arr in
  check_int "par_reduce max" expected m

(* --- par_sort ------------------------------------------------------------- *)

let test_par_sort_random () =
  let n = 10_000 in
  let rs = Random.State.make [| 42 |] in
  let arr = Array.init n (fun _ -> Random.State.int rs 1_000_000) in
  let expected = Array.copy arr in
  Array.sort compare expected;
  Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_sort arr compare);
  check_int_array "par_sort random matches Array.sort" expected arr

let test_par_sort_already_sorted () =
  let arr = Array.init 1_000 (fun i -> i) in
  let expected = Array.copy arr in
  Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_sort arr compare);
  check_int_array "par_sort sorted is no-op" expected arr

let test_par_sort_reverse () =
  let arr = Array.init 1_000 (fun i -> 1_000 - i) in
  let expected = Array.init 1_000 (fun i -> i + 1) in
  Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_sort arr compare);
  check_int_array "par_sort reversed" expected arr

(* --- Sequential threshold -------------------------------------------------- *)

let test_below_threshold_runs_serial () =
  (* When the range is below the default chunk size, it should still produce
     correct results.  This also catches off-by-one bugs in slicing. *)
  let arr = Array.init 100 (fun i -> i) in
  let doubled =
    Eta.Par.run ~n_workers:2 (fun () -> Eta.Par.par_map arr (fun x -> x * 2))
  in
  let expected = Array.init 100 (fun i -> i * 2) in
  check_int_array "below-threshold map" expected doubled

(* --- Stress / regression tests for the bugs called out in review ---------- *)

(* Deep recursion in [par_for]: with [chunk = 1] over N items the
   recursive halver makes ~N internal join calls, with the right spine
   reaching depth log2(N).  On the old eager scheduler this would have
   silently overflowed the fixed-size local stack (cap 32) and Chase-Lev
   deque (cap 64) once depth exceeded those bounds.  The heartbeat
   scheduler stores frames in a heap-allocated linked list and is bounded
   only by available memory, so this test passes deterministically. *)
let test_par_for_deep_recursion () =
  let n = 200_000 in
  let arr = Array.make n 0 in
  Eta.Par.run ~n_workers:4 (fun () ->
    Eta.Par.par_for ~chunk:1 ~start:0 ~stop:n (fun i -> arr.(i) <- i + 1));
  for i = 0 to n - 1 do
    if arr.(i) <> i + 1 then
      Alcotest.failf "arr.(%d) = %d, expected %d" i arr.(i) (i + 1)
  done

(* Same idea for [par_map]: forces deep recursion over a non-trivial
   payload (a per-element float computation), exercising both the
   join-chain depth and parallel writes into a pre-allocated output. *)
let test_par_map_deep_recursion () =
  let n = 100_000 in
  let arr = Array.init n (fun i -> i) in
  let out =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.par_map ~chunk:1 arr (fun i -> i * 3 + 1))
  in
  for i = 0 to n - 1 do
    if out.(i) <> i * 3 + 1 then
      Alcotest.failf "out.(%d) = %d, expected %d" i out.(i) (i * 3 + 1)
  done

(* Exception inside the body of [par_for] must propagate.  Under the
   old [fork_unit] this would have deadlocked the worker because the
   parent's [strands] counter never reached 1 — the unwound child
   skipped [finish_child].  Under the heartbeat scheduler [join]
   captures both [a]'s and [b]'s exceptions, processes the surviving
   side fully, then re-raises. *)
exception Boom of int

let test_par_for_exception_propagates () =
  let raised = ref false in
  (try
     Eta.Par.run ~n_workers:4 (fun () ->
       Eta.Par.par_for ~chunk:1 ~start:0 ~stop:1000 (fun i ->
         if i = 537 then raise (Boom i)))
   with Boom 537 -> raised := true);
  Alcotest.(check bool) "par_for exception propagated" true !raised

let test_par_map_exception_propagates () =
  let raised = ref false in
  let arr = Array.init 1_000 (fun i -> i) in
  (try
     let _ : int array =
       Eta.Par.run ~n_workers:4 (fun () ->
         Eta.Par.par_map ~chunk:1 arr (fun x ->
           if x = 412 then raise (Boom x) else x * 2))
     in
     ()
   with Boom 412 -> raised := true);
  Alcotest.(check bool) "par_map exception propagated" true !raised

let test_par_reduce_exception_propagates () =
  let raised = ref false in
  let arr = Array.init 1_000 (fun i -> i) in
  (try
     let _ : int =
       Eta.Par.run ~n_workers:4 (fun () ->
         Eta.Par.par_reduce ~chunk:1 arr ~init:0
           ~map:(fun x -> if x = 700 then raise (Boom x) else x)
           ~combine:( + ))
     in
     ()
   with Boom 700 -> raised := true);
  Alcotest.(check bool) "par_reduce exception propagated" true !raised

(* Exception inside a directly-called [join] follows the same path as
   the combinator-internal join; double-check both sides. *)
let test_join_left_exception () =
  let raised = ref false in
  (try
     let _ : int * int =
       Eta.Par.run ~n_workers:2 (fun () ->
         Eta.Par.join (fun () -> raise (Boom 1)) (fun () -> 2))
     in
     ()
   with Boom 1 -> raised := true);
  Alcotest.(check bool) "join left exception" true !raised

let test_join_right_exception () =
  let raised = ref false in
  (try
     let _ : int * int =
       Eta.Par.run ~n_workers:2 (fun () ->
         Eta.Par.join (fun () -> 1) (fun () -> raise (Boom 2)))
     in
     ()
   with Boom 2 -> raised := true);
  Alcotest.(check bool) "join right exception" true !raised

(* par_sort on an all-equal array.  With Lomuto partitioning the
   partition index always lands at [hi], producing maximally
   unbalanced recursion of depth N — which under the old fixed-size
   local stack would silently corrupt parent frames once depth
   exceeded the cap.  Three-way (Dutch flag) partitioning collapses
   the equal-segment in a single partition step. *)
let test_par_sort_all_equal () =
  let n = 50_000 in
  let arr = Array.make n 7 in
  let expected = Array.copy arr in
  Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_sort arr compare);
  check_int_array "par_sort all-equal" expected arr

(* par_sort on an array with many duplicate keys: also catches Lomuto
   regressions on inputs with low entropy. *)
let test_par_sort_few_distinct () =
  let n = 20_000 in
  let rs = Random.State.make [| 17 |] in
  let arr = Array.init n (fun _ -> Random.State.int rs 4) in
  let expected = Array.copy arr in
  Array.sort compare expected;
  Eta.Par.run ~n_workers:4 (fun () -> Eta.Par.par_sort arr compare);
  check_int_array "par_sort 4-distinct values" expected arr

(* Heartbeat behaviour: with multiple workers and a workload large
   enough to outlast one heartbeat tick, work actually gets
   distributed across domains.  We count distinct [Domain.self ()]
   ids touched inside the body. *)
let test_par_for_uses_multiple_workers () =
  let n = 200_000 in
  let arr = Array.make n 0 in
  Eta.Par.run ~n_workers:4 ~heartbeat_interval_ns:10_000 (fun () ->
    Eta.Par.par_for ~chunk:1 ~start:0 ~stop:n (fun i ->
      arr.(i) <- (Domain.self () :> int)));
  let seen = Hashtbl.create 8 in
  Array.iter (fun d -> Hashtbl.replace seen d ()) arr;
  let n_workers = Hashtbl.length seen in
  if n_workers < 2 then
    Alcotest.failf
      "expected work to be distributed across ≥2 domains, only saw %d"
      n_workers

(* Very deep [join] chain: forces a long cactus-stack of pending
   jobs, exercising the linked-list pop-front-for-promotion path.
   Mirrors chili's [join_very_long] regression. *)
let rec deep_join_count s e =
  if s >= e then 0
  else if s + 1 = e then 1
  else
    let mid = s + ((e - s) / 2) in
    let l, r =
      Eta.Par.join (fun () -> deep_join_count s mid)
                   (fun () -> deep_join_count mid e)
    in
    l + r

let test_join_very_long () =
  let n = 1 lsl 16 in
  let r = Eta.Par.run ~n_workers:4 (fun () -> deep_join_count 0 n) in
  check_int "deep_join_count" n r

(* --- Iter (parallel iterators) -------------------------------------------- *)

let test_iter_of_array_sum () =
  let arr = Array.init 10_000 (fun i -> i) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> sum))
  in
  check_int "iter sum" (10_000 * 9_999 / 2) r

let test_iter_of_range_sum () =
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_range ~start:0 ~stop:10_000 () |> sum))
  in
  check_int "iter range sum" (10_000 * 9_999 / 2) r

let test_iter_map_reduce () =
  let arr = Array.init 1_000 (fun i -> i + 1) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(
        of_array arr
        |> map (fun x -> x * x)
        |> reduce ~init:0 ~combine:( + )))
  in
  let expected = Array.fold_left (fun a x -> a + x * x) 0 arr in
  check_int "map then reduce" expected r

let test_iter_filter_count () =
  let n = 10_000 in
  let arr = Array.init n (fun i -> i) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(
        of_array arr
        |> filter (fun x -> x mod 3 = 0)
        |> count))
  in
  check_int "filter count" ((n + 2) / 3) r

let test_iter_collect_array_filter () =
  let arr = Array.init 1_000 (fun i -> i) in
  let result =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(
        of_array arr
        |> filter (fun x -> x mod 7 = 0)
        |> map (fun x -> x * 2)
        |> collect_array))
  in
  let expected =
    Array.of_list
      (List.filter_map
         (fun x -> if x mod 7 = 0 then Some (x * 2) else None)
         (Array.to_list arr))
  in
  check_int_array "filter + map + collect" expected result

let test_iter_for_each_side_effect () =
  let arr = Array.init 1_000 (fun i -> i) in
  let acc = Atomic.make 0 in
  Eta.Par.run ~n_workers:4 (fun () ->
    Eta.Par.Iter.(
      of_array arr
      |> map (fun x -> x + 1)
      |> for_each (fun x -> Atomic.fetch_and_add acc x |> ignore)));
  check_int "for_each total" (Array.fold_left (fun a x -> a + x + 1) 0 arr)
    (Atomic.get acc)

let test_iter_find_any_present () =
  let n = 100_000 in
  let arr = Array.init n (fun i -> i) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> find_any (fun x -> x = 12_345)))
  in
  match r with
  | Some 12_345 -> ()
  | _ -> Alcotest.fail "find_any: expected Some 12345"

let test_iter_find_any_absent () =
  let arr = Array.init 10_000 (fun i -> i) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> find_any (fun x -> x < 0)))
  in
  Alcotest.(check (option int)) "find_any absent" None r

let test_iter_any_all () =
  let arr = Array.init 1_000 (fun i -> i) in
  let any_pos =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> any (fun x -> x > 500)))
  in
  let all_nonneg =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> all (fun x -> x >= 0)))
  in
  Alcotest.(check bool) "any > 500" true any_pos;
  Alcotest.(check bool) "all >= 0" true all_nonneg

let test_iter_min_max () =
  let arr = [| 3; 1; 4; 1; 5; 9; 2; 6; 5; 3; 5 |] in
  let min_v =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> min))
  in
  let max_v =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(of_array arr |> max))
  in
  Alcotest.(check (option int)) "min" (Some 1) min_v;
  Alcotest.(check (option int)) "max" (Some 9) max_v

let test_iter_chunk_one_stress () =
  (* Force every step through join to surface scheduler bugs. *)
  let n = 50_000 in
  let arr = Array.init n (fun i -> i) in
  let r =
    Eta.Par.run ~n_workers:4 (fun () ->
      Eta.Par.Iter.(
        of_array ~chunk:1 arr
        |> map (fun x -> x * 2)
        |> sum))
  in
  check_int "chunk=1 deep recursion" (n * (n - 1)) r

(* --- Suite ---------------------------------------------------------------- *)

let () =
  Alcotest.run "par"
    [
      ( "pool",
        [
          ("run returns value", `Quick, test_pool_run_returns_value);
          ("propagates exceptions", `Quick, test_pool_propagates_exceptions);
          ("top-level run", `Quick, test_top_level_run);
        ] );
      ( "join",
        [
          ("basic", `Quick, test_join_basic);
          ("nested", `Quick, test_join_nested);
          ("join3", `Quick, test_join3);
          ("fib via join", `Quick, test_join_fib);
          ("left exception", `Quick, test_join_left_exception);
          ("right exception", `Quick, test_join_right_exception);
          ("very long chain", `Quick, test_join_very_long);
        ] );
      ( "par_for_iter",
        [
          ("par_for", `Quick, test_par_for);
          ("par_iter", `Quick, test_par_iter);
          ("deep recursion (chunk=1)", `Quick, test_par_for_deep_recursion);
          ("exception propagates", `Quick, test_par_for_exception_propagates);
          ("uses multiple workers", `Quick, test_par_for_uses_multiple_workers);
        ] );
      ( "par_map",
        [
          ("par_map", `Quick, test_par_map);
          ("par_mapi", `Quick, test_par_mapi);
          ("float output", `Quick, test_par_map_float_output);
          ("below threshold", `Quick, test_below_threshold_runs_serial);
          ("deep recursion (chunk=1)", `Quick, test_par_map_deep_recursion);
          ("exception propagates", `Quick, test_par_map_exception_propagates);
        ] );
      ( "par_reduce",
        [
          ("sum", `Quick, test_par_reduce_sum);
          ("max", `Quick, test_par_reduce_max);
          ("exception propagates", `Quick, test_par_reduce_exception_propagates);
        ] );
      ( "par_sort",
        [
          ("random", `Quick, test_par_sort_random);
          ("already sorted", `Quick, test_par_sort_already_sorted);
          ("reverse", `Quick, test_par_sort_reverse);
          ("all equal", `Quick, test_par_sort_all_equal);
          ("few distinct keys", `Quick, test_par_sort_few_distinct);
        ] );
      ( "iter",
        [
          ("of_array sum", `Quick, test_iter_of_array_sum);
          ("of_range sum", `Quick, test_iter_of_range_sum);
          ("map then reduce", `Quick, test_iter_map_reduce);
          ("filter count", `Quick, test_iter_filter_count);
          ("filter + map + collect", `Quick, test_iter_collect_array_filter);
          ("for_each side eff", `Quick, test_iter_for_each_side_effect);
          ("find_any present", `Quick, test_iter_find_any_present);
          ("find_any absent", `Quick, test_iter_find_any_absent);
          ("any/all", `Quick, test_iter_any_all);
          ("min/max", `Quick, test_iter_min_max);
          ("chunk=1 stress", `Quick, test_iter_chunk_one_stress);
        ] );
    ]
