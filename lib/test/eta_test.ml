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

  let sleeper_compare a b =
    match Int.compare a.deadline_ms b.deadline_ms with
    | 0 -> Int.compare a.sequence b.sequence
    | order -> order

  let rec insert_sleeper sleeper = function
    | [] -> [ sleeper ]
    | next :: rest as sleepers ->
        if sleeper_compare sleeper next <= 0 then sleeper :: sleepers
        else next :: insert_sleeper sleeper rest

  let take_next_due t target_ms =
    match t.sleepers with
    | [] -> None
    | sleeper :: rest when sleeper.deadline_ms <= target_ms ->
        t.sleepers <- rest;
        Some sleeper
    | _ -> None

  let rec wake_until t target_ms =
    match take_next_due t target_ms with
    | None -> t.now_ms <- target_ms
    | Some sleeper ->
        t.now_ms <- sleeper.deadline_ms;
        Eio.Promise.resolve sleeper.resolver ();
        Eio.Fiber.yield ();
        wake_until t target_ms

  let sleep t duration =
    let deadline_ms = t.now_ms + Eta.Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      let sequence = t.next_sequence in
      t.next_sequence <- t.next_sequence + 1;
      t.sleepers <-
        insert_sleeper { deadline_ms; sequence; resolver } t.sleepers;
      try Eio.Promise.await promise
      with exn ->
        t.sleepers <-
          List.filter (fun sleeper -> sleeper.sequence <> sequence) t.sleepers;
        raise exn

  let adjust t duration =
    wake_until t (t.now_ms + Eta.Duration.to_ms duration)

  let set_time t time_ms =
    wake_until t (max 0 time_ms)

  let now_ms t = t.now_ms

  let as_capability t : Eta.Capabilities.clock =
    object
      method now_ms () = now_ms t
      method sleep duration = sleep t duration
    end

  let sleeper_count t = List.length t.sleepers

  let next_sleep_duration t =
    match t.sleepers with
    | [] -> None
    | sleeper :: _ -> Some (Eta.Duration.ms (sleeper.deadline_ms - t.now_ms))

end

