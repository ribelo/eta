(* Probe A: deep-chain robustness of pull-based recomputation.

   Eta_signal recomputes by recursive descent from observer roots
   (kernel [compute]), marks dirty frontiers by recursive descent over
   dependents ([notify_dirty_frontier]), and computes necessary sets by
   recursive DFS ([fold_reachable]). Jane Street incremental instead drives
   recomputation from an explicit height-ordered heap. This probe builds
   single-chain graphs of increasing depth and reports the first depth at
   which stabilization fails, and how it fails. *)

open Eta

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  Runtime.run rt program

let attempt depth =
  let module S = Eta_signal.Make_no_error () in
  let show pp eff = Effect.map_error (Format.asprintf "%a" pp) eff in
  let source = S.Var.create 0 in
  let signal =
    let rec loop acc remaining =
      if remaining <= 0 then acc else loop (S.map (fun n -> n + 1) acc) (remaining - 1)
    in
    loop (S.Var.watch source) depth
  in
  match
    run_effect
      (let open Syntax in
       let* observer =
         show S.pp_graph_error (S.Observer.observe signal (fun _ -> Effect.unit))
       in
       let* () = show S.pp_stabilize_error S.stabilize in
       let* () = show S.pp_graph_error (S.Var.set source 1) in
       let* () = show S.pp_stabilize_error S.stabilize in
       let* value = show S.pp_observer_read_error (S.Observer.read observer) in
       let+ () = show S.pp_graph_error (S.Observer.dispose observer) in
       value)
  with
  | Exit.Ok value ->
      Printf.printf "depth=%7d ok value=%d\n%!" depth value
  | Exit.Error cause ->
      Printf.printf "depth=%7d typed-failure %s\n%!" depth
        (match cause with
        | Cause.Fail err -> err
        | _ -> "non-fail cause")
  | exception Stack_overflow ->
      Printf.printf "depth=%7d STACK_OVERFLOW\n%!" depth
  | exception exn ->
      Printf.printf "depth=%7d defect %s\n%!" depth (Printexc.to_string exn)

let () =
  List.iter attempt
    [ 200_000; 400_000; 800_000; 1_600_000 ]
