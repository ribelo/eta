(* PROTOTYPE: This executable composes the selected private Signal execution
   seam with timer and observer edge protocols. It is not production code. *)

module E = Eta.Effect
module Lane = Eta_signal_lane

type probe_error = [ `Observer_failed | `Runtime_mismatch ]

let failf format = Printf.ksprintf failwith format

let cause_message cause =
  Eta.Cause.pretty
    (function
      | `Observer_failed -> "observer failed"
      | `Runtime_mismatch -> "runtime mismatch")
    cause

module Test_clock = struct
  type sleeper = {
    deadline_ms : int;
    sequence : int;
    resolver : unit Eio.Promise.u;
  }

  type t = {
    mutable now_ms : int;
    mutable next_sequence : int;
    mutable sleepers : sleeper list;
  }

  let create () = { now_ms = 0; next_sequence = 0; sleepers = [] }

  let compare_sleeper left right =
    match Int.compare left.deadline_ms right.deadline_ms with
    | 0 -> Int.compare left.sequence right.sequence
    | order -> order

  let rec insert sleeper = function
    | [] -> [ sleeper ]
    | next :: rest as sleepers ->
        if compare_sleeper sleeper next <= 0 then sleeper :: sleepers
        else next :: insert sleeper rest

  let sleep t duration =
    let deadline_ms = t.now_ms + Eta.Duration.to_ms duration in
    let promise, resolver = Eio.Promise.create () in
    let sequence = t.next_sequence in
    t.next_sequence <- sequence + 1;
    t.sleepers <- insert { deadline_ms; sequence; resolver } t.sleepers;
    try Eio.Promise.await promise
    with exn ->
      t.sleepers <-
        List.filter (fun sleeper -> sleeper.sequence <> sequence) t.sleepers;
      raise exn

  let rec adjust_to t target =
    match t.sleepers with
    | sleeper :: rest when sleeper.deadline_ms <= target ->
        t.sleepers <- rest;
        t.now_ms <- sleeper.deadline_ms;
        Eio.Promise.resolve sleeper.resolver ();
        Eio.Fiber.yield ();
        adjust_to t target
    | [] | _ :: _ -> t.now_ms <- target

  let adjust t duration =
    adjust_to t (t.now_ms + Eta.Duration.to_ms duration)

  let now_ms t = t.now_ms
  let sleeper_count t = List.length t.sleepers
end

module Execution = struct
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

  let run t operation =
    Eta.Spi.Expert.make ~leaf_name:"eta_signal_edge_seam.execution"
    @@ fun context ->
    let contract = Eta.Spi.Expert.contract context in
    let finish = function
      | Ok value -> Eta.Exit.Ok value
      | Error error -> Eta.Exit.Error (Eta.Cause.Fail error)
    in
    let run_operation () = finish (operation contract.Eta.Runtime_contract.check) in
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
end

let current_runtime () =
  Eta.Spi.Expert.make ~leaf_name:"eta_signal_edge_seam.current_runtime"
    (fun context -> Eta.Exit.Ok (Eta.Spi.Expert.contract context))

type update =
  | Initialized of int
  | Changed of int * int

type delivery =
  | Never_delivered
  | Delivered of int
  | Pending of int * update
  | Running of int * update

type lifecycle = Active | Disposed

type observer = {
  id : int;
  mutable lifecycle : lifecycle;
  mutable current : int;
  mutable delivery : delivery;
  mutable delivered_token : int option;
  callback : observer -> int -> update -> (unit, probe_error) E.t;
  finish : unit -> unit;
  mutable finish_count : int;
}

type timer_state =
  | Inactive
  | Starting of int
  | Running_timer of int * (unit -> unit)

type timer = {
  runtime : Eta.Runtime_contract.t;
  interval : Eta.Duration.t;
  mutable generation : int;
  mutable demand : int;
  mutable state : timer_state;
  mutable queued : bool;
  mutable pending_wakes : int;
  mutable committed_wakes : int;
  mutable installation : unit Eta.Runtime_contract.promise option;
  mutable fail_start_once : bool;
  mutable fail_stop_once : bool;
  mutable fail_loop_once : bool;
  mutable cancel_after_start : (unit -> unit) option;
}

type timer_action =
  | Start of
      timer
      * int
      * unit Eta.Runtime_contract.promise
      * unit Eta.Runtime_contract.resolver
  | Stop of timer * (unit -> unit)
  | Await_start of timer * unit Eta.Runtime_contract.promise

type timer_observer = {
  timer : timer;
  delivery_observer : observer;
  mutable timer_observer_active : bool;
}

type engine = {
  execution : Execution.t;
  mutable lane_held : bool;
  mutable next_observer_id : int;
  mutable next_token : int;
  mutable observers : observer list;
  mutable observer_demand : int;
  mutable source : int;
  mutable committed : int;
}

