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

type layer =
  | Raw
  | Effect
  | Lane
  | Public_sync
  | Public_eio
  | Scheduled_eio
  | Observer_eio
  | Timer_eio

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
  cleanup : unit -> unit;
}

let layer_name = function
  | Raw -> "raw"
  | Effect -> "effect"
  | Lane -> "lane"
  | Public_sync -> "public_sync"
  | Public_eio -> "public_eio"
  | Scheduled_eio -> "scheduled_eio"
  | Observer_eio -> "observer_eio"
  | Timer_eio -> "timer_eio"

let parse_layer = function
  | "raw" -> Raw
  | "effect" -> Effect
  | "lane" -> Lane
  | "public_sync" -> Public_sync
  | "public_eio" -> Public_eio
  | "scheduled_eio" -> Scheduled_eio
  | "observer_eio" -> Observer_eio
  | "timer_eio" -> Timer_eio
  | name -> invalid_arg ("unknown layer: " ^ name)

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

let make_changed ~eio_runtime layer depth =
  let sync_runtime = make_sync_runtime () in
  let runtime =
    match layer with
    | Raw | Effect | Lane | Public_sync -> sync_runtime
    | Public_eio | Scheduled_eio | Observer_eio | Timer_eio -> eio_runtime
  in
  let run effect =
    run_ok runtime
      (E.map_error (fun error -> (error :> signal_error)) effect)
  in
  let source = S.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (S.map (( + ) 1) signal)
  in
  let output = chain depth (S.Var.watch source) in
  let next = ref 0 in
  let next_value () =
    incr next;
    !next
  in
  let raw_stabilize lane =
    let result = S.begin_stabilize lane None in
    Eta_signal_atomic_pass.result result
      ~planning_ok:(fun ~hooks:_ ~events ->
        if events <> [] then
          failwith "raw stabilization produced observer events";
        Eta_signal_kernel.Graph.finish_stabilization S.graph lane)
      ~graph_error:(fun ~hooks:_ error ->
        Format.kasprintf failwith "%a" S.pp_graph_error error)
      ~defect:(fun ~hooks:_ exn backtrace ->
        Printexc.raise_with_backtrace exn backtrace)
  in
  let raw_step lane () =
    S.Var.set_unlocked lane source (next_value ());
    raw_stabilize lane
  in
  let with_lane f = S.with_graph_lane_access f in
  let add_private_demand () =
    run
      (with_lane (fun lane ->
           S.adjust_demand lane output 1;
           raw_stabilize lane))
  in
  let remove_private_demand () =
    run
      (with_lane (fun lane -> S.adjust_demand lane output (-1)))
  in
  let observer = ref None in
  let timer_observer = ref None in
  let initialize () =
    match layer with
    | Raw | Effect | Lane | Public_sync | Public_eio | Scheduled_eio ->
        add_private_demand ()
    | Observer_eio ->
        observer :=
          Some
            (run
               (S.Observer.observe output ~on_update:(fun _ -> E.unit)));
        run S.stabilize
    | Timer_eio ->
        observer :=
          Some
            (run
               (S.Observer.observe output ~on_update:(fun _ -> E.unit)));
        let timer =
          run (S.Time.after (Eta.Duration.ms 3_600_000))
        in
        timer_observer :=
          Some
            (run
               (S.Observer.observe timer ~on_update:(fun _ -> E.unit)));
        run S.stabilize
  in
  initialize ();
  let public_step =
    E.bind
      (fun value ->
        E.bind (fun () -> S.stabilize) (S.Var.set source value))
      (E.sync next_value)
  in
  let scheduled_step = E.bind (fun () -> public_step) E.yield in
  let lane_step = with_lane (fun lane -> raw_step lane ()) in
  let run_batch =
    match layer with
    | Raw ->
        fun operations ->
          run
            (with_lane (fun lane ->
                 for _ = 1 to operations do
                   raw_step lane ()
                 done))
    | Effect ->
        fun operations ->
          run
            (with_lane (fun lane ->
                 let step = E.sync (raw_step lane) in
                 run
                   (effect_loop step operations)))
    | Lane ->
        fun operations ->
          run (effect_loop lane_step operations)
    | Public_sync | Public_eio | Observer_eio | Timer_eio ->
        fun operations -> run (effect_loop public_step operations)
    | Scheduled_eio ->
        fun operations -> run (effect_loop scheduled_step operations)
  in
  let read_output () =
    match !observer with
    | Some observer -> run (S.Observer.read observer)
    | None ->
        run
          (with_lane (fun _lane -> S.effective_signal_value output))
  in
  let check () =
    let observed = read_output () in
    let expected = !next + depth in
    if observed <> expected then
      failwith
        (Printf.sprintf "%s depth %d: expected %d, observed %d"
           (layer_name layer) depth expected observed)
  in
  let cleanup () =
    Option.iter
      (fun observer -> run (S.Observer.dispose observer))
      !timer_observer;
    Option.iter
      (fun observer -> run (S.Observer.dispose observer))
      !observer;
    if Option.is_none !observer then remove_private_demand ()
  in
  {
    name =
      Printf.sprintf "eta_signal.%s.changed.depth_%d"
        (layer_name layer) depth;
    run_batch;
    check;
    cleanup;
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
  let rec loop layer depth samples = function
    | [] -> layer, depth, samples
    | "--layer" :: name :: rest ->
        loop (Some (parse_layer name)) depth samples rest
    | "--depth" :: value :: rest ->
        loop layer (Some (int_of_string value)) samples rest
    | "--samples" :: value :: rest ->
        loop layer depth (int_of_string value) rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  match loop None None 3 (List.tl (Array.to_list Sys.argv)) with
  | Some layer, Some depth, samples when depth >= 0 && samples > 0 ->
      layer, depth, samples
  | _ ->
      invalid_arg
        "use --layer LAYER --depth DEPTH [--samples COUNT]"

let () =
  let layer, depth, sample_count = parse_args () in
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let eio_runtime =
    Eta_eio.Runtime.create ~sw:switch
      ~clock:(Eio.Stdenv.clock environment) ()
  in
  let workload = make_changed ~eio_runtime layer depth in
  Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
  Fun.protect
    ~finally:workload.cleanup
    (fun () -> measure ~sample_count workload)
