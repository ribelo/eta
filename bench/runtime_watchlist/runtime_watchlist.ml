(* Focused regression watchlist for the four rows locked in after the v2
   direct-runtime ship. Lower-is-better composite score combines:

     - overhead.eta.bind.100k.prebuilt        (zero-allocation bind)
     - overhead.eta.fail_catch.100k.prebuilt  (typed fail/catch round trip)
     - overhead.eta.pure.reused_rt            (warm pure cost)
     - realuse.retry.flaky.fail4_then_ok      (retry on a Schedule)

   Allocation invariants (hard constraints):
     - bind.100k.prebuilt minor_words MUST stay 0
     - retry.flaky.fail4_then_ok minor_words MUST stay 0
     - pure.reused_rt minor_words MUST stay 0

   Composite score is normalized against the v2 ship baselines so each
   contribution starts at 1.0. Lower is better. Use the @watchlist-bench alias
   for a small focused run while optimizing these rows. *)

open Eta

let int_sink = ref 0
let one = Sys.opaque_identity 1

let run_eta_int rt program =
  match Runtime.run rt program with
  | Exit.Ok v -> int_sink := Sys.opaque_identity v
  | Exit.Error _ -> failwith "unexpected Eta failure"

let rec eta_bind_chain n acc =
  if n = 0 then acc
  else eta_bind_chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + one)) acc)

(* Fully prebuilt fail_catch chain. All 100k catch nodes are constructed at
   module-load time via a tail-recursive outward build. Each handler is
   [fun _ -> next_node] where [next_node] is the pre-allocated inner node.
   No closures or eff records are allocated per sample — only
   Cause.Fail/Exit.Error wrapping at runtime. *)
let eta_fail_catch_loop n =
  let fail_boom = Effect.fail `Boom in
  let leaf = Effect.pure n in
  let rec build i acc =
    if i = 0 then acc
    else
      let next = Effect.bind_error (fun (_ : [ `Boom ]) -> acc) fail_boom in
      build (i - 1) next
  in
  build n leaf

let bind_n = 100_000
let fail_n = 100_000

(* ---- realuse.retry.flaky.fail4_then_ok (mirror of runtime_real) ---- *)
let retry_flaky_program () =
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
    Effect.retry (Schedule.recurs 10) (fun (_ : [ `Boom ]) -> true) flaky
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

let run_retry_flaky_sample () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt (retry_flaky_program ()) with
  | Exit.Ok _ -> ()
  | Exit.Error _ -> failwith "retry should succeed"

let workload name run = { Bench_lib.name; run; samples = None }

let overhead_workloads rt =
  let eta_bind = eta_bind_chain bind_n (Effect.pure 0) in
  let eta_fail = eta_fail_catch_loop fail_n in
  [
    workload "overhead.eta.pure.reused_rt" (fun () ->
        run_eta_int rt (Effect.pure 0));
    workload "overhead.eta.bind.100k.prebuilt" (fun () ->
        run_eta_int rt eta_bind);
    workload "overhead.eta.fail_catch.100k.prebuilt" (fun () ->
        run_eta_int rt eta_fail);
  ]

let realuse_workloads () =
  [ workload "realuse.retry.flaky.fail4_then_ok" run_retry_flaky_sample ]

let () =
  let opts = Bench_lib.parse_args () in
  Bench_lib.run opts (realuse_workloads ());
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Bench_lib.run opts (overhead_workloads rt)