module Fiber_accounting = struct
  type kind = Structured | Daemon

  type info = {
    id : int;
    parent_id : int option;
    kind : kind;
  }

  type t = {
    mutable next_id : int;
    mutable pending_rev : info list;
    mutable activity : int;
    mutable scheduler_active : int;
  }

  let fiber_id = Eta.Runtime_contract.create_local ()
  let daemon_subtree = Eta.Runtime_contract.create_local ()
  let create () =
    { next_id = 1; pending_rev = []; activity = 0; scheduler_active = 0 }
  let pending t = List.rev t.pending_rev
  let activity t = t.activity
  let scheduler_active t = t.scheduler_active

  let start t local_get kind =
    let id = t.next_id in
    t.next_id <- id + 1;
    let info = { id; parent_id = local_get fiber_id; kind } in
    t.pending_rev <- info :: t.pending_rev;
    info

  let finish t id =
    t.pending_rev <- List.filter (fun fiber -> fiber.id <> id) t.pending_rev

  let scheduler_start t daemon_owned =
    if not daemon_owned then (
      t.scheduler_active <- t.scheduler_active + 1;
      t.activity <- t.activity + 1)

  let scheduler_finish t daemon_owned =
    if not daemon_owned then (
      t.scheduler_active <- t.scheduler_active - 1;
      t.activity <- t.activity + 1)

  let note_yield t daemon_owned =
    if not daemon_owned then
    t.activity <- t.activity + 1

  let wrap ?(record_fibers = true) t backend =
    let module Base = (val backend : Eta.Runtime_contract.RUNTIME) in
    (module struct
      type scope = Base.scope
      type cancel_context = Base.cancel_context
      type 'a promise = 'a Base.promise
      type 'a resolver = 'a Base.resolver
      type 'a stream = 'a Base.stream

      let root_scope = Base.root_scope
      let now_ms = Base.now_ms
      let fresh = Base.fresh
      let sleep = Base.sleep
      let protect = Base.protect
      let run_scope = Base.run_scope
      let fail_scope = Base.fail_scope

      let fork scope f =
        let daemon_owned =
          Option.value (Base.local_get daemon_subtree) ~default:false
        in
        let info =
          if record_fibers then Some (start t Base.local_get Structured) else None
        in
        scheduler_start t daemon_owned;
        let finish () =
          Option.iter (fun info -> finish t info.id) info;
          scheduler_finish t daemon_owned
        in
        try
          Base.fork scope (fun () ->
              let run () = Fun.protect ~finally:finish f in
              match info with
              | None -> run ()
              | Some info -> Base.local_with_binding fiber_id info.id run)
        with exn ->
          finish ();
          raise exn

      let fork_daemon scope f =
        let info =
          if record_fibers then Some (start t Base.local_get Daemon) else None
        in
        let finish () = Option.iter (fun info -> finish t info.id) info in
        try
          Base.fork_daemon scope (fun () ->
              Base.local_with_binding daemon_subtree true (fun () ->
                  let run () = Fun.protect ~finally:finish f in
                  match info with
                  | None -> run ()
                  | Some info -> Base.local_with_binding fiber_id info.id run))
        with exn ->
          finish ();
          raise exn

      let await_cancel = Base.await_cancel
      let yield () =
        note_yield t
          (Option.value (Base.local_get daemon_subtree) ~default:false);
        Base.yield ()
      let check = Base.check
      let create_promise = Base.create_promise
      let resolve_promise = Base.resolve_promise
      let await_promise = Base.await_promise
      let create_stream = Base.create_stream
      let stream_add = Base.stream_add
      let stream_take = Base.stream_take
      let stream_take_nonblocking = Base.stream_take_nonblocking
      let with_worker_context = Base.with_worker_context
      let in_worker_context = Base.in_worker_context
      let cancellation_reason = Base.cancellation_reason
      let multiple_exceptions = Base.multiple_exceptions
      let cancel_sub = Base.cancel_sub
      let cancel = Base.cancel
      let local_get = Base.local_get
      let local_with_binding = Base.local_with_binding
      let current_fiber_id = Base.current_fiber_id
      let with_fiber_identity = Base.with_fiber_identity
    end : Eta.Runtime_contract.RUNTIME)
end

let create_accounted_runtime ~sw ~eio_clock ~clock ?logger ?tracer () =
  let accounting = Fiber_accounting.create () in
  let backend =
    Eta_eio.runtime ~sw ~clock:eio_clock |> Fiber_accounting.wrap accounting
  in
  Eta.Runtime.create_with_runtime backend ~sleep:(Test_clock.sleep clock)
    ~now_ms:(fun () -> Test_clock.now_ms clock) ?logger ?tracer
    ~services:
      [
        Eta_blocking.runtime_service ~runner:Eta_eio.default_blocking_runner ();
      ]
    ()

let with_logger f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let logger = Eta.Logger.in_memory () in
  let rt =
    create_accounted_runtime ~sw ~eio_clock:(Eio.Stdenv.clock stdenv) ~clock
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  f sw rt logger

let with_tracer f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_accounted_runtime ~sw ~eio_clock:(Eio.Stdenv.clock stdenv) ~clock
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw rt tracer

let with_logger_and_tracer f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let logger = Eta.Logger.in_memory () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_accounted_runtime ~sw ~eio_clock:(Eio.Stdenv.clock stdenv) ~clock
      ~logger:(Eta.Logger.as_capability logger)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw rt logger tracer

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    create_accounted_runtime ~sw ~eio_clock:(Eio.Stdenv.clock stdenv) ~clock ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    create_accounted_runtime ~sw ~eio_clock:(Eio.Stdenv.clock stdenv) ~clock
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw clock rt tracer

module Async = struct
  type 'a promise = 'a Eio.Promise.t

  let fork_run sw rt eff =
    let promise, resolver = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolver (Eta.Runtime.run rt eff));
    promise

  let await = Eio.Promise.await

  let unresolved () =
    let promise, _resolver = Eio.Promise.create () in
    promise

  let yield = Eio.Fiber.yield
end

