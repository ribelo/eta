(* Archaeology F (runtime): use a same-domain Channel across eta_par Island
   domains. The handle is created on the main domain; Island.run callbacks on
   worker domains build their OWN eio+eta runtimes there and run channel
   effects on the shared handle. Contrast case: Eta Queue, which is
   documented cross-domain. Predicted: runtime-only failure, hang, or silent
   misbehavior for Channel; clean completion for Queue. The caller wraps
   every scenario in `timeout`. *)

open Eta

let pp_hidden fmt _ = Format.pp_print_string fmt "<err>"

let run_worker eff =
  match
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
    Eta_eio.Runtime.run rt eff
  with
  | Exit.Ok v -> "Ok(" ^ v ^ ")"
  | Exit.Error cause ->
      Format.asprintf "Error(%a)" (Cause.pp pp_hidden) cause

let () =
  let scenario = Sys.argv.(1) in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let pool = Eta_par.Island.Pool.create ~domains:2 () in
  Fun.protect
    ~finally:(fun () -> Eta_par.Island.Pool.shutdown pool)
    (fun () ->
      let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
      match scenario with
      | "try-send" ->
          let chan = Channel.create ~capacity:4 () in
          let exit =
            Eta_eio.Runtime.run rt
              (Eta_par.Island.run ~name:"worker-try-send" ~pool
                 (fun chan ->
                   run_worker
                     (Effect.map
                        (function
                          | `Sent -> "Sent"
                          | `Full -> "Full"
                          | `Closed -> "Closed"
                          | `Closed_with_error _ -> "Closed_with_error")
                        (Channel.try_send chan "from-worker")))
                 chan)
          in
          (match exit with
          | Exit.Ok outcome -> Printf.printf "worker try_send: %s\n" outcome
          | Exit.Error cause ->
              Format.printf "island infra: Error(%a)@."
                (Cause.pp Format.pp_print_string)
                cause);
          (match Eta_eio.Runtime.run rt (Channel.try_recv chan) with
          | Exit.Ok (`Item v) -> Printf.printf "main try_recv: Ok(Item %S)\n" v
          | Exit.Ok `Empty -> print_endline "main try_recv: Ok(Empty) VALUE LOST"
          | _ -> print_endline "main try_recv: other")
      | "blocking-pair" ->
          let chan = Channel.create ~capacity:1 () in
          let exits =
            Eta_eio.Runtime.run rt
              (Effect.all
                 [
                   Eta_par.Island.run ~name:"worker-recv" ~pool
                     (fun chan ->
                       run_worker
                         (Effect.map (fun (_ : string) -> "recv completed")
                            (Channel.recv chan)))
                     chan;
                   Eta_par.Island.run ~name:"worker-send" ~pool
                     (fun chan ->
                       run_worker
                         (Effect.bind
                            (fun () ->
                              Effect.map (fun () -> "send completed")
                                (Channel.send chan "from-worker"))
                            (Effect.sleep (Duration.ms 300))))
                     chan;
                 ])
          in
          (match exits with
          | Exit.Ok [ a; b ] ->
              Printf.printf "channel blocking pair: %s / %s\n" a b
          | Exit.Ok _ -> print_endline "channel blocking pair: unexpected arity"
          | Exit.Error cause ->
              Format.printf "channel blocking pair: Error(%a)@."
                (Cause.pp Format.pp_print_string)
                cause)
      | "queue-contrast" ->
          let queue = Queue.unbounded () in
          let exits =
            Eta_eio.Runtime.run rt
              (Effect.all
                 [
                   Eta_par.Island.run ~name:"worker-take" ~pool
                     (fun queue ->
                       run_worker
                         (Effect.map
                            (fun v -> Printf.sprintf "take got %S" v)
                            (Queue.take queue)))
                     queue;
                   Eta_par.Island.run ~name:"worker-send" ~pool
                     (fun queue ->
                       run_worker
                         (Effect.bind
                            (fun () ->
                              Effect.map (fun () -> "send completed")
                                (Queue.send queue "from-worker"))
                            (Effect.sleep (Duration.ms 300))))
                     queue;
                 ])
          in
          (match exits with
          | Exit.Ok [ a; b ] -> Printf.printf "queue blocking pair: %s / %s\n" a b
          | Exit.Ok _ -> print_endline "queue blocking pair: unexpected arity"
          | Exit.Error cause ->
              Format.printf "queue blocking pair: Error(%a)@."
                (Cause.pp Format.pp_print_string)
                cause)
      | _ -> failwith "unknown scenario")
