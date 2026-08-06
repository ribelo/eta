(* PROTOTYPE: This executable tests post-commit Signal edge protocols.
   It is not production Signal code. *)

exception Injected_failure of string
exception Runtime_mismatch
exception Cancelled
exception Counter_overflow of string

let failf format = Printf.ksprintf failwith format

let checked_succ label value =
  if value = max_int then raise (Counter_overflow label) else value + 1

type counters = {
  mutable lane_entries : int;
  mutable cleanup_claims : int;
  mutable cleanup_attempts : int;
  mutable callback_claims : int;
  mutable callback_attempts : int;
  mutable acknowledgements : int;
  mutable releases : int;
  mutable terminal_skips : int;
  mutable timer_wakes : int;
}

let counters () =
  {
    lane_entries = 0;
    cleanup_claims = 0;
    cleanup_attempts = 0;
    callback_claims = 0;
    callback_attempts = 0;
    acknowledgements = 0;
    releases = 0;
    terminal_skips = 0;
    timer_wakes = 0;
  }

type lane = {
  counts : counters;
  mutable held : bool;
}

let lane counts = { counts; held = false }

let with_lane lane f =
  if lane.held then failwith "PROTOTYPE: lane reentry";
  lane.counts.lane_entries <- lane.counts.lane_entries + 1;
  lane.held <- true;
  Fun.protect ~finally:(fun () -> lane.held <- false) f

let outside_lane lane label =
  if lane.held then failf "%s ran while the graph lane was held" label

type update =
  | Initialized of int
  | Changed of int * int

type delivery =
  | Never_delivered
  | Delivered of int
  | Pending of int * update
  | Running of int * update

type lifecycle =
  | Active
  | Disposed
  | Invalid_scope

type observer = {
  id : int;
  mutable lifecycle : lifecycle;
  mutable current : int;
  mutable delivery : delivery;
  callback : observer -> int -> update -> unit;
  finish : string -> unit;
  mutable finish_count : int;
}

let update_value = function
  | Initialized value | Changed (_, value) -> value

let make_observer ?(initial = 0) ?(callback = fun _ _ _ -> ())
    ?(finish = fun _ -> ()) id =
  {
    id;
    lifecycle = Active;
    current = initial;
    delivery = Never_delivered;
    callback;
    finish;
    finish_count = 0;
  }

type engine = {
  lane : lane;
  counts : counters;
  mutable next_token : int;
  mutable pending_hooks : (unit -> unit) list;
}

let engine () =
  let counts = counters () in
  { lane = lane counts; counts; next_token = 0; pending_hooks = [] }

let delivery_base = function
  | Never_delivered | Pending (_, Initialized _) | Running (_, Initialized _) ->
      None
  | Delivered value -> Some value
  | Pending (_, Changed (old_value, _))
  | Running (_, Changed (old_value, _)) ->
      Some old_value

let publish engine observer value =
  with_lane engine.lane @@ fun () ->
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

let acknowledge engine observer token =
  with_lane engine.lane @@ fun () ->
  match observer.lifecycle, observer.delivery with
  | Active, (Pending (current, update) | Running (current, update))
    when current = token ->
      observer.delivery <- Delivered (update_value update);
      engine.counts.acknowledgements <- engine.counts.acknowledgements + 1;
      true
  | Active, _ | Disposed, _ | Invalid_scope, _ -> false

module Delivery_capability : sig
  type t

  val create_for_driver : engine -> observer -> int -> t
  val acknowledge : t -> bool
end = struct
  type t = {
    acknowledge_token : unit -> bool;
    mutable used : bool;
  }

  let create_for_driver engine observer token =
    {
      acknowledge_token = (fun () -> acknowledge engine observer token);
      used = false;
    }

  let acknowledge capability =
    if capability.used then false
    else (
      capability.used <- true;
      capability.acknowledge_token ())
end

let finish_observer engine observer reason =
  let hook =
    with_lane engine.lane @@ fun () ->
    match observer.lifecycle with
    | Disposed | Invalid_scope -> None
    | Active ->
        observer.lifecycle <-
          if reason = "invalid_scope" then Invalid_scope else Disposed;
        observer.delivery <-
          (match delivery_base observer.delivery with
          | None -> Never_delivered
          | Some value -> Delivered value);
        observer.finish_count <- observer.finish_count + 1;
        Some (fun () ->
            outside_lane engine.lane "observer finish hook";
            observer.finish reason)
  in
  Option.iter (fun hook -> engine.pending_hooks <- hook :: engine.pending_hooks) hook