module Expect = struct
  let pp_hidden_error fmt _ = Format.pp_print_string fmt "<err>"

  let expect_ok = function
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Ok, got Error %a"
          (Eta.Cause.pp pp_hidden_error) cause

  let expect_typed_failure exit predicate =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Fail err) when predicate err -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected matching typed failure, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected matching typed failure, got Ok"

  let expect_typed_failure_eq test exit expected =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Fail actual) ->
        Alcotest.check test "typed failure" expected actual
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected typed failure, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected typed failure, got Ok"

  let expect_die exit predicate =
    match exit with
    | Eta.Exit.Error (Eta.Cause.Die die) when predicate die -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected matching Die, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected matching Die, got Ok"

  let expect_interrupt = function
    | Eta.Exit.Error (Eta.Cause.Interrupt _) -> ()
    | Eta.Exit.Error cause ->
        Alcotest.failf "expected Interrupt, got %a"
          (Eta.Cause.pp pp_hidden_error) cause
    | Eta.Exit.Ok _ -> Alcotest.fail "expected Interrupt, got Ok"
end

module Test_random = struct
  let create ~seed = Eta.Capabilities.random_of_seed seed
  let set_seed = Eta.Capabilities.random_set_seed
end

module Run = struct
  type fiber_kind = Fiber_accounting.kind = Structured | Daemon

  type fiber_info = Fiber_accounting.info = {
    id : int;
    parent_id : int option;
    kind : fiber_kind;
  }

  type event =
    | Sleep of Eta.Duration.t
    | Log of Eta.Logger.record
    | Span of Eta.Tracer.span
    | Metric of Eta.Meter.point

  type ('a, 'err) outcome = {
    exit : ('a, 'err) Eta.Exit.t;
    logs : Eta.Logger.record list;
    spans : Eta.Tracer.span list;
    metrics : Eta.Meter.point list;
    sleeps : Eta.Duration.t list;
    events : event list;
    pending_fibers : fiber_info list;
  }

  let settle_deadline accounting clock result =
    let rec loop stable activity sleepers =
      Eio.Fiber.yield ();
      if not (Eio.Promise.is_resolved result) then
        let next_activity = Fiber_accounting.activity accounting in
        let next_sleepers = Test_clock.sleeper_count clock in
        if next_activity <> activity || next_sleepers <> sleepers then
          loop 0 next_activity next_sleepers
        else
          let required_stable_turns =
            (* After the last observed child activity, allow the scope
               coordinator and root-result publisher to run as well. *)
            Fiber_accounting.scheduler_active accounting + 3
          in
          if stable < required_stable_turns then
            loop (stable + 1) next_activity next_sleepers
    in
    loop 0 (Fiber_accounting.activity accounting)
      (Test_clock.sleeper_count clock)

  let rec drive accounting clock result =
    if Eio.Promise.is_resolved result then ()
    else
      match Test_clock.next_sleep_duration clock with
      | Some duration ->
          Test_clock.adjust clock duration;
          (* Let work made runnable at this deadline settle (and cancel losing
             sleepers) before selecting the next virtual timer. *)
          settle_deadline accounting clock result;
          drive accounting clock result
      | None ->
          Eio.Fiber.yield ();
          drive accounting clock result

  let run ?clock ?(seed = 0) ?(account_fibers = true) eff =
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let clock = Option.value clock ~default:(Test_clock.create ()) in
    let logger = Eta.Logger.in_memory () in
    let tracer = Eta.Tracer.in_memory () in
    let meter = Eta.Meter.in_memory () in
    let random = Eta.Capabilities.random_of_seed seed in
    let events_rev = ref [] in
    let record event = events_rev := event :: !events_rev in
    let logger_capability = Eta.Logger.as_capability logger in
    let logger_capability : Eta.Capabilities.logger =
      object
        method log log_record =
          logger_capability#log log_record;
          record (Log log_record)
      end
    in
    let meter_capability = Eta.Meter.as_capability meter in
    let meter_capability : Eta.Capabilities.meter =
      object
        method record point =
          meter_capability#record point;
          record (Metric point)
      end
    in
    let tracer_capability = Eta.Tracer.as_capability tracer in
    let tracer_capability : Eta.Capabilities.tracer =
      object
        method with_task_context : 'a. Eta.Runtime_contract.t -> (unit -> 'a) -> 'a =
          fun contract f -> tracer_capability#with_task_context contract f

        method begin_span contract ?parent_id ?external_parent ?trace_id
            ?trace_flags ?trace_state ?baggage ?kind ~name ~started_ms () =
          tracer_capability#begin_span contract ?parent_id ?external_parent
            ?trace_id ?trace_flags ?trace_state ?baggage ?kind ~name ~started_ms
            ()

        method end_span contract ~span_id ~status ~ended_ms =
          tracer_capability#end_span contract ~span_id ~status ~ended_ms;
          match
            List.find_opt
              (fun span -> span.Eta.Tracer.span_id = span_id)
              (Eta.Tracer.dump tracer)
          with
          | Some span -> record (Span span)
          | None -> invalid_arg "Eta_test.Run: ended span missing from test tracer"

        method add_attr contract ~key ~value =
          tracer_capability#add_attr contract ~key ~value

        method add_attr_to contract ~span_id ~key ~value =
          tracer_capability#add_attr_to contract ~span_id ~key ~value

        method add_event contract ~span_id ~name ~ts_ms ~attrs =
          tracer_capability#add_event contract ~span_id ~name ~ts_ms ~attrs

        method add_link contract link = tracer_capability#add_link contract link

        method add_link_to contract ~span_id link =
          tracer_capability#add_link_to contract ~span_id link

        method inspect contract ~span_id =
          tracer_capability#inspect contract ~span_id
      end
    in
    let clock_capability : Eta.Capabilities.clock =
      object
        method now_ms () = Test_clock.now_ms clock

        method sleep duration =
          if Eta.Duration.to_ms duration > 0 then record (Sleep duration);
          Test_clock.sleep clock duration
      end
    in
    let accounting = Fiber_accounting.create () in
    let backend =
      Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock stdenv)
      |> Fiber_accounting.wrap ~record_fibers:account_fibers accounting
    in
    let runtime =
      Eta.Runtime.create_with_runtime backend
        ~meter:meter_capability
        ~services:
          [
            Eta_blocking.runtime_service ~runner:Eta_eio.default_blocking_runner
              ();
          ]
        ~capture_backtrace:false ()
    in
    let program =
      eff
      |> Eta.Effect.with_tracer tracer_capability
      |> Eta.Effect.with_logger logger_capability
      |> Eta.Effect.with_random random
      |> Eta.Effect.with_clock clock_capability
    in
    let result, resolve = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve (Eta.Runtime.run runtime program));
    drive accounting clock result;
    let exit = Eio.Promise.await result in
    let events = List.rev !events_rev in
    {
      exit;
      logs = Eta.Logger.dump logger;
      spans = Eta.Tracer.dump tracer;
      metrics = Eta.Meter.dump meter;
      sleeps =
        List.filter_map
          (function Sleep duration -> Some duration | _ -> None)
          events;
      events;
      pending_fibers = Fiber_accounting.pending accounting;
    }

  let expect_no_pending_fibers outcome =
    match outcome.pending_fibers with
    | [] -> ()
    | fibers ->
        let pp_kind fmt = function
          | Structured -> Format.pp_print_string fmt "structured"
          | Daemon -> Format.pp_print_string fmt "daemon (runtime-owned)"
        in
        let pp_fiber fmt fiber =
          Format.fprintf fmt "#%d parent=%a %a" fiber.id
            (Format.pp_print_option Format.pp_print_int)
            fiber.parent_id pp_kind fiber.kind
        in
        Alcotest.failf "expected no pending fibers, got %a"
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ", ")
             pp_fiber)
          fibers

  let expect_sleeps expected outcome =
    Alcotest.check
      (Alcotest.list (Alcotest.testable Eta.Duration.pp Eta.Duration.equal))
      "virtual sleeps" expected outcome.sleeps

  let pp_attrs fmt attrs =
    let pp_attr fmt (key, value) = Format.fprintf fmt "%s=%S" key value in
    Format.pp_print_list
      ~pp_sep:(fun fmt () -> Format.pp_print_string fmt " ")
      pp_attr fmt attrs

  let pp_level fmt = function
    | Eta.Capabilities.Trace -> Format.pp_print_string fmt "TRACE"
    | Debug -> Format.pp_print_string fmt "DEBUG"
    | Info -> Format.pp_print_string fmt "INFO"
    | Warn -> Format.pp_print_string fmt "WARN"
    | Error -> Format.pp_print_string fmt "ERROR"
    | Fatal -> Format.pp_print_string fmt "FATAL"

  let pp_log fmt record =
    Format.fprintf fmt "t=%d %a %S attrs={%a} trace=%S span=%S"
      record.Eta.Logger.ts_ms pp_level record.level record.body pp_attrs
      record.attrs record.trace_id record.span_id

  let pp_span_status fmt = function
    | Eta.Tracer.Ok -> Format.pp_print_string fmt "ok"
    | Error message -> Format.fprintf fmt "error(%S)" message
    | Cancelled -> Format.pp_print_string fmt "cancelled"

  let pp_span_kind fmt = function
    | Eta.Capabilities.Internal -> Format.pp_print_string fmt "internal"
    | Server -> Format.pp_print_string fmt "server"
    | Client -> Format.pp_print_string fmt "client"
    | Producer -> Format.pp_print_string fmt "producer"
    | Consumer -> Format.pp_print_string fmt "consumer"

  let pp_trace_context fmt (context : Eta.Capabilities.trace_context) =
    Format.fprintf fmt "trace=%S span=%S flags=%d state={%a} baggage={%a}"
      context.Eta.Capabilities.trace_id context.span_id context.trace_flags
      pp_attrs context.trace_state pp_attrs context.baggage

  let pp_span_event fmt event =
    Format.fprintf fmt "(%d,%S,{%a})" event.Eta.Tracer.ev_ts_ms event.ev_name
      pp_attrs event.ev_attrs

  let pp_span_link fmt link =
    Format.fprintf fmt "(%S,%S,{%a})" link.Eta.Tracer.link_trace_id
      link.link_span_id pp_attrs link.link_attrs

  let pp_span fmt span =
    Format.fprintf fmt
      "id=%d parent=%a t=%d..%d name=%S kind=%a status=%a attrs={%a} \
       events=[%a] links=[%a] trace=%S flags=%d state={%a} baggage={%a} \
       external_parent=%a"
      span.Eta.Tracer.span_id (Format.pp_print_option Format.pp_print_int)
      span.parent_id span.started_ms span.ended_ms span.name pp_span_kind span.kind
      pp_span_status span.status pp_attrs span.attrs
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
         pp_span_event)
      span.events
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.pp_print_string fmt "; ")
         pp_span_link)
      span.links span.trace_id span.trace_flags pp_attrs span.trace_state pp_attrs
      span.baggage (Format.pp_print_option pp_trace_context) span.external_parent

  let pp_metric_value fmt = function
    | Eta.Capabilities.Number (Int value) -> Format.pp_print_int fmt value
    | Number (Float value) -> Format.pp_print_float fmt value
    | Category value -> Format.fprintf fmt "%S" value

  let pp_float_list fmt values =
    Format.pp_print_list
      ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ",")
      Format.pp_print_float fmt values

  let pp_metric_kind fmt = function
    | Eta.Capabilities.Counter { monotonic } ->
        Format.fprintf fmt "counter(monotonic=%b)" monotonic
    | Gauge -> Format.pp_print_string fmt "gauge"
    | Frequency -> Format.pp_print_string fmt "frequency"
    | Histogram { boundaries } ->
        Format.fprintf fmt "histogram([%a])" pp_float_list boundaries
    | Summary { quantiles; max_age; max_size } ->
        Format.fprintf fmt "summary(q=[%a],max_age=%a,max_size=%d)" pp_float_list
          quantiles Eta.Duration.pp max_age max_size

  let pp_metric fmt point =
    Format.fprintf fmt
      "t=%d name=%S description=%S unit=%S kind=%a attrs={%a} value=%a"
      point.Eta.Meter.ts_ms point.name point.description point.unit_ pp_metric_kind
      point.kind pp_attrs point.attrs pp_metric_value point.value

  let pp_event fmt = function
    | Sleep duration -> Format.fprintf fmt "sleep %a" Eta.Duration.pp duration
    | Log record -> Format.fprintf fmt "log %a" pp_log record
    | Span span -> Format.fprintf fmt "span %a" pp_span span
    | Metric point -> Format.fprintf fmt "metric %a" pp_metric point

  let pp_fiber_kind fmt = function
    | Structured -> Format.pp_print_string fmt "structured"
    | Daemon -> Format.pp_print_string fmt "daemon(runtime-owned)"

  let pp_parent fmt = function
    | None -> Format.pp_print_string fmt "root"
    | Some id -> Format.pp_print_int fmt id

  let pp_fiber fmt fiber =
    Format.fprintf fmt "#%d parent=%a kind=%a" fiber.id pp_parent fiber.parent_id
      pp_fiber_kind fiber.kind

  let pp_indexed pp_item fmt items =
    match items with
    | [] -> Format.pp_print_string fmt "none"
    | _ ->
        List.iteri
          (fun index item -> Format.fprintf fmt "@,  [%d] %a" index pp_item item)
          items

  let pp pp_ok pp_err fmt outcome =
    Format.fprintf fmt
      "@[<v>execution outcome@,exit: %a@,ordered events:%a@,snapshots:@, \
       sleeps:%a@, logs:%a@, spans:%a@, metrics:%a@, finalizers: unavailable \
       (failures remain in exit)@,pending fibers:%a@]"
      (Eta.Exit.pp pp_ok pp_err) outcome.exit
      (pp_indexed pp_event) outcome.events
      (pp_indexed Eta.Duration.pp) outcome.sleeps
      (pp_indexed pp_log) outcome.logs (pp_indexed pp_span) outcome.spans
      (pp_indexed pp_metric) outcome.metrics (pp_indexed pp_fiber)
      outcome.pending_fibers

  let equal ok_test err_test left right =
    (match (left.exit, right.exit) with
    | Eta.Exit.Ok left, Eta.Exit.Ok right -> Alcotest.equal ok_test left right
    | Eta.Exit.Error left, Eta.Exit.Error right ->
        Eta.Cause.diagnostic_equal (Alcotest.equal err_test) left right
    | _ -> false)
    && left.logs = right.logs
    && left.spans = right.spans
    && left.metrics = right.metrics
    && List.equal Eta.Duration.equal left.sleeps right.sleeps
    && left.events = right.events
    && left.pending_fibers = right.pending_fibers

  let testable ok_test err_test =
    Alcotest.testable
      (pp (Alcotest.pp ok_test) (Alcotest.pp err_test))
      (equal ok_test err_test)
end

let fail_audit assertion eff =
  Alcotest.failf "%s failed for static blueprint:\n%s" assertion
    (Eta.Effect.describe eff)

let assert_no_clock eff =
  if (Eta.Effect.audit eff).uses_clock then fail_audit "assert_no_clock" eff

let assert_no_logs eff =
  if (Eta.Effect.audit eff).emits_logs then fail_audit "assert_no_logs" eff

let assert_no_metrics eff =
  if (Eta.Effect.audit eff).emits_metrics then fail_audit "assert_no_metrics" eff

let assert_no_concurrency eff =
  if (Eta.Effect.audit eff).has_concurrency then
    fail_audit "assert_no_concurrency" eff

let assert_no_resources eff =
  if (Eta.Effect.audit eff).has_resources then
    fail_audit "assert_no_resources" eff

let assert_no_background eff =
  if (Eta.Effect.audit eff).has_background then
    fail_audit "assert_no_background" eff

let assert_pure_eff eff =
  let audit = Eta.Effect.audit eff in
  if
    audit.uses_clock || audit.emits_logs || audit.emits_metrics
    || audit.has_concurrency || audit.has_resources || audit.has_background
  then fail_audit "assert_pure_eff" eff