type source_signal = { source_engine : engine }

let engine () =
  {
    execution = Execution.create ();
    lane_held = false;
    next_observer_id = 0;
    next_token = 0;
    observers = [];
    observer_demand = 0;
    source = 0;
    committed = 0;
  }

let with_lane engine operation =
  Execution.run engine.execution @@ fun checkpoint ->
  if engine.lane_held then failwith "PROTOTYPE: nested lane marker";
  engine.lane_held <- true;
  Fun.protect
    ~finally:(fun () -> engine.lane_held <- false)
    (fun () -> operation checkpoint)

let outside_lane engine label =
  if engine.lane_held then failf "%s ran while the graph lane was held" label

let checked_succ label value =
  if value = max_int then failf "%s overflow" label else value + 1

let update_value = function
  | Initialized value | Changed (_, value) -> value

let delivery_base = function
  | Never_delivered | Pending (_, Initialized _) | Running (_, Initialized _) ->
      None
  | Delivered value -> Some value
  | Pending (_, Changed (old_value, _))
  | Running (_, Changed (old_value, _)) ->
      Some old_value

let create_observer ?(callback = fun _ _ _ -> E.unit)
    ?(finish = fun () -> ()) engine =
  with_lane engine @@ fun _checkpoint ->
  let id = checked_succ "observer identity" engine.next_observer_id in
  let demand =
    checked_succ "observer demand" engine.observer_demand
  in
  let observer =
    {
      id;
      lifecycle = Active;
      current = 0;
      delivery = Never_delivered;
      delivered_token = None;
      callback;
      finish;
      finish_count = 0;
    }
  in
  engine.next_observer_id <- id;
  engine.observers <- observer :: engine.observers;
  engine.observer_demand <- demand;
  Ok observer

let watch_source engine = { source_engine = engine }

let observe_source ?callback ?finish signal =
  create_observer ?callback ?finish signal.source_engine

let publish_under_lane engine observer value =
  if observer.lifecycle = Active then
    match delivery_base observer.delivery with
    | Some old_value when old_value = value ->
        observer.current <- value;
        observer.delivery <- Delivered value
    | base ->
        let token = checked_succ "observer delivery token" engine.next_token in
        let update =
          match base with
          | None -> Initialized value
          | Some old_value -> Changed (old_value, value)
        in
        engine.next_token <- token;
        observer.current <- value;
        observer.delivery <- Pending (token, update)

let claim_observer engine observer =
  with_lane engine @@ fun _checkpoint ->
  Ok
    (match observer.lifecycle, observer.delivery with
    | Active, Pending (token, update) ->
        observer.delivery <- Running (token, update);
        Some (token, update)
    | Active, (Never_delivered | Delivered _ | Running _) | Disposed, _ -> None)

let settle_observer engine observer token update delivered =
  with_lane engine @@ fun _checkpoint ->
  (match observer.lifecycle, observer.delivery with
  | Active, Running (current, _) when current = token ->
      observer.delivery <-
        if delivered then Delivered (update_value update)
        else Pending (token, update);
      if delivered then observer.delivered_token <- Some token
  | Active, _ | Disposed, _ -> ());
  Ok ()

let rec deliver_observers engine = function
  | [] -> E.unit
  | observer :: rest ->
      E.bind
        (function
          | None -> deliver_observers engine rest
          | Some (token, update) ->
              let callback =
                E.bind
                  (fun () ->
                    observer.callback observer token update)
                  (E.sync (fun () ->
                       outside_lane engine "observer callback"))
              in
              E.on_exit
                (function
                  | Eta.Exit.Ok () ->
                      settle_observer engine observer token update true
                  | Eta.Exit.Error _ ->
                      settle_observer engine observer token update false)
                callback
              |> E.bind (fun () -> deliver_observers engine rest))
        (claim_observer engine observer)

let dispose_observer_under_lane engine observer =
  match observer.lifecycle with
  | Disposed -> None
  | Active ->
      observer.lifecycle <- Disposed;
      engine.observers <-
        List.filter
          (fun candidate -> candidate.id <> observer.id)
          engine.observers;
      if engine.observer_demand <= 0 then
        failwith "PROTOTYPE: observer demand underflow";
      engine.observer_demand <- engine.observer_demand - 1;
      observer.delivery <-
        (match delivery_base observer.delivery with
        | None -> Never_delivered
        | Some value -> Delivered value);
      observer.finish_count <- observer.finish_count + 1;
      Some observer.finish

let run_finish_hook engine = function
  | None -> E.unit
  | Some finish ->
      E.sync (fun () ->
          outside_lane engine "observer finish hook";
          finish ())