let claim_delivery engine observer =
  with_lane engine.lane @@ fun () ->
  match observer.lifecycle, observer.delivery with
  | Active, Pending (token, update) ->
      observer.delivery <- Running (token, update);
      engine.counts.callback_claims <- engine.counts.callback_claims + 1;
      Some (token, update)
  | Active, (Never_delivered | Delivered _ | Running _)
  | (Disposed | Invalid_scope), _ ->
      engine.counts.terminal_skips <- engine.counts.terminal_skips + 1;
      None

let settle_delivery engine observer token update delivered =
  with_lane engine.lane @@ fun () ->
  match observer.lifecycle, observer.delivery with
  | Active, Running (current, _) when current = token ->
      if delivered then (
        observer.delivery <- Delivered (update_value update);
        engine.counts.acknowledgements <- engine.counts.acknowledgements + 1)
      else (
        observer.delivery <- Pending (token, update);
        engine.counts.releases <- engine.counts.releases + 1)
  | Active, _ | Disposed, _ | Invalid_scope, _ -> ()

type timer_state =
  | Inactive
  | Running_timer of (unit -> unit)

type timer = {
  runtime : int;
  mutable generation : int;
  mutable demanded : bool;
  mutable state : timer_state;
  mutable queued : bool;
  mutable source_work : int;
  start : int -> unit -> (unit -> unit);
}

type timer_store = {
  registry : timer list;
  mutable queued : timer list;
}

let make_timer ?(start = fun _generation () -> fun () -> ()) runtime =
  {
    runtime;
    generation = 0;
    demanded = false;
    state = Inactive;
    queued = false;
    source_work = 0;
    start;
  }

let timer_store registry = { registry; queued = [] }
let no_timers = timer_store []

let enqueue_timer (store : timer_store) (timer : timer) =
  if not timer.queued then (
    timer.queued <- true;
    store.queued <- timer :: store.queued)

let set_timer_demand store timer demanded =
  let active =
    match timer.state with
    | Inactive -> false
    | Running_timer _ -> true
  in
  let generation =
    if active <> demanded && not demanded then
      checked_succ "timer generation" timer.generation
    else timer.generation
  in
  timer.demanded <- demanded;
  timer.generation <- generation;
  if active <> demanded then enqueue_timer store timer

type timer_action =
  | Start of timer * int
  | Stop of timer * int * (unit -> unit)

let claim_timer_actions engine runtime (store : timer_store) =
  with_lane engine.lane @@ fun () ->
  let queued = List.rev store.queued in
  List.iter
    (fun (timer : timer) ->
      if timer.queued && timer.runtime <> runtime then raise Runtime_mismatch)
    queued;
  List.iter
    (fun (timer : timer) ->
      match timer.demanded, timer.state with
      | true, Inactive ->
          ignore (checked_succ "timer generation" timer.generation : int)
      | true, Running_timer _ | false, Inactive | false, Running_timer _ -> ())
    queued;
  let actions = ref [] in
  List.iter
    (fun (timer : timer) ->
      if timer.queued then (
        timer.queued <- false;
        engine.counts.cleanup_claims <- engine.counts.cleanup_claims + 1;
        match timer.demanded, timer.state with
        | true, Inactive ->
            timer.generation <-
              checked_succ "timer generation" timer.generation;
            actions := Start (timer, timer.generation) :: !actions
        | false, Running_timer cancel ->
            actions := Stop (timer, timer.generation, cancel) :: !actions
        | true, Running_timer _ | false, Inactive -> ()))
    queued;
  store.queued <- [];
  List.rev !actions

