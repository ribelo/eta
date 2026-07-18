(* Real-use workloads, mirrored 1:1 with bench/runtime_overhead_ts/realuse_*.
 *
 * These exercise the slices of Eta that have a fair Effect-v4
 * counterpart: bounded/unbounded concurrent fanout, retry over a
 * Schedule with a flaky operation, a pipeline of binds with one
 * caught failure, and nested resource acquire/release scopes.
 *
 * Each workload pays the full "real entry point" cost on the OCaml
 * side: a fresh Eio_main.run + Switch.run + Eta_eio.Runtime.create per
 * sample. This matches what a user pays at the boundary of a binary;
 * it is comparable to what `Effect.runSync` charges per call on the
 * Bun side.
 *)

open Eta

let sink = ref 0

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt program with
  | Exit.Ok v -> sink := v
  | Exit.Error _ -> failwith "unexpected failure"

(* A small bind chain used as per-task work in fanout rows. 50 steps
   match the TS counterpart so per-task allocation profiles agree. *)
let bind_chain n =
  let rec go i acc =
    if i = 0 then acc
    else go (i - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)
  in
  go n (Effect.pure 0)

(* ---- realuse.fanout.par.success.64x50 ----
   64 concurrent tasks, each a 50-step bind chain, all succeed.  *)
let fanout_par_64x50 () =
  let task _ = Effect.map (fun _ -> 1) (bind_chain 50) in
  Effect.map (List.fold_left ( + ) 0)
    (Effect.map_par task (List.init 64 Fun.id))

(* ---- realuse.fanout.bounded.512x50.k=8 ----
   512 concurrent tasks bounded to 8 in flight, each a 50-step bind
   chain.  *)
let fanout_bounded_512x50_k8 () =
  let task _ = Effect.map (fun _ -> 1) (bind_chain 50) in
  Effect.map (List.fold_left ( + ) 0)
    (Effect.map_par ~max_concurrent:8 task (List.init 512 Fun.id))

(* ---- realuse.retry.flaky.fail4_then_ok ----
   Operation fails 4 times before succeeding. Schedule.recurs 10
   gives more attempts than needed; the schedule terminates because
   the 5th attempt succeeds.  Repeated 100 times per sample to put
   the per-row wall above the timer floor.  *)
let retry_flaky () =
  let counter = ref 0 in
  let attempt =
    Effect.sync (fun () ->
        let n = !counter + 1 in
        counter := n;
        n)
  in
  let flaky =
    Effect.bind
      (fun n -> if n < 5 then Effect.fail `Boom else Effect.pure n)
      attempt
  in
  let one_run =
    counter := 0;
    Effect.retry ~schedule:(Schedule.recurs 10) ~while_:(fun (_ : [ `Boom ]) -> true) flaky
  in
  let rec loop n acc =
    if n = 0 then Effect.pure acc
    else
      Effect.bind
        (fun v ->
          counter := 0;
          loop (n - 1) (acc + v))
        one_run
  in
  loop 100 0

(* ---- realuse.pipeline.bind_catch.1k ----
   1000-step bind chain. Halfway through, a typed failure is raised
   and caught, then the remaining steps run to completion.  *)
let pipeline_bind_catch_1k () =
  let prefix = bind_chain 500 in
  let with_failure_then_recover =
    Effect.bind
      (fun acc ->
        Effect.bind_error
          (fun (_ : [ `Boom ]) -> Effect.pure acc)
          (Effect.fail `Boom))
      prefix
  in
  let suffix base =
    let rec go i acc =
      if i = 0 then acc
      else go (i - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)
    in
    go 500 (Effect.pure base)
  in
  Effect.bind suffix with_failure_then_recover

(* ---- realuse.scope.acquire_release.64 ----
   64 nested acquire_release scopes, each acquires a counter, threads
   the value through the inner eff, and releases on exit.  *)
let scope_acquire_release_64 () =
  let counter = ref 0 in
  let acquire_one =
    Effect.acquire_release
      ~acquire:
        (Effect.sync (fun () ->
             incr counter;
             !counter))
      ~release:(fun _ ->
        Effect.sync (fun () ->
            decr counter;
            ()))
  in
  let rec build depth =
    if depth = 0 then Effect.pure 0
    else Effect.bind (fun v -> Effect.map (( + ) v) (build (depth - 1))) acquire_one
  in
  Effect.with_scope (build 64)

(* ---- workload registration ---- *)

let workload name run = { Bench_lib.name = "realuse." ^ name; run; samples = None }

let workloads =
  [
    workload "fanout.par.success.64x50" (fun () ->
        run_effect (fanout_par_64x50 ()));
    workload "fanout.bounded.512x50.k=8" (fun () ->
        run_effect (fanout_bounded_512x50_k8 ()));
    workload "retry.flaky.fail4_then_ok" (fun () -> run_effect (retry_flaky ()));
    workload "pipeline.bind_catch.1k" (fun () ->
        run_effect (pipeline_bind_catch_1k ()));
    workload "scope.acquire_release.64" (fun () ->
        run_effect (scope_acquire_release_64 ()));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