let dispose_observer engine observer =
  let open Eta.Syntax in
  let* hook =
    with_lane engine @@ fun _checkpoint ->
    Ok (dispose_observer_under_lane engine observer)
  in
  run_finish_hook engine hook

let set_source engine value =
  with_lane engine @@ fun _checkpoint ->
  engine.source <- value;
  Ok ()

let stabilize_observers engine observers =
  let open Eta.Syntax in
  let* () =
    with_lane engine @@ fun checkpoint ->
    let changed = engine.source <> engine.committed in
    let uninitialized =
      List.exists
        (fun observer -> observer.delivery = Never_delivered)
        observers
    in
    if changed || uninitialized then (
      checkpoint ();
      engine.committed <- engine.source;
      List.iter
        (fun observer ->
          publish_under_lane engine observer engine.committed)
        observers);
    Ok ()
  in
  deliver_observers engine observers

let create_timer engine interval =
  let open Eta.Syntax in
  let* runtime = current_runtime () in
  with_lane engine @@ fun _checkpoint ->
  Ok
    {
      runtime;
      interval;
      generation = 0;
      demand = 0;
      state = Inactive;
      queued = false;
      pending_wakes = 0;
      committed_wakes = 0;
      installation = None;
      fail_start_once = false;
      fail_stop_once = false;
      fail_loop_once = false;
      cancel_after_start = None;
    }

let enqueue_timer timer = timer.queued <- true

let add_timer_demand timer =
  timer.demand <- checked_succ "timer demand" timer.demand;
  match timer.state with
  | Inactive -> enqueue_timer timer
  | Starting _ | Running_timer _ -> ()

let remove_timer_demand timer =
  if timer.demand <= 0 then failwith "PROTOTYPE: timer demand underflow";
  timer.demand <- timer.demand - 1;
  if timer.demand = 0 then
    match timer.state with
    | Inactive -> ()
    | Starting _ | Running_timer _ ->
        timer.generation <-
          checked_succ "timer generation fence" timer.generation;
        enqueue_timer timer