let run_timer_actions engine store actions =
  let failures = ref [] in
  List.iter
    (function
      | Start (timer, generation) ->
          engine.counts.cleanup_attempts <- engine.counts.cleanup_attempts + 1;
          (try
             outside_lane engine.lane "timer start";
             let cancel = timer.start generation () in
             with_lane engine.lane @@ fun () ->
             if timer.demanded && timer.generation = generation then
               timer.state <- Running_timer cancel
             else engine.pending_hooks <- cancel :: engine.pending_hooks
           with exn ->
             with_lane engine.lane (fun () -> enqueue_timer store timer);
             failures := exn :: !failures)
      | Stop (timer, generation, cancel) ->
          engine.counts.cleanup_attempts <- engine.counts.cleanup_attempts + 1;
          (try
             outside_lane engine.lane "timer stop";
             cancel ();
             with_lane engine.lane @@ fun () ->
             timer.state <- Inactive;
             if timer.demanded || timer.generation <> generation then
               enqueue_timer store timer
           with exn ->
             with_lane engine.lane (fun () -> enqueue_timer store timer);
             failures := exn :: !failures))
    actions;
  List.rev !failures

let run_hooks engine =
  let hooks =
    with_lane engine.lane @@ fun () ->
    let hooks = engine.pending_hooks in
    engine.pending_hooks <- [];
    hooks
  in
  let failures = ref [] in
  List.iter
    (fun hook ->
      engine.counts.cleanup_attempts <- engine.counts.cleanup_attempts + 1;
      try
        outside_lane engine.lane "cleanup hook";
        hook ()
      with exn -> failures := exn :: !failures)
    hooks;
  List.rev !failures

let deliver engine observers =
  let rec loop = function
    | [] -> []
    | observer :: rest -> (
        match claim_delivery engine observer with
        | None -> loop rest
        | Some (token, update) ->
            engine.counts.callback_attempts <-
              engine.counts.callback_attempts + 1;
            let delivered, failure =
              try
                outside_lane engine.lane "observer callback";
                observer.callback observer token update;
                (true, None)
              with exn -> (false, Some exn)
            in
            settle_delivery engine observer token update delivered;
            match failure with
            | None -> loop rest
            | Some exn -> [ exn ])
  in
  loop observers

let run_postcommit engine ~runtime ~timers ~observers =
  let actions = claim_timer_actions engine runtime timers in
  let failures = run_timer_actions engine timers actions @ run_hooks engine in
  match failures with
  | [] -> deliver engine observers
  | _ -> failures

let timer_wake engine runtime timer generation =
  with_lane engine.lane @@ fun () ->
  if timer.runtime <> runtime then raise Runtime_mismatch;
  match timer.state with
  | Running_timer _ when timer.generation = generation && timer.demanded ->
      timer.source_work <- timer.source_work + 1;
      engine.counts.timer_wakes <- engine.counts.timer_wakes + 1;
      true
  | Inactive | Running_timer _ -> false

type stream_bridge = {
  capacity : int;
  queue : update Queue.t;
  on_drop : update -> unit;
  mutable sent : int;
  mutable dropped : int;
  mutable acknowledged : int;
  mutable logged_drop_failures : int;
}

let stream_bridge ?(on_drop = fun _ -> ()) capacity =
  if capacity <= 0 then invalid_arg "PROTOTYPE: non-positive stream capacity";
  {
    capacity;
    queue = Queue.create ();
    on_drop;
    sent = 0;
    dropped = 0;
    acknowledged = 0;
    logged_drop_failures = 0;
  }

let offer_stream bridge capability update ~interrupt_after_publish =
  let acknowledge_once () =
    if Delivery_capability.acknowledge capability then
      bridge.acknowledged <- bridge.acknowledged + 1
    else failwith "PROTOTYPE: rejected stream acknowledgement"
  in
  if Queue.length bridge.queue = bridge.capacity then (
    bridge.dropped <- bridge.dropped + 1;
    (try bridge.on_drop update
     with _ -> bridge.logged_drop_failures <- bridge.logged_drop_failures + 1);
    acknowledge_once ())
  else (
    Queue.add update bridge.queue;
    bridge.sent <- bridge.sent + 1;
    Fun.protect ~finally:acknowledge_once @@ fun () ->
    if interrupt_after_publish then raise Cancelled)

let expect_failure label = function
  | [ Injected_failure actual ] when actual = label -> ()
  | [] -> failf "expected %s failure" label
  | failures -> failf "expected one %s failure, got %d" label (List.length failures)

