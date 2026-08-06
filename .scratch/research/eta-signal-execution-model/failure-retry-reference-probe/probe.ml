(* This is a prototype measurement probe, not production Signal code. *)

module E = Eta.Effect
module S = Eta_signal_kernel.Make_no_error ()

type signal_error =
  [ S.graph_error | S.observer_read_error | S.stabilize_error | S.time_error ]

module Sync_runtime () = struct
  type scope = unit
  type cancel_context = unit
  type 'a promise = 'a option ref
  type 'a resolver = 'a option ref
  type 'a stream = 'a Stdlib.Queue.t

  let root_scope = ()
  let fresh_counter = ref 0
  let now_ms () = 0
  let fresh () = incr fresh_counter; !fresh_counter
  let sleep _duration = ()
  let protect f = f ()

  let with_cancel_mask f =
    protect (fun () ->
        f
          {
            Eta.Runtime_contract.restore =
              (fun (type a) (body : unit -> a) -> body ());
          })

  let run_scope ?name:_ f = f ()
  let fail_scope ?bt:_ () exn = raise exn
  let fork () f = f ()
  let fork_daemon () f = ignore (f () : [ `Stop_daemon ])
  let await_cancel () = failwith "Sync_runtime.await_cancel"
  let yield () = ()
  let check () = ()

  let create_promise () =
    let cell = ref None in
    (cell, cell)

  let resolve_promise resolver value =
    match !resolver with
    | Some _ -> invalid_arg "Sync_runtime.resolve_promise: already resolved"
    | None -> resolver := Some value

  let await_promise promise =
    match !promise with
    | Some value -> value
    | None -> failwith "Sync_runtime.await_promise: unresolved"

  let create_stream _capacity = Stdlib.Queue.create ()
  let stream_add stream value = Stdlib.Queue.add value stream

  let stream_take stream =
    if Stdlib.Queue.is_empty stream then
      failwith "Sync_runtime.stream_take: empty"
    else Stdlib.Queue.take stream

  let stream_take_nonblocking stream =
    if Stdlib.Queue.is_empty stream then None else Some (Stdlib.Queue.take stream)

  let with_worker_context f = f ()
  let in_worker_context () = false
  let cancellation_reason _ = None
  let multiple_exceptions _ = None
  let cancel_sub f = f ()
  let cancel () exn = raise exn
  let current_fiber_id () = 0
  let with_fiber_identity f = f ()

  let locals :
      (int, Eta.Runtime_contract.local_binding list) Hashtbl.t =
    Hashtbl.create 8

  let local_get local =
    match
      Hashtbl.find_opt locals (Eta.Runtime_contract.Backend.local_id local)
    with
    | None -> None
    | Some bindings ->
        List.find_map
          (Eta.Runtime_contract.Backend.local_binding_value local)
          bindings

  let local_with_binding local value f =
    let id = Eta.Runtime_contract.Backend.local_id local in
    let previous = Hashtbl.find_opt locals id in
    let stack = Option.value previous ~default:[] in
    Hashtbl.replace locals id
      (Eta.Runtime_contract.Local_binding (local, value) :: stack);
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some stack -> Hashtbl.replace locals id stack
        | None -> Hashtbl.remove locals id)
      f
end

type layer = Raw | Public_sync
type kind = Failed_retry | Successful
type position = First | Middle | Last | None_position

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
  cleanup : unit -> unit;
}

exception Probe_failure

let layer_name = function Raw -> "raw" | Public_sync -> "public_sync"
let kind_name = function Failed_retry -> "failed_retry" | Successful -> "successful"

let position_name = function
  | First -> "first"
  | Middle -> "middle"
  | Last -> "last"
  | None_position -> "none"

let parse_layer = function
  | "raw" -> Raw
  | "public_sync" -> Public_sync
  | name -> invalid_arg ("unknown layer: " ^ name)

let parse_kind = function
  | "failed_retry" -> Failed_retry
  | "successful" -> Successful
  | name -> invalid_arg ("unknown kind: " ^ name)

let parse_position = function
  | "first" -> First
  | "middle" -> Middle
  | "last" -> Last
  | "none" -> None_position
  | name -> invalid_arg ("unknown position: " ^ name)

let position_index depth = function
  | First -> 1
  | Middle -> (depth + 1) / 2
  | Last -> depth
  | None_position -> depth

let make_sync_runtime () =
  let module Runtime = Sync_runtime () in
  Eta.Runtime.create_with_runtime
    (module Runtime : Eta.Runtime_contract.RUNTIME)
    ()

let fail_cause cause =
  failwith (Eta.Cause.pretty (fun _ -> "typed failure") cause)

let run_ok runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> fail_cause cause

let rec effect_loop step remaining =
  if remaining = 0 then E.unit
  else E.bind (fun () -> effect_loop step (remaining - 1)) step

let make_workload layer kind depth position =
  let runtime = make_sync_runtime () in
  let run effect =
    run_ok runtime
      (E.map_error (fun error -> (error :> signal_error)) effect)
  in
  let source = S.Var.create 0 in
  let fail_next = ref false in
  let failing_index = position_index depth position in
  let rec chain index signal =
    if index > depth then signal
    else
      let map =
        if kind = Failed_retry && index = failing_index then
          S.map (fun value ->
              if !fail_next then raise Probe_failure;
              value + 1)
        else S.map (( + ) 1)
      in
      chain (index + 1) (map signal)
  in
  let output = chain 1 (S.Var.watch source) in
  let next = ref 0 in
  let next_value () =
    incr next;
    !next
  in
  let raw_success lane =
    let result = S.begin_stabilize lane None in
    Eta_signal_atomic_pass.result result
      ~planning_ok:(fun ~hooks ~events ->
        if hooks <> [] || events <> [] then
          failwith "raw success produced cleanup hooks or observer events";
        Eta_signal_kernel.Graph.finish_stabilization S.graph lane)
      ~graph_error:(fun ~hooks:_ error ->
        Format.kasprintf failwith "%a" S.pp_graph_error error)
      ~defect:(fun ~hooks:_ exn backtrace ->
        Printexc.raise_with_backtrace exn backtrace)
  in
  let raw_failure lane =
    let result = S.begin_stabilize lane None in
    Eta_signal_atomic_pass.result result
      ~planning_ok:(fun ~hooks:_ ~events:_ ->
        failwith "raw failing stabilization succeeded")
      ~graph_error:(fun ~hooks:_ error ->
        Format.kasprintf failwith "%a" S.pp_graph_error error)
      ~defect:(fun ~hooks exn _backtrace ->
        if hooks <> [] then
          failwith "raw defect produced cleanup hooks";
        match exn with
        | Probe_failure -> ()
        | _ -> raise exn)
  in
  let with_lane f = S.with_graph_lane_access f in
  let read_raw () =
    run (with_lane (fun _lane -> S.effective_signal_value output))
  in
  let add_private_demand () =
    run
      (with_lane (fun lane ->
           S.adjust_demand lane output 1;
           raw_success lane))
  in
  let remove_private_demand () =
    run (with_lane (fun lane -> S.adjust_demand lane output (-1)))
  in
  add_private_demand ();
  let raw_failed_retry lane () =
    fail_next := true;
    S.Var.set_unlocked lane source (next_value ());
    raw_failure lane;
    fail_next := false;
    raw_success lane
  in
  let raw_successful lane () =
    S.Var.set_unlocked lane source (next_value ());
    raw_success lane
  in
  let public_failed_retry =
    E.bind
      (fun value ->
        E.bind
          (fun () ->
            E.bind
              (function
                | Eta.Exit.Error (Eta.Cause.Die _) ->
                    E.bind
                      (fun () -> S.stabilize)
                      (E.sync (fun () -> fail_next := false))
                | Eta.Exit.Ok () ->
                    E.sync (fun () ->
                        failwith "public failing stabilization succeeded")
                | Eta.Exit.Error cause ->
                    E.sync (fun () -> fail_cause cause))
              (E.to_exit S.stabilize))
          (S.Var.set source value))
      (E.sync (fun () ->
           fail_next := true;
           next_value ()))
  in
  let public_successful =
    E.bind
      (fun value ->
        E.bind (fun () -> S.stabilize) (S.Var.set source value))
      (E.sync next_value)
  in
  let read_public () = read_raw () in
  let check_failed_retry () =
    let committed_before = read_raw () in
    (match layer with
    | Raw ->
        run
          (with_lane (fun lane ->
               fail_next := true;
               S.Var.set_unlocked lane source (next_value ());
               raw_failure lane;
               let preserved = S.effective_signal_value output in
               if preserved <> committed_before then
                 failwith "raw defect changed the committed snapshot";
               fail_next := false;
               raw_success lane;
               let committed = S.effective_signal_value output in
               if committed <> !next + depth then
                 failwith "raw retry did not commit the changed value"))
    | Public_sync ->
        fail_next := true;
        let value = next_value () in
        run (S.Var.set source value);
        (match
           Eta.Runtime.run runtime
             (E.map_error
                (fun error -> (error :> signal_error))
                S.stabilize)
         with
        | Eta.Exit.Error (Eta.Cause.Die _) -> ()
        | Eta.Exit.Ok () -> failwith "public failing stabilization succeeded"
        | Eta.Exit.Error cause -> fail_cause cause);
        if read_public () <> committed_before then
          failwith "public defect changed the committed snapshot";
        fail_next := false;
        run S.stabilize;
        if read_public () <> !next + depth then
          failwith "public retry did not commit the changed value")
  in
  let check_successful () =
    match layer with
    | Raw -> run (with_lane (fun lane -> raw_successful lane ()))
    | Public_sync -> run public_successful
  in
  (match kind with
  | Failed_retry -> check_failed_retry ()
  | Successful -> check_successful ());
  let run_batch =
    match (layer, kind) with
    | Raw, Failed_retry ->
        fun operations ->
          run
            (with_lane (fun lane ->
                 for _ = 1 to operations do
                   raw_failed_retry lane ()
                 done))
    | Raw, Successful ->
        fun operations ->
          run
            (with_lane (fun lane ->
                 for _ = 1 to operations do
                   raw_successful lane ()
                 done))
    | Public_sync, Failed_retry ->
        fun operations -> run (effect_loop public_failed_retry operations)
    | Public_sync, Successful ->
        fun operations -> run (effect_loop public_successful operations)
  in
  let check () =
    let observed = read_raw () in
    let expected = !next + depth in
    if observed <> expected then
      failwith
        (Printf.sprintf "%s %s depth %d: expected %d, observed %d"
           (layer_name layer) (kind_name kind) depth expected observed)
  in
  {
    name =
      Printf.sprintf "eta_signal.%s.%s.depth_%d.position_%s"
        (layer_name layer) (kind_name kind) depth (position_name position);
    run_batch;
    check;
    cleanup = remove_private_demand;
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run_batch operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~sample_count workload =
  let operations = calibrate workload 1 in
  workload.run_batch operations;
  workload.check ();
  Gc.full_major ();
  for sample = 1 to sample_count do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run_batch operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    workload.check ();
    let count = float_of_int operations in
    let wall_ns = ((stopped -. started) *. 1e9) /. count in
    let allocated_words =
      ((after_minor -. before_minor)
       +. (after_major -. before_major)
       -. (after_promoted -. before_promoted))
      /. count
    in
    Printf.printf "%s,%d,%d,%.6f,%.6f\n%!"
      workload.name operations sample wall_ns allocated_words
  done

let parse_args () =
  let rec loop layer kind depth position samples = function
    | [] -> layer, kind, depth, position, samples
    | "--layer" :: value :: rest ->
        loop (Some (parse_layer value)) kind depth position samples rest
    | "--kind" :: value :: rest ->
        loop layer (Some (parse_kind value)) depth position samples rest
    | "--depth" :: value :: rest ->
        loop layer kind (Some (int_of_string value)) position samples rest
    | "--position" :: value :: rest ->
        loop layer kind depth (parse_position value) samples rest
    | "--samples" :: value :: rest ->
        loop layer kind depth position (int_of_string value) rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  match
    loop None None None None_position 3
      (List.tl (Array.to_list Sys.argv))
  with
  | Some layer, Some kind, Some depth, position, samples
    when depth > 0 && samples > 0 ->
      if kind = Successful && position <> None_position then
        invalid_arg "successful workload position must be none";
      if kind = Failed_retry && position = None_position then
        invalid_arg "failed_retry workload needs a failing position";
      (layer, kind, depth, position, samples)
  | _ ->
      invalid_arg
        "use --layer LAYER --kind KIND --depth DEPTH --position POSITION \
         [--samples COUNT]"

let () =
  let layer, kind, depth, position, sample_count = parse_args () in
  let workload = make_workload layer kind depth position in
  Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
  Fun.protect
    ~finally:workload.cleanup
    (fun () -> measure ~sample_count workload)