let claim_timer_action engine runtime timer =
  with_lane engine @@ fun _checkpoint ->
  if not (Eta.Runtime_contract.same_runtime runtime timer.runtime) then
    Error `Runtime_mismatch
  else (
    timer.queued <- false;
    match timer.demand, timer.state with
    | demand, Inactive when demand > 0 ->
        let generation =
          checked_succ "timer generation start" timer.generation
        in
        let #(installation, resolver) =
          runtime.Eta.Runtime_contract.create_promise ()
        in
        timer.generation <- generation;
        timer.state <- Starting generation;
        timer.installation <- Some installation;
        Ok
          (Some
             (Start
                (timer, generation, installation, resolver)))
    | 0, Running_timer (_, cancel) -> Ok (Some (Stop (timer, cancel)))
    | demand, Running_timer (active_generation, cancel)
      when demand > 0 && active_generation <> timer.generation ->
        Ok (Some (Stop (timer, cancel)))
    | _, Starting _ ->
        (match timer.installation with
        | Some installation ->
            Ok (Some (Await_start (timer, installation)))
        | None -> failwith "PROTOTYPE: starting timer has no installation")
    | _, Inactive | _, Running_timer _ -> Ok None)

let install_timer_cancel engine timer generation cancel =
  with_lane engine @@ fun _checkpoint ->
  if
    timer.demand > 0
    && timer.generation = generation
    && timer.state = Starting generation
  then (
    timer.state <- Running_timer (generation, cancel);
    timer.installation <- None;
    Ok `Continue)
  else (
    (match timer.state with
    | Starting active_generation when active_generation = generation ->
        timer.state <- Inactive;
        timer.installation <- None;
        timer.queued <- false;
        if timer.demand > 0 then enqueue_timer timer
    | Inactive | Starting _ | Running_timer _ -> ());
    Ok `Stop)

let timer_wake engine timer generation =
  let open Eta.Syntax in
  let* runtime = current_runtime () in
  with_lane engine @@ fun _checkpoint ->
  if not (Eta.Runtime_contract.same_runtime runtime timer.runtime) then
    Error `Runtime_mismatch
  else (
    (match timer.state with
    | Running_timer (active_generation, _)
      when active_generation = generation
           && timer.generation = generation
           && timer.demand > 0 ->
        timer.pending_wakes <- timer.pending_wakes + 1
    | Inactive | Starting _ | Running_timer _ -> ());
    Ok ())

let settle_timer_stop engine timer =
  with_lane engine @@ fun _checkpoint ->
  timer.state <- Inactive;
  if timer.demand > 0 then enqueue_timer timer;
  Ok ()

exception Timer_cancelled
exception Injected_timer_failure of string

let run_cancellable ~install_cancel ~loop =
  Eta.Spi.Expert.make ~leaf_name:"eta_signal_edge_seam.timer" @@ fun context ->
  let contract = Eta.Spi.Expert.contract context in
  let cancelled_exit = function
    | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
        Eta.Exit.Ok ()
    | exit -> exit
  in
  try
    contract.Eta.Runtime_contract.cancel_sub @@ fun cancel_context ->
    let cancel () =
      contract.Eta.Runtime_contract.cancel cancel_context Timer_cancelled
    in
    match Eta.Spi.Expert.eval context (install_cancel cancel) with
    | Eta.Exit.Error _ as error -> error
    | Eta.Exit.Ok `Stop -> Eta.Exit.Ok ()
    | Eta.Exit.Ok `Continue ->
        Eta.Spi.Expert.eval context loop |> cancelled_exit
  with exn ->
    if Option.is_some (contract.Eta.Runtime_contract.cancellation_reason exn)
    then Eta.Exit.Ok ()
    else Eta.Spi.Expert.exit_of_exn context exn

let settle_failed_timer_start engine timer generation =
  with_lane engine @@ fun _checkpoint ->
  (match timer.state with
  | Starting active_generation when active_generation = generation ->
      timer.state <- Inactive;
      timer.installation <- None;
      if timer.demand > 0 then enqueue_timer timer
  | Inactive | Starting _ | Running_timer _ -> ());
  Ok ()

let requeue_failed_timer_stop engine timer =
  with_lane engine @@ fun _checkpoint ->
  enqueue_timer timer;
  Ok ()

let cleanup_timer_daemon engine timer generation =
  with_lane engine @@ fun _checkpoint ->
  (match timer.state with
  | Starting active_generation when active_generation = generation ->
      timer.state <- Inactive;
      timer.installation <- None;
      if timer.demand > 0 then enqueue_timer timer
  | Running_timer (active_generation, _)
    when active_generation = generation ->
      timer.state <- Inactive;
      timer.installation <- None;
      if timer.demand > 0 then enqueue_timer timer
  | Inactive | Starting _ | Running_timer _ -> ());
  Ok ()

let start_timer engine timer generation installed installed_resolver =
  let operation =
    let open Eta.Syntax in
    let resolved = ref false in
    let resolve_installed () =
      if not !resolved then (
        resolved := true;
        timer.runtime.Eta.Runtime_contract.resolve_promise
          installed_resolver ())
    in
    let notify_installed effect =
      E.on_exit
        (fun _exit -> E.sync resolve_installed)
        effect
    in
    let step =
      let* () = E.sleep timer.interval in
      let* () =
        E.sync (fun () ->
            if timer.fail_loop_once then (
              timer.fail_loop_once <- false;
              raise (Injected_timer_failure "loop")))
      in
      timer_wake engine timer generation
    in
    let daemon =
      run_cancellable
        ~install_cancel:
          (fun cancel ->
            notify_installed
              (install_timer_cancel engine timer generation cancel))
        ~loop:(E.forever step)
      |> E.on_exit (fun _exit ->
             cleanup_timer_daemon engine timer generation)
    in
    let start =
      let* () =
        E.sync (fun () ->
            outside_lane engine "timer start";
            if timer.fail_start_once then (
              timer.fail_start_once <- false;
              raise (Injected_timer_failure "start")))
      in
      let* () = Eta.Spi.daemon daemon in
      let* () =
        E.sync (fun () ->
            timer.runtime.Eta.Runtime_contract.await_promise installed)
      in
      E.sync (fun () ->
          match timer.cancel_after_start with
          | None -> ()
          | Some cancel ->
              timer.cancel_after_start <- None;
              cancel ();
              Eio.Fiber.check ())
    in
    E.on_exit
      (function
        | Eta.Exit.Ok () -> E.sync resolve_installed
        | Eta.Exit.Error _ ->
            let* () =
              settle_failed_timer_start engine timer generation
            in
            E.sync resolve_installed)
      start
  in
  operation

let stop_timer engine timer cancel =
  let operation =
    let open Eta.Syntax in
    let* () =
      E.sync (fun () ->
          outside_lane engine "timer stop";
          if timer.fail_stop_once then (
            timer.fail_stop_once <- false;
            raise (Injected_timer_failure "stop"));
          cancel ())
    in
    settle_timer_stop engine timer
  in
  E.on_exit
    (function
      | Eta.Exit.Ok () -> E.unit
      | Eta.Exit.Error _ -> requeue_failed_timer_stop engine timer)
    operation

let run_timer_action engine = function
  | None -> E.unit
  | Some (Start (timer, generation, installed, resolver)) ->
      start_timer engine timer generation installed resolver
  | Some (Stop (timer, cancel)) -> stop_timer engine timer cancel
  | Some (Await_start (timer, installed)) ->
      E.sync (fun () ->
          timer.runtime.Eta.Runtime_contract.await_promise installed)

let rec reconcile_timer engine timer =
  let open Eta.Syntax in
  let* runtime = current_runtime () in
  let* action = claim_timer_action engine runtime timer in
  let* () = run_timer_action engine action in
  if timer.queued then reconcile_timer engine timer else E.unit

let validate_timer_runtime engine runtime timer =
  with_lane engine @@ fun _checkpoint ->
  if Eta.Runtime_contract.same_runtime runtime timer.runtime then Ok ()
  else Error `Runtime_mismatch

let abort_timer_observation engine observer =
  with_lane engine @@ fun _checkpoint ->
  if observer.timer_observer_active then (
    observer.timer_observer_active <- false;
    remove_timer_demand observer.timer);
  if observer.timer.demand = 0 && observer.timer.state = Inactive then
    observer.timer.queued <- false;
  ignore
    (dispose_observer_under_lane engine observer.delivery_observer :
      (unit -> unit) option);
  Ok ()

let observe_timer engine timer =
  let observer = ref None in
  let operation =
    let open Eta.Syntax in
    let* runtime = current_runtime () in
    let* () = validate_timer_runtime engine runtime timer in
    let* delivery_observer = create_observer engine in
    let registration =
      {
        timer;
        delivery_observer;
        timer_observer_active = true;
      }
    in
    observer := Some registration;
    let* () =
      with_lane engine @@ fun _checkpoint ->
      add_timer_demand timer;
      Ok ()
    in
    E.map (fun () -> registration) (reconcile_timer engine timer)
  in
  operation
  |> E.on_exit (function
       | Eta.Exit.Ok _ -> E.unit
       | Eta.Exit.Error _ -> (
           match !observer with
           | None -> E.unit
           | Some observer ->
               let open Eta.Syntax in
               let* () = abort_timer_observation engine observer in
               reconcile_timer engine timer))

let dispose_timer_observer engine observer =
  let open Eta.Syntax in
  let* runtime = current_runtime () in
  let* () =
    validate_timer_runtime engine runtime observer.timer
  in
  let* hook =
    with_lane engine @@ fun _checkpoint ->
    if observer.timer_observer_active then (
      observer.timer_observer_active <- false;
      remove_timer_demand observer.timer);
    Ok
      (dispose_observer_under_lane engine
         observer.delivery_observer)
  in
  reconcile_timer engine observer.timer
  |> E.on_exit (fun _exit -> run_finish_hook engine hook)

let stabilize_timer engine observer =
  let open Eta.Syntax in
  let timer = observer.timer in
  let* () = reconcile_timer engine timer in
  let* () =
    with_lane engine @@ fun checkpoint ->
    let uninitialized =
      observer.delivery_observer.delivery = Never_delivered
    in
    if timer.pending_wakes > 0 || uninitialized then (
      checkpoint ();
      timer.committed_wakes <- timer.committed_wakes + timer.pending_wakes;
      timer.pending_wakes <- 0;
      publish_under_lane engine observer.delivery_observer
        timer.committed_wakes);
    Ok ()
  in
  deliver_observers engine [ observer.delivery_observer ]

let rec wait_until label predicate attempts =
  if predicate () then ()
  else if attempts = 0 then failf "timed out: %s" label
  else (
    Eio.Fiber.yield ();
    wait_until label predicate (attempts - 1))

let run_ok runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> failwith (cause_message cause)

let run_typed_error runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Error (Eta.Cause.Fail `Observer_failed) -> ()
  | Eta.Exit.Error cause ->
      failf "expected observer failure, got %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "expected observer failure"

