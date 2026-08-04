(* Probe B: change-proportionality of stabilization.

   Two claims from the audit are measured:

   1. User-function recomputation is change-proportional: after changing
      one of two independent source vars, only the dependent chain
      recomputes ([recompute_count] delta ~ chain length, not graph size).

   2. Stabilization *traversal* is O(necessary graph) regardless of how
      much changed: a no-op stabilization (set suppressed by the source
      cutoff) recomputes nothing but still costs time linear in graph
      size, because [compute] walks from every observer root and version
      checks visit every edge. Jane Street incremental's recompute heap
      visits only nodes downstream of a change.

   Graph shape per size: two source vars A and B; A feeds K chains of
   length L, B feeds K chains of length L; each chain end is observed
   through [all]. N = 2*K*L total nodes, all necessary. *)

open Eta

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  match Runtime.run rt program with
  | Exit.Ok value -> value
  | Exit.Error _ -> failwith "probe_scale: typed failure"

let time_call f =
  let start = Unix.gettimeofday () in
  let () = f () in
  (Unix.gettimeofday () -. start) *. 1e6

let scenario ~chains ~len ~iters =
  let module S = Eta_signal.Make_no_error () in
  let var_a = S.Var.create 0 in
  let var_b = S.Var.create 0 in
  let chain var =
    List.init chains (fun _ ->
        let rec loop acc remaining =
          if remaining <= 0 then acc
          else loop (S.map (fun n -> n + 1) acc) (remaining - 1)
        in
        loop (S.Var.watch var) len)
  in
  let ends_a = chain var_a in
  let ends_b = chain var_b in
  let observe_all signals =
    run_effect
      (let open Syntax in
       let all = S.all signals in
       S.Observer.observe all (fun _ -> Effect.unit))
  in
  let _obs_a = observe_all ends_a in
  let _obs_b = observe_all ends_b in
  run_effect S.stabilize;
  let recompute_count () = (run_effect (S.stats ())).recompute_count in
  let nodes = 2 * chains * len in
  (* 1. change-proportionality of user-function recomputation *)
  let before = recompute_count () in
  run_effect (S.Var.set var_a 1);
  run_effect S.stabilize;
  let recomputed = recompute_count () - before in
  (* 2. no-op stabilize wall time (cutoff suppresses the set) *)
  let noop_us =
    time_call (fun () ->
        for _ = 1 to iters do
          run_effect (S.Var.set var_a 1);
          run_effect S.stabilize
        done)
    /. Float.of_int iters
  in
  (* 3. changing stabilize wall time *)
  let change_us =
    time_call (fun () ->
        for i = 2 to iters + 1 do
          run_effect (S.Var.set var_a i);
          run_effect S.stabilize
        done)
    /. Float.of_int iters
  in
  (* 4. stabilize with no set at all *)
  let pure_us =
    time_call (fun () ->
        for _ = 1 to iters do
          run_effect S.stabilize
        done)
    /. Float.of_int iters
  in
  Printf.printf
    "nodes=%7d chains=%4d len=%3d recomputed_after_one_var_set=%7d \
     noop_stabilize_us=%9.1f change_stabilize_us=%9.1f idle_stabilize_us=%9.1f\n\
     %!"
    nodes chains len recomputed noop_us change_us pure_us

let () =
  scenario ~chains:1 ~len:100 ~iters:200;
  scenario ~chains:10 ~len:100 ~iters:200;
  scenario ~chains:50 ~len:100 ~iters:100;
  scenario ~chains:200 ~len:100 ~iters:50;
  scenario ~chains:500 ~len:100 ~iters:20