let check_observer_protocol () =
  let engine = engine () in
  let trace = ref [] in
  let dependency =
    make_observer 1 ~callback:(fun _ _ _ -> trace := "dependency" :: !trace)
  in
  let consumer =
    make_observer 2 ~callback:(fun _ _ _ -> trace := "consumer" :: !trace)
  in
  publish engine dependency 1;
  publish engine consumer 1;
  if run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ dependency; consumer ] <> []
  then failwith "ordered delivery failed";
  if List.rev !trace <> [ "dependency"; "consumer" ] then
    failwith "delivery changed the frozen topological order";
  let attempts = ref 0 in
  let last_update = ref None in
  let failing =
    make_observer 3 ~callback:(fun _ _ update ->
        incr attempts;
        last_update := Some update;
        if !attempts = 1 then raise (Injected_failure "callback"))
  in
  publish engine failing 7;
  expect_failure "callback"
    (run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ failing ]);
  (match failing.delivery with
  | Pending _ -> ()
  | _ -> failwith "failed callback did not remain pending");
  publish engine failing 8;
  if run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ failing ] <> []
  then failwith "callback retry failed";
  if !attempts <> 2 then failwith "callback retry count mismatch";
  (match !last_update with
  | Some (Initialized 8) -> ()
  | Some (Initialized _ | Changed _) | None ->
      failwith "callback retry did not coalesce to the latest value");
  let changed_attempts = ref 0 in
  let fail_changed = ref false in
  let changed =
    make_observer 30 ~callback:(fun _ _ _ ->
        incr changed_attempts;
        if !fail_changed then raise (Injected_failure "changed"))
  in
  publish engine changed 0;
  ignore
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ changed ]);
  fail_changed := true;
  publish engine changed 1;
  expect_failure "changed"
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ changed ]);
  publish engine changed 0;
  ignore
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ changed ]);
  if !changed_attempts <> 2 then
    failwith "return to delivered value ran another callback";
  (match changed.delivery with
  | Delivered 0 -> ()
  | _ -> failwith "return to delivered value stayed pending");
  let dispose_during_callback =
    make_observer 4 ~callback:(fun observer _ _ ->
        finish_observer engine observer "disposed")
  in
  publish engine dispose_during_callback 9;
  ignore
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ dispose_during_callback ]);
  if dispose_during_callback.lifecycle <> Disposed then
    failwith "callback disposal did not win";
  if dispose_during_callback.finish_count <> 1 then
    failwith "finish hook was not registered once";
  ignore (run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[]);
  if dispose_during_callback.finish_count <> 1 then
    failwith "finish ran more than once";
  let acknowledge_then_fail =
    make_observer 5 ~callback:(fun observer token _ ->
        ignore (acknowledge engine observer token : bool);
        raise (Injected_failure "after_ack"))
  in
  publish engine acknowledge_then_fail 11;
  expect_failure "after_ack"
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ acknowledge_then_fail ]);
  (match acknowledge_then_fail.delivery with
  | Delivered 11 -> ()
  | _ -> failwith "failure restored an acknowledged delivery");
  let interrupted =
    make_observer 6 ~callback:(fun _ _ _ -> raise Cancelled)
  in
  publish engine interrupted 13;
  (match run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ interrupted ] with
  | [ Cancelled ] -> ()
  | _ -> failwith "interruption did not escape delivery");
  (match interrupted.delivery with
  | Pending _ -> ()
  | _ -> failwith "interruption did not release the delivery");
  let invalid_reasons = ref [] in
  let invalid_attempts = ref 0 in
  let invalid =
    make_observer 7 ~callback:(fun _ _ _ -> incr invalid_attempts)
      ~finish:(fun reason -> invalid_reasons := reason :: !invalid_reasons)
  in
  publish engine invalid 1;
  finish_observer engine invalid "invalid_scope";
  ignore
    (run_postcommit engine ~runtime:1 ~timers:no_timers
       ~observers:[ invalid ]);
  if invalid.lifecycle <> Invalid_scope then
    failwith "invalid-scope finish lost its lifecycle";
  if !invalid_reasons <> [ "invalid_scope" ] then
    failwith "invalid-scope finish hook count mismatch";
  if !invalid_attempts <> 0 then
    failwith "invalid-scope finish delivered a pending callback";
  let overflow = make_observer 8 in
  engine.next_token <- max_int;
  (match publish engine overflow 1 with
  | exception Counter_overflow "observer delivery token" -> ()
  | _ -> failwith "observer token overflow was not rejected");
  if overflow.current <> 0 || overflow.delivery <> Never_delivered then
    failwith "observer token overflow changed observer state";
  Printf.printf "observer protocol: pass\n%!"