let run_defect runtime effect =
  match Eta_eio.Runtime.run runtime effect with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause ->
      failf "expected observer defect, got %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "expected observer defect"

type workload = {
  name : string;
  run : int -> unit;
  check : unit -> unit;
}

let make_observer_failure_retry runtime =
  let engine = engine () in
  let fail_next = ref false in
  let callback_token = ref None in
  let observer =
    run_ok runtime
      (observe_source (watch_source engine)
         ~callback:(fun _ token _ ->
           callback_token := Some token;
           if !fail_next then (
             fail_next := false;
             E.fail `Observer_failed)
           else E.unit))
  in
  run_ok runtime (stabilize_observers engine [ observer ]);
  let completed = ref 0 in
  ( {
      name = "observer_failure_retry";
      run =
        (fun operations ->
          for _ = 1 to operations do
            incr completed;
            fail_next := true;
            run_ok runtime (set_source engine !completed);
            run_typed_error runtime
              (stabilize_observers engine [ observer ]);
            run_ok runtime (stabilize_observers engine [ observer ])
          done);
      check =
        (fun () ->
          match
            observer.delivery,
            !callback_token,
            observer.delivered_token
          with
          | Delivered value, Some callback_token, Some delivered_token
            when value = !completed
                 && callback_token = delivered_token ->
              ()
          | _ -> failwith "candidate observer retry state mismatch");
    },
    engine,
    observer )

let make_observer_disposal runtime =
  let engine = engine () in
  {
    name = "observer_disposal";
    run =
      (fun operations ->
        for _ = 1 to operations do
          let observer =
            run_ok runtime
              (observe_source (watch_source engine))
          in
          run_ok runtime (dispose_observer engine observer)
        done);
    check = (fun () -> ());
  }

let make_timer_cycle runtime clock =
  let engine = engine () in
  let timer =
    run_ok runtime (create_timer engine (Eta.Duration.ms 1))
  in
  let completed = ref 0 in
  {
    name = "timer_cycle";
    run =
      (fun operations ->
        for _ = 1 to operations do
          let observer = run_ok runtime (observe_timer engine timer) in
          wait_until "candidate timer start"
            (fun () -> Test_clock.sleeper_count clock = 1)
            100;
          Test_clock.adjust clock (Eta.Duration.ms 1);
          wait_until "candidate timer wake"
            (fun () ->
              timer.pending_wakes = 1
              && Test_clock.sleeper_count clock = 1)
            100;
          run_ok runtime (stabilize_timer engine observer);
          run_ok runtime (dispose_timer_observer engine observer);
          wait_until "candidate timer stop"
            (fun () -> Test_clock.sleeper_count clock = 0)
            100;
          incr completed
        done);
    check =
      (fun () ->
        if timer.committed_wakes <> !completed then
          failwith "candidate timer cycle state mismatch");
  }

let check_semantics runtime foreign_runtime clock =
  let workload, base_engine, observer =
    make_observer_failure_retry runtime
  in
  workload.run 1;
  workload.check ();
  let defect_next = ref true in
  let defect_token = ref None in
  let defective =
    run_ok runtime
      (observe_source (watch_source base_engine)
         ~callback:(fun _ token _ ->
           defect_token := Some token;
           if !defect_next then (
             defect_next := false;
             E.sync (fun () -> failwith "injected observer defect"))
           else E.unit))
  in
  run_ok runtime (set_source base_engine 2);
  run_defect runtime
    (stabilize_observers base_engine [ defective ]);
  (match !defect_token, defective.delivery with
  | Some expected, Pending (actual, _) when expected = actual -> ()
  | _ -> failwith "observer defect did not restore pending delivery");
  run_ok runtime (stabilize_observers base_engine [ defective ]);
  let finish_calls = ref 0 in
  let disposable =
    run_ok runtime
      (observe_source (watch_source base_engine)
         ~finish:(fun () ->
           outside_lane base_engine "observer finish check";
           incr finish_calls))
  in
  run_ok runtime (dispose_observer base_engine disposable);
  run_ok runtime (dispose_observer base_engine disposable);
  if !finish_calls <> 1 || disposable.finish_count <> 1 then
    failwith "observer disposal was not idempotent";
  let interrupting = ref true in
  let cancel_context = ref None in
  let interrupted_token = ref None in
  let interrupted =
    run_ok runtime
      (observe_source (watch_source base_engine)
         ~callback:(fun _ token _ ->
           interrupted_token := Some token;
           if !interrupting then
             E.sync (fun () ->
                 Option.iter
                   (fun context -> Eio.Cancel.cancel context Exit)
                   !cancel_context;
                 Eio.Fiber.check ())
           else E.unit))
  in
  run_ok runtime (set_source base_engine 3);
  (match
     Eio.Cancel.sub @@ fun context ->
     cancel_context := Some context;
     Eta_eio.Runtime.run runtime
       (stabilize_observers base_engine [ interrupted ])
   with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "observer interruption became an Eta error: %s"
        (cause_message cause)
  | Eta.Exit.Ok () -> failwith "observer interruption returned success");
  (match !interrupted_token, interrupted.delivery with
  | Some expected, Pending (actual, _) when expected = actual -> ()
  | _ -> failwith "observer interruption did not restore pending delivery");
  interrupting := false;
  run_ok runtime
    (stabilize_observers base_engine [ interrupted ]);
  let foreign_engine = engine () in
  let foreign_timer =
    run_ok runtime
      (create_timer foreign_engine (Eta.Duration.ms 1))
  in
  (match
     Eta_eio.Runtime.run foreign_runtime
       (observe_timer foreign_engine foreign_timer)
   with
  | Eta.Exit.Error (Eta.Cause.Fail `Runtime_mismatch) -> ()
  | Eta.Exit.Error cause ->
      failf "runtime mismatch returned %s" (cause_message cause)
  | Eta.Exit.Ok _ -> failwith "foreign runtime claimed timer work");
  if
    foreign_timer.queued || foreign_timer.demand <> 0
    || foreign_engine.observer_demand <> 0
    || foreign_engine.observers <> []
  then failwith "runtime mismatch changed timer registration state";
  let initialization_engine = engine () in
  let initialization_timer =
    run_ok runtime
      (create_timer initialization_engine (Eta.Duration.ms 1))
  in
  let initialization_observer =
    run_ok runtime
      (observe_timer initialization_engine initialization_timer)
  in
  (match
     Eta_eio.Runtime.run foreign_runtime
       (stabilize_timer initialization_engine
          initialization_observer)
   with
  | Eta.Exit.Error (Eta.Cause.Fail `Runtime_mismatch) -> ()
  | Eta.Exit.Error cause ->
      failf "foreign stabilization returned %s"
        (cause_message cause)
  | Eta.Exit.Ok () -> failwith "foreign runtime stabilized a timer");
  (match
     Eta_eio.Runtime.run foreign_runtime
       (timer_wake initialization_engine initialization_timer
          initialization_timer.generation)
   with
  | Eta.Exit.Error (Eta.Cause.Fail `Runtime_mismatch) -> ()
  | Eta.Exit.Error cause ->
      failf "foreign timer wake returned %s" (cause_message cause)
  | Eta.Exit.Ok () -> failwith "foreign runtime admitted a timer wake");
  run_ok runtime
    (stabilize_timer initialization_engine initialization_observer);
  (match initialization_observer.delivery_observer.delivery with
  | Delivered 0 -> ()
  | _ -> failwith "timer observer did not initialize without a wake");
  run_ok runtime
    (dispose_timer_observer initialization_engine
       initialization_observer);
  wait_until "immediate timer disposal"
    (fun () -> Test_clock.sleeper_count clock = 0)
    100;
  (match initialization_timer.state with
  | Inactive
    when initialization_timer.demand = 0
         && not initialization_timer.queued ->
      ()
  | Inactive | Starting _ | Running_timer _ ->
      failwith "immediate timer disposal did not settle");
  let registration_engine = engine () in
  let registration_timer =
    run_ok runtime
      (create_timer registration_engine (Eta.Duration.ms 1))
  in
  registration_timer.fail_start_once <- true;
  run_defect runtime
    (E.discard
       (observe_timer registration_engine registration_timer));
  if
    registration_timer.demand <> 0 || registration_timer.queued
    || registration_timer.state <> Inactive
    || registration_engine.observer_demand <> 0
    || registration_engine.observers <> []
  then failwith "failed timer start leaked observer registration";
  let cancellation_engine = engine () in
  let cancellation_timer =
    run_ok runtime
      (create_timer cancellation_engine (Eta.Duration.ms 1))
  in
  (match
     Eio.Cancel.sub @@ fun context ->
     cancellation_timer.cancel_after_start <-
       Some (fun () -> Eio.Cancel.cancel context Exit);
     Eta_eio.Runtime.run runtime
       (observe_timer cancellation_engine cancellation_timer)
   with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Error cause ->
      failf "cancelled timer registration returned %s"
        (cause_message cause)
  | Eta.Exit.Ok _ -> failwith "cancelled timer registration succeeded");
  wait_until "cancelled timer registration cleanup"
    (fun () -> Test_clock.sleeper_count clock = 0)
    100;
  if
    cancellation_timer.demand <> 0 || cancellation_timer.queued
    || cancellation_timer.state <> Inactive
    || cancellation_engine.observer_demand <> 0
    || cancellation_engine.observers <> []
  then failwith "cancelled timer registration leaked daemon state";
  let disposal_engine = engine () in
  let disposal_timer =
    run_ok runtime
      (create_timer disposal_engine (Eta.Duration.ms 1))
  in
  let disposal_observer =
    run_ok runtime (observe_timer disposal_engine disposal_timer)
  in
  wait_until "disposal failure timer start"
    (fun () -> Test_clock.sleeper_count clock = 1)
    100;
  disposal_timer.fail_stop_once <- true;
  run_defect runtime
    (dispose_timer_observer disposal_engine disposal_observer);
  if
    disposal_observer.delivery_observer.lifecycle <> Disposed
    || disposal_engine.observer_demand <> 0
    || disposal_engine.observers <> []
    || disposal_timer.demand <> 0
    || not disposal_timer.queued
  then failwith "failed timer stop retained observer registration";
  run_ok runtime (reconcile_timer disposal_engine disposal_timer);
  wait_until "disposal failure timer stop retry"
    (fun () -> Test_clock.sleeper_count clock = 0)
    100;
  let daemon_engine = engine () in
  let daemon_timer =
    run_ok runtime
      (create_timer daemon_engine (Eta.Duration.ms 1))
  in
  let daemon_observer =
    run_ok runtime (observe_timer daemon_engine daemon_timer)
  in
  wait_until "daemon failure timer start"
    (fun () -> Test_clock.sleeper_count clock = 1)
    100;
  daemon_timer.fail_loop_once <- true;
  Test_clock.adjust clock (Eta.Duration.ms 1);
  wait_until "daemon failure cleanup"
    (fun () ->
      daemon_timer.state = Inactive && daemon_timer.queued)
    100;
  run_ok runtime (stabilize_timer daemon_engine daemon_observer);
  wait_until "daemon failure restart"
    (fun () -> Test_clock.sleeper_count clock = 1)
    100;
  run_ok runtime
    (dispose_timer_observer daemon_engine daemon_observer);
  wait_until "daemon failure final stop"
    (fun () -> Test_clock.sleeper_count clock = 0)
    100;
  let failure_engine = engine () in
  let failure_timer =
    run_ok runtime
      (create_timer failure_engine (Eta.Duration.ms 1))
  in
  failure_timer.fail_start_once <- true;
  run_ok runtime
    (with_lane failure_engine @@ fun _checkpoint ->
     add_timer_demand failure_timer;
     Ok ());
  run_defect runtime (reconcile_timer failure_engine failure_timer);
  (match failure_timer.state with
  | Inactive when failure_timer.queued && failure_timer.demand = 1 -> ()
  | Inactive | Starting _ | Running_timer _ ->
      failwith "failed timer start lost retry state");
  run_ok runtime (reconcile_timer failure_engine failure_timer);
  wait_until "timer start retry"
    (fun () -> Test_clock.sleeper_count clock = 1)
    100;
  let first_generation = failure_timer.generation in
  run_ok runtime
    (with_lane failure_engine @@ fun _checkpoint ->
     remove_timer_demand failure_timer;
     add_timer_demand failure_timer;
     Ok ());
  run_ok runtime
    (timer_wake failure_engine failure_timer first_generation);
  if failure_timer.pending_wakes <> 0 then
    failwith "generation fence admitted a reentry wake";
  run_ok runtime (reconcile_timer failure_engine failure_timer);
  (match failure_timer.state with
  | Running_timer (generation, _)
    when generation > first_generation && failure_timer.demand = 1 ->
      ()
  | Inactive | Starting _ | Running_timer _ ->
      failwith "demand reentry did not restart the fenced timer");
  let live_generation = failure_timer.generation in
  run_ok runtime
    (with_lane failure_engine @@ fun _checkpoint ->
     remove_timer_demand failure_timer;
     Ok ());
  run_ok runtime
    (timer_wake failure_engine failure_timer live_generation);
  if failure_timer.pending_wakes <> 0 then
    failwith "generation fence admitted a late timer wake";
  failure_timer.fail_stop_once <- true;
  run_defect runtime (reconcile_timer failure_engine failure_timer);
  (match failure_timer.state with
  | Running_timer _ when failure_timer.queued -> ()
  | Inactive | Starting _ | Running_timer _ ->
      failwith "failed timer stop lost retry state");
  run_ok runtime (reconcile_timer failure_engine failure_timer);
  wait_until "timer stop retry"
    (fun () -> Test_clock.sleeper_count clock = 0)
    100;
  let timer_workload = make_timer_cycle runtime clock in
  timer_workload.run 1;
  timer_workload.check ();
  ignore observer;
  Printf.printf "semantic checks: pass\n%!"

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure workload samples =
  let operations = calibrate workload 1 in
  workload.run operations;
  workload.check ();
  Gc.full_major ();
  Printf.printf "side,name,pair,operations,sample,wall_ns,allocated_words\n%!";
  let pair = Option.value (Sys.getenv_opt "PAIR") ~default:"1" in
  for sample = 1 to samples do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run operations;
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
    Printf.printf "candidate,%s,%s,%d,%d,%.6f,%.6f\n%!" workload.name pair
      operations sample wall_ns allocated_words
  done

let () =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let make_runtime () =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock environment)
      ~sleep:(Test_clock.sleep clock)
      ~now_ms:(fun () -> Test_clock.now_ms clock)
      ()
  in
  let runtime = make_runtime () in
  match List.tl (Array.to_list Sys.argv) with
  | [ "--check" ] ->
      let foreign_runtime = make_runtime () in
      check_semantics runtime foreign_runtime clock
  | [ "--measure"; name; "--samples"; samples ] ->
      let workload =
        match name with
        | "observer_failure_retry" ->
            let workload, _, _ = make_observer_failure_retry runtime in
            workload
        | "observer_disposal" -> make_observer_disposal runtime
        | "timer_cycle" -> make_timer_cycle runtime clock
        | _ -> invalid_arg ("unknown candidate workload: " ^ name)
      in
      measure workload (int_of_string samples)
  | _ ->
      invalid_arg "use --check or --measure WORKLOAD --samples COUNT"
