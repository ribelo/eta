(* PROTOTYPE: This executable compares private Eta effect seams around one
   synchronous Signal kernel. It is not production Signal code. *)

[@@@alert "-do_not_spawn_domains-unsafe_multidomain"]

module E = Eta.Effect
module Lane = Eta_signal_lane
module Reference = Eta_signal_kernel.Make_no_error ()

type graph_error = [ `Injected_graph_error ]
type probe_error =
  [ graph_error
  | Reference.graph_error
  | Reference.observer_read_error
  | Reference.stabilize_error ]

let failf format = Printf.ksprintf failwith format

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
    f
      {
        Eta.Runtime_contract.restore =
          (fun (type a) (body : unit -> a) -> body ());
      }

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

let make_sync_runtime () =
  let module Runtime = Sync_runtime () in
  Eta.Runtime.create_with_runtime
    (module Runtime : Eta.Runtime_contract.RUNTIME)
    ()

let cause_message cause =
  Eta.Cause.pretty (fun _ -> "typed failure") cause

let run_ok runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> failwith (cause_message cause)

let widen effect =
  E.map_error (fun error -> (error :> probe_error)) effect

module Kernel = struct
  type t = {
    values : int array;
    undo : int array;
    journal : int array;
    mutable journal_length : int;
    mutable accepted : int;
    mutable pending_claim : bool;
  }

  type claim = int

  let create depth =
    let values = Array.init (depth + 1) Fun.id in
    {
      values;
      undo = Array.copy values;
      journal = Array.make (depth + 1) 0;
      journal_length = 0;
      accepted = 0;
      pending_claim = false;
    }

  let depth t = Array.length t.values - 1
  let set t value = t.accepted <- value
  let value t = t.values.(Array.length t.values - 1)

  let write t slot candidate =
    if t.values.(slot) <> candidate then (
      t.undo.(slot) <- t.values.(slot);
      t.journal.(t.journal_length) <- slot;
      t.journal_length <- t.journal_length + 1;
      t.values.(slot) <- candidate)

  let rollback t =
    for index = t.journal_length - 1 downto 0 do
      let slot = t.journal.(index) in
      t.values.(slot) <- t.undo.(slot)
    done;
    t.journal_length <- 0

  let stabilize ?(make_claim = false) ~before_publish t =
    try
      write t 0 t.accepted;
      for slot = 1 to Array.length t.values - 1 do
        write t slot (t.values.(slot - 1) + 1)
      done;
      before_publish ();
      t.journal_length <- 0;
      if make_claim then t.pending_claim <- true;
      Ok ()
    with exn ->
      rollback t;
      raise exn

  let next_claim t = if t.pending_claim then Some 0 else None

  let acknowledge t claim =
    if claim <> 0 || not t.pending_claim then
      invalid_arg "PROTOTYPE: stale claim";
    t.pending_claim <- false
end

module Driver = struct
  type t = {
    lane : Lane.t;
    owner_domain : Domain.id;
    depth_local : int Eta.Runtime_contract.local;
    mutable owner_fiber_id : int option;
  }

  let hooks =
    Lane.hooks ~note_waiter_enqueued:(fun () -> ())
      ~note_waiter_compaction:(fun () -> ())

  let create () =
    {
      lane = Lane.create ();
      owner_domain = Domain.self ();
      depth_local =
        Eta.Runtime_contract.create_local
          ~inheritance:Eta.Runtime_contract.Fiber_local ();
      owner_fiber_id = None;
    }

  let ensure_context t =
    if
      Domain.self () <> t.owner_domain
      || Eta.Runtime_contract.in_registered_worker_context ()
    then
      invalid_arg
        "PROTOTYPE: graph operation ran outside its owner-domain context"

  let hold_for_test ~after_acquired t operation =
    Lane.with_sync ~leaf_name:"eta_signal_effect_seam.prototype"
      ~depth_local:t.depth_local ~ensure_context:(fun () -> ensure_context t)
      ~hooks ~after_acquired t.lane
      (fun _access -> operation ())
    |> E.flatten_result

  let run_with_checkpoint t operation =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal_effect_seam.checkpoint"
    @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let finish = function
      | Ok value -> Eta.Exit.Ok value
      | Error error -> Eta.Exit.Error (Eta.Cause.Fail error)
    in
    let run_operation () =
      finish (operation contract.Eta.Runtime_contract.check)
    in
    try
      ensure_context t;
      let current_fiber_id =
        contract.Eta.Runtime_contract.current_fiber_id ()
      in
      match t.owner_fiber_id with
      | Some owner_fiber_id when owner_fiber_id = current_fiber_id ->
          run_operation ()
      | _ ->
          let access = Lane.enter ~hooks contract t.lane in
          t.owner_fiber_id <- Some current_fiber_id;
          let release () =
            contract.Eta.Runtime_contract.protect (fun () ->
                t.owner_fiber_id <- None;
                Lane.leave t.lane access)
          in
          Fun.protect ~finally:release (fun () ->
              contract.Eta.Runtime_contract.local_with_binding
                t.depth_local 1 run_operation)
    with
    | exn
      when Option.is_some
             (contract.Eta.Runtime_contract.cancellation_reason exn) ->
        raise exn
    | exn -> Eta.Spi.Expert.exit_of_exn context exn

  let run t operation =
    run_with_checkpoint t (fun _checkpoint -> operation ())

  let waiting t = Lane.waiting_count t.lane
  let cancelled t = Lane.cancelled_count t.lane
end

type layer =
  | Raw
  | Effect
  | Driver_sync
  | Public_sync
  | Public_eio
  | Deep_claim_sync
  | Cursor_sync

let layer_name = function
  | Raw -> "raw"
  | Effect -> "effect"
  | Driver_sync -> "driver_sync"
  | Public_sync -> "public_sync"
  | Public_eio -> "public_eio"
  | Deep_claim_sync -> "deep_claim_sync"
  | Cursor_sync -> "cursor_sync"

let parse_layer = function
  | "raw" -> Raw
  | "effect" -> Effect
  | "driver_sync" -> Driver_sync
  | "public_sync" -> Public_sync
  | "public_eio" -> Public_eio
  | "deep_claim_sync" -> Deep_claim_sync
  | "cursor_sync" -> Cursor_sync
  | name -> invalid_arg ("unknown layer: " ^ name)

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

let rec effect_loop step remaining =
  if remaining = 0 then E.unit
  else E.bind (fun () -> effect_loop step (remaining - 1)) step

let make_workload ~eio_runtime layer depth =
  let sync_runtime = make_sync_runtime () in
  let runtime = match layer with Public_eio -> eio_runtime | _ -> sync_runtime in
  let kernel = Kernel.create depth in
  let driver = Driver.create () in
  let next = ref 0 in
  let advance () =
    incr next;
    !next
  in
  let raw_step () =
    Kernel.set kernel (advance ());
    match Kernel.stabilize ~before_publish:(fun () -> ()) kernel with
    | Ok () -> ()
    | Error _ -> assert false
  in
  let effect_step = E.sync raw_step in
  let fused_step =
    Driver.run_with_checkpoint driver (fun before_publish ->
        Kernel.set kernel (advance ());
        Kernel.stabilize ~before_publish kernel)
  in
  let set_step =
    Driver.run driver (fun () ->
        Kernel.set kernel (advance ());
        Ok ())
  in
  let stabilize_step =
    Driver.run_with_checkpoint driver (fun before_publish ->
        Kernel.stabilize ~before_publish kernel)
  in
  let public_step = E.bind (fun () -> stabilize_step) set_step in
  let deep_claim_step =
    Driver.run_with_checkpoint driver (fun before_publish ->
        Kernel.set kernel (advance ());
        match
          Kernel.stabilize ~make_claim:true
            ~before_publish kernel
        with
        | Error _ as error -> error
        | Ok () -> (
            match Kernel.next_claim kernel with
            | None -> failwith "PROTOTYPE: missing private claim"
            | Some claim ->
                Kernel.acknowledge kernel claim;
                Ok ()))
  in
  let cursor_step =
    Driver.run_with_checkpoint driver (fun before_publish ->
        Kernel.set kernel (advance ());
        Kernel.stabilize ~make_claim:true
          ~before_publish kernel)
    |> E.bind (fun () ->
           Driver.run driver (fun () -> Ok (Kernel.next_claim kernel)))
    |> E.bind (function
         | None -> E.sync (fun () -> failwith "PROTOTYPE: missing cursor claim")
         | Some claim ->
             E.bind
               (fun () ->
                 Driver.run driver (fun () ->
                     Kernel.acknowledge kernel claim;
                     Ok ()))
               E.unit)
  in
  let run_batch =
    match layer with
    | Raw ->
        fun operations ->
          for _ = 1 to operations do
            raw_step ()
          done
    | Effect ->
        fun operations -> run_ok runtime (effect_loop effect_step operations)
    | Driver_sync ->
        fun operations -> run_ok runtime (effect_loop fused_step operations)
    | Public_sync | Public_eio ->
        fun operations -> run_ok runtime (effect_loop public_step operations)
    | Deep_claim_sync ->
        fun operations -> run_ok runtime (effect_loop deep_claim_step operations)
    | Cursor_sync ->
        fun operations -> run_ok runtime (effect_loop cursor_step operations)
  in
  {
    name =
      Printf.sprintf "eta_signal.effect_seam.%s.depth_%d"
        (layer_name layer) depth;
    run_batch;
    check =
      (fun () ->
        let expected = !next + depth in
        if Kernel.value kernel <> expected then
          failf "%s: expected %d, observed %d"
            (layer_name layer) expected (Kernel.value kernel);
        if Kernel.next_claim kernel <> None then
          failf "%s: retained a claim" (layer_name layer));
  }

let expect_typed_error runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Error (Eta.Cause.Fail `Injected_graph_error) -> ()
  | Eta.Exit.Error cause ->
      failf "expected typed graph error, got %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "expected typed graph error, got success"

