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
    mutable observed_sleeps_rev : Eta.Duration.t list;
  }

  let create () =
    { now_ms = 0; next_sequence = 0; sleepers = []; observed_sleeps_rev = [] }

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
      let () = t.observed_sleeps_rev <- duration :: t.observed_sleeps_rev in
      let promise, resolver = Eio.Promise.create () in
      let sequence = t.next_sequence in
      t.next_sequence <- t.next_sequence + 1;
      t.sleepers <-
        insert_sleeper { deadline_ms; sequence; resolver } t.sleepers;
      Eio.Promise.await promise

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

  let observed_sleeps t = List.rev t.observed_sleeps_rev
end

let with_logger f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let logger = Eta.Logger.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~now_ms:(fun () -> Test_clock.now_ms clock)
      ~logger:(Eta.Logger.as_capability logger) ()
  in
  f sw rt logger

let with_tracer f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~now_ms:(fun () -> Test_clock.now_ms clock)
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
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~now_ms:(fun () -> Test_clock.now_ms clock)
      ~logger:(Eta.Logger.as_capability logger)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f sw rt logger tracer

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~now_ms:(fun () -> Test_clock.now_ms clock)
      ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock)
      ~now_ms:(fun () -> Test_clock.now_ms clock)
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
  type fiber_kind = Structured | Daemon

  type fiber_info = {
    id : int;
    parent_id : int option;
    kind : fiber_kind;
  }

  type ('a, 'err) outcome = {
    exit : ('a, 'err) Eta.Exit.t;
    logs : Eta.Logger.record list;
    spans : Eta.Tracer.span list;
    metrics : Eta.Meter.point list;
    sleeps : Eta.Duration.t list;
    pending_fibers : fiber_info list;
  }

  type accounting = {
    mutable next_id : int;
    mutable pending_rev : fiber_info list;
  }

  let accounting_fiber_id = Eta.Runtime_contract.create_local ()

  let start_fiber accounting local_get kind =
    let id = accounting.next_id in
    accounting.next_id <- id + 1;
    let parent_id = local_get accounting_fiber_id in
    let info = { id; parent_id; kind } in
    accounting.pending_rev <- info :: accounting.pending_rev;
    info

  let finish_fiber accounting id =
    accounting.pending_rev <-
      List.filter (fun fiber -> fiber.id <> id) accounting.pending_rev

  let accounting_runtime accounting backend =
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
        let info = start_fiber accounting Base.local_get Structured in
        try
          Base.fork scope (fun () ->
              Base.local_with_binding accounting_fiber_id info.id (fun () ->
                  Fun.protect
                    ~finally:(fun () -> finish_fiber accounting info.id)
                    f))
        with exn ->
          finish_fiber accounting info.id;
          raise exn

      let fork_daemon scope f =
        let info = start_fiber accounting Base.local_get Daemon in
        try
          Base.fork_daemon scope (fun () ->
              Base.local_with_binding accounting_fiber_id info.id (fun () ->
                  Fun.protect
                    ~finally:(fun () -> finish_fiber accounting info.id)
                    f))
        with exn ->
          finish_fiber accounting info.id;
          raise exn

      let await_cancel = Base.await_cancel
      let yield = Base.yield
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

  let rec drive clock result =
    if Eio.Promise.is_resolved result then ()
    else
      match Test_clock.next_sleep_duration clock with
      | Some duration ->
          Test_clock.adjust clock duration;
          drive clock result
      | None ->
          Eio.Fiber.yield ();
          drive clock result

  let run ?clock ?(seed = 0) eff =
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let clock = Option.value clock ~default:(Test_clock.create ()) in
    let logger = Eta.Logger.in_memory () in
    let tracer = Eta.Tracer.in_memory () in
    let meter = Eta.Meter.in_memory () in
    let random = Eta.Capabilities.random_of_seed seed in
    let accounting = { next_id = 1; pending_rev = [] } in
    let backend =
      Eta_eio.runtime ~sw ~clock:(Eio.Stdenv.clock stdenv)
      |> accounting_runtime accounting
    in
    let runtime =
      Eta.Runtime.create_with_runtime backend
        ~meter:(Eta.Meter.as_capability meter) ~capture_backtrace:false ()
    in
    let program =
      eff
      |> Eta.Effect.with_tracer (Eta.Tracer.as_capability tracer)
      |> Eta.Effect.with_logger (Eta.Logger.as_capability logger)
      |> Eta.Effect.with_random random
      |> Eta.Effect.with_clock (Test_clock.as_capability clock)
    in
    let result, resolve = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve (Eta.Runtime.run runtime program));
    drive clock result;
    let exit = Eio.Promise.await result in
    {
      exit;
      logs = Eta.Logger.dump logger;
      spans = Eta.Tracer.dump tracer;
      metrics = Eta.Meter.dump meter;
      sleeps = Test_clock.observed_sleeps clock;
      pending_fibers = List.rev accounting.pending_rev;
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