let check_timer_protocol () =
  let engine = engine () in
  let starts = ref 0 in
  let stops = ref 0 in
  let fail_start = ref true in
  let fail_stop = ref false in
  let on_stop = ref (fun () -> ()) in
  let timer =
    make_timer 7 ~start:(fun _generation () ->
        incr starts;
        if !fail_start then (
          fail_start := false;
          raise (Injected_failure "start"));
        fun () ->
          if !fail_stop then (
            fail_stop := false;
            raise (Injected_failure "stop"));
          incr stops;
          (!on_stop) ())
  in
  let store = timer_store [ timer ] in
  set_timer_demand store timer true;
  expect_failure "start"
    (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  if not timer.queued then failwith "failed start was not retryable";
  if run_postcommit engine ~runtime:7 ~timers:store ~observers:[] <> []
  then failwith "timer start retry failed";
  let generation = timer.generation in
  if not (timer_wake engine 7 timer generation) then
    failwith "live timer wake did not admit source work";
  set_timer_demand store timer false;
  if timer_wake engine 7 timer generation then
    failwith "generation fence accepted a late wake";
  fail_stop := true;
  expect_failure "stop"
    (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  if not timer.queued then failwith "failed stop was not retryable";
  if run_postcommit engine ~runtime:7 ~timers:store ~observers:[] <> []
  then failwith "timer stop failed";
  set_timer_demand store timer true;
  ignore (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  on_stop := (fun () -> set_timer_demand store timer true);
  set_timer_demand store timer false;
  ignore (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  if not timer.queued then
    failwith "demand during stop did not queue a restart";
  on_stop := (fun () -> ());
  ignore (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  (match timer.state with
  | Running_timer _ when timer.demanded -> ()
  | Inactive | Running_timer _ ->
      failwith "demand during stop was lost");
  set_timer_demand store timer false;
  ignore (run_postcommit engine ~runtime:7 ~timers:store ~observers:[]);
  if !starts <> 4 || !stops <> 3 then failwith "timer lifecycle count mismatch";
  let foreign = make_timer 8 in
  let foreign_store = timer_store [ foreign ] in
  set_timer_demand foreign_store foreign true;
  (match
     run_postcommit engine ~runtime:7 ~timers:foreign_store ~observers:[]
   with
  | exception Runtime_mismatch -> ()
  | _ -> failwith "timer runtime mismatch was not rejected");
  if not foreign.queued then failwith "runtime mismatch lost retry work";
  ignore
    (run_postcommit engine ~runtime:8 ~timers:foreign_store ~observers:[]);
  (match timer_wake engine 7 foreign foreign.generation with
  | exception Runtime_mismatch -> ()
  | _ -> failwith "foreign timer wake was not rejected");
  let stop_overflow = make_timer 7 in
  stop_overflow.generation <- max_int;
  stop_overflow.demanded <- true;
  stop_overflow.state <- Running_timer (fun () -> ());
  let stop_overflow_store = timer_store [ stop_overflow ] in
  (match set_timer_demand stop_overflow_store stop_overflow false with
  | exception Counter_overflow "timer generation" -> ()
  | _ -> failwith "timer stop overflow was not rejected");
  if not stop_overflow.demanded || stop_overflow.queued then
    failwith "timer stop overflow changed demand state";
  let start_overflow = make_timer 7 in
  start_overflow.generation <- max_int;
  let start_overflow_store = timer_store [ start_overflow ] in
  set_timer_demand start_overflow_store start_overflow true;
  (match
     run_postcommit engine ~runtime:7 ~timers:start_overflow_store
       ~observers:[]
   with
  | exception Counter_overflow "timer generation" -> ()
  | _ -> failwith "timer start overflow was not rejected");
  if not start_overflow.queued || start_overflow.state <> Inactive then
    failwith "timer start overflow lost retry state";
  Printf.printf "timer protocol: pass\n%!"

let check_cleanup_aggregation () =
  let engine = engine () in
  let attempts = ref [] in
  engine.pending_hooks <-
    [
      (fun () ->
        attempts := 1 :: !attempts;
        raise (Injected_failure "one"));
      (fun () ->
        attempts := 2 :: !attempts;
        raise (Injected_failure "two"));
    ];
  let failures =
    run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[]
  in
  if List.rev !attempts <> [ 1; 2 ] then
    failwith "cleanup stopped after the first failure";
  if List.length failures <> 2 then
    failwith "cleanup failures were not aggregated";
  let observer_attempts = ref 0 in
  let observer =
    make_observer 1 ~callback:(fun _ _ _ -> incr observer_attempts)
  in
  publish engine observer 1;
  let timer =
    make_timer 1 ~start:(fun _generation () ->
        raise (Injected_failure "timer"))
  in
  let timers = timer_store [ timer ] in
  set_timer_demand timers timer true;
  let hook_attempts = ref 0 in
  engine.pending_hooks <-
    [
      (fun () ->
        incr hook_attempts;
        raise (Injected_failure "hook"));
      (fun () -> incr hook_attempts);
    ];
  (match
     run_postcommit engine ~runtime:1 ~timers ~observers:[ observer ]
   with
  | [ Injected_failure "timer"; Injected_failure "hook" ] -> ()
  | failures ->
      failf "combined cleanup returned %d failures" (List.length failures));
  if !hook_attempts <> 2 then
    failwith "combined cleanup skipped a hook";
  if !observer_attempts <> 0 then
    failwith "cleanup failure delivered an observer";
  (match observer.delivery with
  | Pending _ -> ()
  | _ -> failwith "cleanup failure lost pending observer delivery");
  if not timer.queued then failwith "cleanup failure lost timer retry";
  Printf.printf "cleanup aggregation: pass\n%!"

let check_stream_protocol () =
  let engine = engine () in
  let drop_calls = ref 0 in
  let bridge =
    stream_bridge 1 ~on_drop:(fun _ ->
        incr drop_calls;
        raise (Injected_failure "drop hook"))
  in
  let interrupt = ref false in
  let observer =
    make_observer 1 ~callback:(fun observer token update ->
        let capability =
          Delivery_capability.create_for_driver engine observer token
        in
        offer_stream bridge capability update
          ~interrupt_after_publish:!interrupt)
  in
  publish engine observer 1;
  if run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ observer ] <> []
  then failwith "stream send failed";
  publish engine observer 2;
  if run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ observer ] <> []
  then failwith "stream drop hook escaped delivery";
  if
    bridge.sent <> 1 || bridge.dropped <> 1 || bridge.acknowledged <> 2
    || bridge.logged_drop_failures <> 1 || !drop_calls <> 1
  then failwith "stream send/drop accounting mismatch";
  ignore (Queue.take bridge.queue : update);
  interrupt := true;
  publish engine observer 3;
  (match run_postcommit engine ~runtime:1 ~timers:no_timers ~observers:[ observer ] with
  | [ Cancelled ] -> ()
  | _ -> failwith "stream interruption did not escape");
  if bridge.sent <> 2 || bridge.acknowledged <> 3 then
    failwith "stream interruption split publication and acknowledgement";
  (match observer.delivery with
  | Delivered 3 -> ()
  | _ -> failwith "stream interruption restored acknowledged delivery");
  Printf.printf "stream protocol: pass\n%!"

let check_affected_work () =
  List.iter
    (fun mismatches ->
      let engine = engine () in
      let timers = List.init mismatches (fun _ -> make_timer 1) in
      let ballast = List.init 100_000 (fun _ -> make_timer 1) in
      let store = timer_store (timers @ ballast) in
      List.iter (fun timer -> set_timer_demand store timer true) timers;
      ignore
        (run_postcommit engine ~runtime:1 ~timers:store ~observers:[]);
      if List.length store.registry <> mismatches + 100_000 then
        failwith "timer registry did not contain its ballast";
      if engine.counts.cleanup_claims <> mismatches then
        failf "%d mismatches produced %d claims" mismatches
          engine.counts.cleanup_claims;
      if store.queued <> [] then
        failwith "timer reconciliation retained queued work")
    [ 1; 32; 1_024 ];
  Printf.printf "affected-work checks: pass\n%!"

type workload = {
  name : string;
  run : int -> unit;
  check : unit -> unit;
}

let make_workload name =
  let engine = engine () in
  let completed = ref 0 in
  match name with
  | "observer_success" ->
      let observer = make_observer 1 in
      {
        name;
        run =
          (fun operations ->
            for _ = 1 to operations do
              incr completed;
              publish engine observer !completed;
              ignore
                (run_postcommit engine ~runtime:1 ~timers:no_timers
                   ~observers:[ observer ])
            done);
        check =
          (fun () ->
            match observer.delivery with
            | Delivered value when value = !completed -> ()
            | _ -> failwith "observer benchmark state mismatch");
      }
  | "observer_failure_retry" ->
      let fail_next = ref true in
      let observer =
        make_observer 1 ~callback:(fun _ _ _ ->
            if !fail_next then (
              fail_next := false;
              raise (Injected_failure "bench")))
      in
      {
        name;
        run =
          (fun operations ->
            for _ = 1 to operations do
              incr completed;
              fail_next := true;
              publish engine observer !completed;
              ignore
                (run_postcommit engine ~runtime:1 ~timers:no_timers
                   ~observers:[ observer ]);
              ignore
                (run_postcommit engine ~runtime:1 ~timers:no_timers
                   ~observers:[ observer ])
            done);
        check =
          (fun () ->
            match observer.delivery with
            | Delivered value when value = !completed -> ()
            | _ -> failwith "observer retry benchmark state mismatch");
      }
  | "observer_disposal" ->
      {
        name;
        run =
          (fun operations ->
            for id = 1 to operations do
              let observer = make_observer id in
              publish engine observer id;
              finish_observer engine observer "disposed";
              ignore
                (run_postcommit engine ~runtime:1 ~timers:no_timers
                   ~observers:[ observer ]);
              if observer.lifecycle <> Disposed || observer.finish_count <> 1
              then failwith "observer disposal benchmark state mismatch";
              incr completed
            done);
        check = (fun () -> ());
      }
  | "timer_cycle" ->
      let timer = make_timer 1 in
      let timers = timer_store [ timer ] in
      {
        name;
        run =
          (fun operations ->
            for _ = 1 to operations do
              set_timer_demand timers timer true;
              ignore
                (run_postcommit engine ~runtime:1 ~timers
                   ~observers:[]);
              let generation = timer.generation in
              ignore (timer_wake engine 1 timer generation);
              set_timer_demand timers timer false;
              ignore
                (run_postcommit engine ~runtime:1 ~timers
                   ~observers:[]);
              incr completed
            done);
        check =
          (fun () ->
            match timer.state with
            | Inactive when timer.source_work = !completed -> ()
            | Inactive | Running_timer _ ->
                failwith "timer benchmark state mismatch");
      }
  | "stream_offer" ->
      let bridge = stream_bridge 1 in
      let observer =
        make_observer 1 ~callback:(fun observer token update ->
            if Queue.length bridge.queue = bridge.capacity then
              ignore (Queue.take bridge.queue : update);
            let capability =
              Delivery_capability.create_for_driver engine observer token
            in
            offer_stream bridge capability update
              ~interrupt_after_publish:false)
      in
      {
        name;
        run =
          (fun operations ->
            for _ = 1 to operations do
              incr completed;
              publish engine observer !completed;
              ignore
                (run_postcommit engine ~runtime:1 ~timers:no_timers
                   ~observers:[ observer ])
            done);
        check =
          (fun () ->
            if bridge.acknowledged <> !completed then
              failwith "stream benchmark acknowledgement mismatch");
      }
  | _ -> invalid_arg ("unknown workload: " ^ name)

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

let check () =
  check_observer_protocol ();
  check_timer_protocol ();
  check_cleanup_aggregation ();
  check_stream_protocol ();
  check_affected_work ()

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--check" ] -> check ()
  | [ "--measure"; name; "--samples"; samples ] ->
      measure (make_workload name) (int_of_string samples)
  | _ ->
      invalid_arg
        "use --check or --measure WORKLOAD --samples COUNT"