let expect_defect runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      failf "expected defect, got %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "expected defect, got success"

let check_semantics ~eio_runtime ~sw =
  let sync_runtime = make_sync_runtime () in
  let driver = Driver.create () in
  expect_typed_error sync_runtime
    (Driver.run driver (fun () -> Error `Injected_graph_error));
  expect_defect sync_runtime
    (Driver.run driver (fun () -> failwith "injected defect"));
  let nested_count = ref 0 in
  run_ok sync_runtime
    (Driver.run driver (fun () ->
         run_ok sync_runtime
           (Driver.run driver (fun () ->
                incr nested_count;
                Ok ()));
         Ok ()));
  if !nested_count <> 1 then failwith "nested operation did not reenter once";
  let kernel = Kernel.create 10 in
  Kernel.set kernel 1;
  (match
     Kernel.stabilize
       ~before_publish:(fun () -> raise Exit) kernel
   with
  | exception Exit -> ()
  | Ok () | Error _ -> failwith "injected pre-publication failure did not escape");
  if Kernel.value kernel <> 10 then
    failwith "pre-publication failure exposed a candidate";
  ignore
    (Kernel.stabilize ~before_publish:(fun () -> ()) kernel :
      (unit, graph_error) result);
  if Kernel.value kernel <> 11 then
    failwith "pre-publication failure did not leave admission retryable";
  let interrupted_kernel = Kernel.create 10 in
  (match
     Eio.Cancel.sub @@ fun context ->
     let effect =
       Driver.run_with_checkpoint driver (fun checkpoint ->
           Kernel.set interrupted_kernel 1;
           Kernel.stabilize interrupted_kernel
             ~before_publish:(fun () ->
               Eio.Cancel.cancel context Exit;
               checkpoint ()))
     in
     Eta.Runtime.run eio_runtime (widen effect)
   with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "pre-publication cancellation became an Eta error: %s"
        (cause_message cause)
  | Eta.Exit.Ok () -> failwith "pre-publication cancellation returned success");
  if Kernel.value interrupted_kernel <> 10 then
    failwith "pre-publication cancellation exposed a candidate";
  run_ok eio_runtime
    (widen
       (Driver.run_with_checkpoint driver (fun checkpoint ->
            Kernel.stabilize interrupted_kernel ~before_publish:checkpoint)));
  if Kernel.value interrupted_kernel <> 11 then
    failwith "pre-publication cancellation did not leave admission retryable";
  let holder_started, holder_started_resolver = Eio.Promise.create () in
  let release_holder, release_holder_resolver = Eio.Promise.create () in
  let holder =
    Eio.Fiber.fork_promise ~sw (fun () ->
        let effect =
          Driver.hold_for_test
            ~after_acquired:(fun () ->
              E.sync (fun () ->
                  Eio.Promise.resolve holder_started_resolver ();
                  Eio.Promise.await release_holder))
            driver (fun () -> Ok ())
        in
        Eta.Runtime.run eio_runtime (widen effect))
  in
  Eio.Promise.await holder_started;
  let contender_body_count = ref 0 in
  let cancel_context = ref None in
  let contender_ready, contender_ready_resolver = Eio.Promise.create () in
  let contender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun context ->
        cancel_context := Some context;
        Eio.Promise.resolve contender_ready_resolver ();
        let effect =
          Driver.run driver (fun () ->
              incr contender_body_count;
              Ok ())
        in
        Eta.Runtime.run eio_runtime (widen effect))
  in
  Eio.Promise.await contender_ready;
  let rec wait_for_queue attempts =
    if Driver.waiting driver = 1 then ()
    else if attempts = 0 then failwith "contender did not queue"
    else (
      Eio.Fiber.yield ();
      wait_for_queue (attempts - 1))
  in
  wait_for_queue 100;
  Option.iter (fun context -> Eio.Cancel.cancel context Exit) !cancel_context;
  Eio.Promise.resolve release_holder_resolver ();
  (match Eio.Promise.await_exn contender with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "cancelled contender returned Eta error: %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "cancelled contender returned success");
  (match Eio.Promise.await_exn holder with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      failf "holder returned Eta error: %s" (cause_message cause));
  if !contender_body_count <> 0 then
    failwith "cancelled contender executed its body";
  if Driver.waiting driver <> 0 then
    failwith "cancelled contender remained queued";
  if Driver.cancelled driver <> 1 then
    failwith "cancelled contender count mismatch";
  run_ok eio_runtime (widen (Driver.run driver (fun () -> Ok ())));
  let foreign_exit =
    Domain.join
      (Domain.spawn (fun () ->
           let foreign_runtime = make_sync_runtime () in
           Eta.Runtime.run foreign_runtime
             (Driver.run driver (fun () -> Ok ()))))
  in
  (match foreign_exit with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      failf "wrong-domain operation was not a defect: %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "wrong-domain operation succeeded");
  Printf.printf "semantic checks: pass\n%!"

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
    let pair = Option.value (Sys.getenv_opt "PAIR") ~default:"1" in
    Printf.printf "%s,%s,%d,%d,%.6f,%.6f\n%!"
      workload.name pair operations sample wall_ns allocated_words
  done

type edge_layer = Candidate_edge | Reference_edge

let parse_edge_layer = function
  | "candidate" -> Candidate_edge
  | "reference" -> Reference_edge
  | name -> invalid_arg ("unknown edge layer: " ^ name)

let await_cancelled label promise =
  match Eio.Promise.await_exn promise with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "%s returned Eta error: %s" label (cause_message cause)
  | Eta.Exit.Ok () -> failf "%s returned success" label

let await_ok label promise =
  match Eio.Promise.await_exn promise with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      failf "%s returned Eta error: %s" label (cause_message cause)

let make_candidate_edge ~eio_runtime ~sw =
  let driver = Driver.create () in
  let kernel = Kernel.create 1 in
  let completed = ref 0 in
  let cancelled_bodies = ref 0 in
  let run_one () =
    let value = !completed + 1 in
    let started, started_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let holder =
      Eio.Fiber.fork_promise ~sw (fun () ->
          let effect =
            Driver.hold_for_test
              ~after_acquired:(fun () ->
                E.sync (fun () ->
                    Eio.Promise.resolve started_resolver ();
                    Eio.Promise.await release))
              driver (fun () ->
                Kernel.set kernel value;
                Kernel.stabilize ~before_publish:(fun () -> ()) kernel)
          in
          Eta.Runtime.run eio_runtime (widen effect))
    in
    Eio.Promise.await started;
    let context = ref None in
    let contender =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Eio.Cancel.sub @@ fun cancel_context ->
          context := Some cancel_context;
          let effect =
            Driver.run driver (fun () ->
                incr cancelled_bodies;
                Kernel.set kernel (value + 1);
                Ok ())
          in
          Eta.Runtime.run eio_runtime (widen effect))
    in
    let rec wait attempts =
      if Driver.waiting driver = 1 then ()
      else if attempts = 0 then failwith "candidate edge contender did not queue"
      else (
        Eio.Fiber.yield ();
        wait (attempts - 1))
    in
    wait 100;
    Option.iter (fun cancel_context -> Eio.Cancel.cancel cancel_context Exit) !context;
    Eio.Promise.resolve release_resolver ();
    await_cancelled "candidate edge contender" contender;
    await_ok "candidate edge holder" holder;
    if Driver.waiting driver <> 0 then
      failwith "candidate edge retained a waiter";
    incr completed
  in
  {
    name = "eta_signal.effect_seam.edge.candidate_cancelled_contender";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          run_one ()
        done);
    check =
      (fun () ->
        if !cancelled_bodies <> 0 then
          failwith "candidate edge ran a cancelled body";
        if Kernel.value kernel <> !completed + 1 then
          failwith "candidate edge committed the wrong value");
  }

let make_reference_edge ~eio_runtime ~sw =
  let source = Reference.Var.create 0 in
  let blocker = ref None in
  let output =
    Reference.Var.watch source
    |> Reference.map (fun value ->
           (match !blocker with
           | None -> ()
           | Some (started_resolver, release) ->
               Eio.Promise.resolve started_resolver ();
               Eio.Promise.await release;
               blocker := None);
           value + 1)
  in
  let observer =
    run_ok eio_runtime (widen (Reference.Observer.observe output))
  in
  run_ok eio_runtime (widen Reference.stabilize);
  let completed = ref 0 in
  let run_one () =
    let value = !completed + 1 in
    run_ok eio_runtime (widen (Reference.Var.set source value));
    let started, started_resolver = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    blocker := Some (started_resolver, release);
    let holder =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Eta.Runtime.run eio_runtime (widen Reference.stabilize))
    in
    Eio.Promise.await started;
    let context = ref None in
    let contender =
      Eio.Fiber.fork_promise ~sw (fun () ->
          Eio.Cancel.sub @@ fun cancel_context ->
          context := Some cancel_context;
          Eta.Runtime.run eio_runtime
            (widen (Reference.Var.set source (value + 1))))
    in
    for _ = 1 to 5 do
      Eio.Fiber.yield ()
    done;
    Option.iter (fun cancel_context -> Eio.Cancel.cancel cancel_context Exit) !context;
    Eio.Promise.resolve release_resolver ();
    await_cancelled "reference edge contender" contender;
    await_ok "reference edge holder" holder;
    incr completed
  in
  {
    name = "eta_signal.effect_seam.edge.reference_cancelled_contender";
    run_batch =
      (fun operations ->
        for _ = 1 to operations do
          run_one ()
        done);
    check =
      (fun () ->
        let observed =
          run_ok eio_runtime (widen (Reference.Observer.read observer))
        in
        if observed <> !completed + 1 then
          failwith "reference edge committed the wrong value");
  }

type command =
  | Check
  | Measure of layer * int * int
  | Edge of edge_layer * int

let parse_args () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--check" ] -> Check
  | [ "--layer"; layer; "--depth"; depth; "--samples"; samples ] ->
      Measure (parse_layer layer, int_of_string depth, int_of_string samples)
  | [ "--edge"; layer; "--samples"; samples ] ->
      Edge (parse_edge_layer layer, int_of_string samples)
  | _ ->
      invalid_arg
        "use --check, --layer LAYER --depth DEPTH --samples COUNT, or --edge LAYER --samples COUNT"

let () =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun sw ->
  let eio_runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock environment) ()
  in
  match parse_args () with
  | Check -> check_semantics ~eio_runtime ~sw
  | Measure (layer, depth, sample_count) ->
      let workload = make_workload ~eio_runtime layer depth in
      Printf.printf
        "name,pair,operations,sample,wall_ns,allocated_words\n%!";
      measure ~sample_count workload
  | Edge (layer, sample_count) ->
      let workload =
        match layer with
        | Candidate_edge -> make_candidate_edge ~eio_runtime ~sw
        | Reference_edge -> make_reference_edge ~eio_runtime ~sw
      in
      Printf.printf
        "name,pair,operations,sample,wall_ns,allocated_words\n%!";
      measure ~sample_count workload
