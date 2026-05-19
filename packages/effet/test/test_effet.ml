open Effet

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_ok test name expected = function
  | Exit.Ok actual -> Alcotest.check test name expected actual
  | Exit.Error _ -> Alcotest.fail "expected Ok"

let check_exit_error test name expected = function
  | Exit.Ok _ -> Alcotest.fail "expected Error"
  | Exit.Error cause -> Alcotest.check test name expected cause

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~env:() ()
  in
  f rt tracer

let with_sampled_traced_runtime sampler f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~sampler ~env:() ()
  in
  f rt tracer

let with_auto_traced_runtime auto_instrument f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ~auto_instrument ~env:() ()
  in
  f rt tracer

module Test_clock = struct
  type sleeper = { deadline_ms : int; resolver : unit Eio.Promise.u }
  type t = { mutable now_ms : int; mutable sleepers : sleeper list }

  let create () = { now_ms = 0; sleepers = [] }

  let wake_due t =
    let due, pending =
      List.partition (fun sleeper -> sleeper.deadline_ms <= t.now_ms) t.sleepers
    in
    t.sleepers <- pending;
    List.iter
      (fun sleeper -> Eio.Promise.resolve sleeper.resolver ())
      due

  let sleep t duration =
    let deadline_ms = t.now_ms + Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      t.sleepers <- { deadline_ms; resolver } :: t.sleepers;
      Eio.Promise.await promise

  let adjust t duration =
    t.now_ms <- t.now_ms + Duration.to_ms duration;
    wake_due t

  let set_time t time_ms =
    t.now_ms <- max 0 time_ms;
    wake_due t

  let sleeper_count t = List.length t.sleepers
end

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~env:() ()
  in
  f sw clock rt

let with_traced_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~tracer:(Tracer.as_capability tracer)
      ~env:() ()
  in
  f sw clock rt tracer

let fork_run sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolver (Runtime.run rt eff));
  promise

let dur_ms = Duration.ms
let some_dur = Alcotest.option (Alcotest.testable Duration.pp Duration.equal)
let dur = Alcotest.testable Duration.pp Duration.equal
let string_cause =
  Alcotest.testable (Cause.pp Format.pp_print_string) (Cause.equal String.equal)

let attr key span = List.assoc_opt key span.Tracer.attrs

let link_span_id span =
  List.map (fun link -> link.Tracer.link_span_id) span.Tracer.links

let only_span tracer =
  match Tracer.dump tracer with
  | [ span ] -> span
  | spans ->
      Alcotest.failf "expected one span, got %d" (List.length spans)

let check_status name expected actual =
  match (expected, actual) with
  | Tracer.Ok, Tracer.Ok -> ()
  | Tracer.Cancelled, Tracer.Cancelled -> ()
  | Tracer.Error _, Tracer.Error _ -> ()
  | _ -> Alcotest.failf "%s: unexpected span status" name

let test_pure () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "pure" 42 (run_ok rt (Effect.pure 42))

let test_map () =
  with_runtime @@ fun rt ->
  let e = Effect.pure 1 |> Effect.map (fun n -> n + 1) in
  Alcotest.(check int) "map" 2 (run_ok rt e)

let test_collect_names () =
  let e =
    Effect.concat
      [
        Effect.sync "leaf-a" (fun _ -> ()) |> Effect.map (fun _ -> ());
        Effect.async "leaf-b" (fun _ -> ());
      ]
    |> Effect.named "outer"
  in
  Alcotest.(check (list string))
    "names in pre-order"
    [ "outer"; "leaf-a"; "leaf-b" ]
    (Effect.collect_names e)

let test_tracer_manual_spans () =
  let tracer = Tracer.in_memory () in
  let t = Tracer.as_capability tracer in
  t#add_attr ~key:"pending" ~value:"yes";
  let parent = t#begin_span ~name:"parent" ~started_ms:1 () in
  t#add_attr ~key:"inside" ~value:"parent";
  let child = t#begin_span ~name:"child" ~started_ms:2 () in
  t#end_span ~span_id:child ~status:Tracer.Ok ~ended_ms:3;
  t#end_span ~span_id:parent ~status:(Tracer.Error "boom") ~ended_ms:4;
  match Tracer.dump tracer with
  | [ child_span; parent_span ] ->
      Alcotest.(check int) "child parent" parent
        (Option.get child_span.Tracer.parent_id);
      Alcotest.(check (option string)) "pending attr" (Some "yes")
        (attr "pending" parent_span);
      Alcotest.(check (option string)) "inside attr" (Some "parent")
        (attr "inside" parent_span);
      check_status "child" Tracer.Ok child_span.status;
      check_status "parent" (Tracer.Error "boom") parent_span.status
  | spans -> Alcotest.failf "expected two spans, got %d" (List.length spans)

let test_observability_named_ok () =
  with_traced_runtime @@ fun rt tracer ->
  let eff = Effect.named "foo" (Effect.pure 1) in
  Alcotest.(check int) "value" 1 (run_ok rt eff);
  let span = only_span tracer in
  Alcotest.(check string) "name" "foo" span.name;
  check_status "status" Tracer.Ok span.status

let test_observability_span_kind () =
  with_traced_runtime @@ fun rt tracer ->
  run_ok rt (Effect.named_kind ~kind:Capabilities.Server "server" Effect.unit);
  let span = only_span tracer in
  Alcotest.(check bool) "server kind" true (span.kind = Tracer.Server)

let test_observability_fn_loc () =
  with_traced_runtime @@ fun rt tracer ->
  let program = Effect.fn __POS__ __FUNCTION__ (Effect.pure ()) in
  run_ok rt program;
  let span = only_span tracer in
  Alcotest.(check string) "name" __FUNCTION__ span.name;
  match attr "loc" span with
  | Some loc -> Alcotest.(check bool) "test file" true (String.contains loc '/')
  | None -> Alcotest.fail "missing loc attr"

let test_observability_annotation_order () =
  let run eff =
    with_traced_runtime @@ fun rt tracer ->
    run_ok rt eff;
    attr "k" (only_span tracer)
  in
  let inside =
    Effect.pure () |> Effect.annotate ~key:"k" ~value:"inside"
    |> Effect.named "span"
  in
  let outside =
    Effect.pure () |> Effect.named "span"
    |> Effect.annotate ~key:"k" ~value:"outside"
  in
  Alcotest.(check (option string)) "inside" (Some "inside") (run inside);
  Alcotest.(check (option string)) "outside" (Some "outside") (run outside)

let test_observability_nested_spans () =
  with_traced_runtime @@ fun rt tracer ->
  let eff =
    Effect.named "outer"
      (Effect.named "inner-a" (Effect.pure ())
      |> Effect.bind (fun () -> Effect.named "inner-b" (Effect.pure ())))
  in
  run_ok rt eff;
  match Tracer.dump tracer with
  | [ a; b; outer ] ->
      Alcotest.(check string) "outer" "outer" outer.name;
      Alcotest.(check (option int)) "a parent" (Some outer.span_id)
        a.parent_id;
      Alcotest.(check (option int)) "b parent" (Some outer.span_id)
        b.parent_id
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

let test_observability_statuses () =
  with_traced_runtime @@ fun rt tracer ->
  ignore (Runtime.run rt (Effect.named "fail" (Effect.fail `Boom)) :
            (unit, [> `Boom ]) Exit.t);
  ignore
    (Runtime.run rt
       (Effect.named "die" (Effect.sync "die" (fun () -> failwith "boom"))) :
      (unit, _) Exit.t);
  ignore
    (Runtime.run rt
       (Effect.named "interrupt"
          (Effect.sync "interrupt" (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "cancel"))))) :
      (unit, _) Exit.t);
  match Tracer.dump tracer with
  | [ fail_span; die_span; interrupt_span ] ->
      check_status "fail" (Tracer.Error "") fail_span.status;
      check_status "die" (Tracer.Error "") die_span.status;
      check_status "interrupt" Tracer.Cancelled interrupt_span.status
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

let test_observability_concurrent_status () =
  with_traced_runtime @@ fun rt tracer ->
  let eff =
    Effect.named "concurrent" (Effect.race [ Effect.fail "a"; Effect.fail "b" ])
  in
  ignore (Runtime.run rt eff : (unit, string) Exit.t);
  let span = only_span tracer in
  check_status "concurrent" (Tracer.Error "") span.status

let test_observability_cancelled_parallel_child_status () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let slow =
    Effect.named "slow" (Effect.pure () |> Effect.delay (Duration.ms 10))
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure () ]) in
  wait_for_sleepers clock 1;
  check_exit_ok Alcotest.unit "race done" () (Eio.Promise.await promise);
  let slow_span =
    List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
  in
  check_status "slow cancelled" Tracer.Cancelled slow_span.status

let test_observability_uninterruptible_parallel_child_status () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let slow =
    Effect.named "slow"
      (Effect.pure () |> Effect.delay (Duration.ms 10) |> Effect.uninterruptible)
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure () ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "protected child still running" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.unit "race done" () (Eio.Promise.await promise);
  let slow_span =
    List.find (fun span -> span.Tracer.name = "slow") (Tracer.dump tracer)
  in
  check_status "slow ok" Tracer.Ok slow_span.status

let test_observability_par_children_inherit_parent () =
  with_traced_runtime @@ fun rt tracer ->
  let child name = Effect.named name (Effect.pure ()) in
  let eff = Effect.named "parent" (Effect.par (child "a") (child "b")) in
  ignore (run_ok rt eff);
  match Tracer.dump tracer with
  | [ a; b; parent ] ->
      Alcotest.(check (option int)) "a parent" (Some parent.span_id) a.parent_id;
      Alcotest.(check (option int)) "b parent" (Some parent.span_id) b.parent_id
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

let test_observability_par_pending_attrs_links_are_fiber_local () =
  with_traced_test_clock @@ fun sw clock rt tracer ->
  let branch ~name ~delay ~attr_key ~link_span_id =
    Effect.pure ()
    |> Effect.named name
    |> Effect.delay (Duration.ms delay)
    |> Effect.link_span ~trace_id:("trace-" ^ name) ~span_id:link_span_id
    |> Effect.annotate ~key:attr_key ~value:"yes"
  in
  let promise =
    fork_run sw rt
      (Effect.par
         (branch ~name:"left" ~delay:10 ~attr_key:"left" ~link_span_id:"left-link")
         (branch ~name:"right" ~delay:5 ~attr_key:"right" ~link_span_id:"right-link"))
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok (Alcotest.pair Alcotest.unit Alcotest.unit) "par done" ((), ())
    (Eio.Promise.await promise);
  let spans = Tracer.dump tracer in
  let left = List.find (fun span -> span.Tracer.name = "left") spans in
  let right = List.find (fun span -> span.Tracer.name = "right") spans in
  Alcotest.(check (option string)) "left has left attr" (Some "yes")
    (attr "left" left);
  Alcotest.(check (option string)) "left has no right attr" None
    (attr "right" left);
  Alcotest.(check (list string)) "left links" [ "left-link" ]
    (link_span_id left);
  Alcotest.(check (option string)) "right has right attr" (Some "yes")
    (attr "right" right);
  Alcotest.(check (option string)) "right has no left attr" None
    (attr "left" right);
  Alcotest.(check (list string)) "right links" [ "right-link" ]
    (link_span_id right)

let test_observability_sampler_always_off () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt tracer ->
  run_ok rt (Effect.named "off" Effect.unit);
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_sampler_ratio () =
  with_sampled_traced_runtime (Sampler.ratio 0.5) @@ fun rt tracer ->
  let spans =
    List.init 1_000 (fun i -> Effect.named ("span-" ^ string_of_int i) Effect.unit)
  in
  run_ok rt (Effect.concat spans);
  let count = List.length (Tracer.dump tracer) in
  Alcotest.(check bool) "roughly half sampled" true (count > 350 && count < 650)

let test_observability_sampler_parent_based () =
  with_sampled_traced_runtime (Sampler.parent_based ()) @@ fun rt tracer ->
  run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
  Alcotest.(check int) "parent and child sampled" 2
    (List.length (Tracer.dump tracer));
  with_sampled_traced_runtime
    (Sampler.parent_based ~root:Sampler.always_off ())
  @@ fun rt tracer ->
  run_ok rt (Effect.named "parent" (Effect.named "child" Effect.unit));
  Alcotest.(check int) "unsampled parent suppresses child" 0
    (List.length (Tracer.dump tracer))

let test_observability_sampler_unsampled_parent_suppresses_par_children () =
  with_sampled_traced_runtime Sampler.always_off @@ fun rt tracer ->
  let child name = Effect.named name Effect.unit in
  ignore (run_ok rt (Effect.named "parent" (Effect.par (child "a") (child "b"))));
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_auto_instrument_default_off () =
  with_traced_runtime @@ fun rt tracer ->
  run_ok rt (Effect.sync "leaf" (fun () -> ()));
  Alcotest.(check int) "no spans" 0 (List.length (Tracer.dump tracer))

let test_observability_auto_instrument_sync_leaves () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.sync name (fun () -> ()) in
  run_ok rt (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]);
  Alcotest.(check (list string)) "leaf spans" [ "a"; "b"; "c" ]
    (List.map (fun span -> span.Tracer.name) (Tracer.dump tracer))

let test_observability_auto_instrument_leaves_nest_under_named () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  let leaf name = Effect.sync name (fun () -> ()) in
  run_ok rt (Effect.named "outer" (Effect.concat [ leaf "a"; leaf "b"; leaf "c" ]));
  let spans = Tracer.dump tracer in
  let outer = List.find (fun span -> span.Tracer.name = "outer") spans in
  let children = List.filter (fun span -> span.Tracer.name <> "outer") spans in
  List.iter
    (fun span ->
      Alcotest.(check (option int)) span.Tracer.name (Some outer.span_id)
        span.parent_id)
    children

let test_observability_auto_instrument_failure_status () =
  with_auto_traced_runtime true @@ fun rt tracer ->
  ignore (Runtime.run rt (Effect.sync "boom" (fun () -> failwith "boom")) :
            (unit, _) Exit.t);
  let span = only_span tracer in
  check_status "leaf failed" (Tracer.Error "") span.status

let test_observability_all_for_each_supervisor_inherit_parent () =
  with_traced_runtime @@ fun rt tracer ->
  let child name = Effect.named name (Effect.pure ()) in
  let supervised =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift (child "supervised"))
          in
          await child;
    }
  in
  let eff =
    Effect.named "parent"
      (Effect.all [ child "all-a"; child "all-b" ]
      |> Effect.bind (fun _ ->
             Effect.for_each_par [ "each-a"; "each-b" ] child)
      |> Effect.bind (fun _ -> supervised))
  in
  run_ok rt eff;
  let spans = Tracer.dump tracer in
  let parent = List.find (fun span -> span.Tracer.name = "parent") spans in
  let children = List.filter (fun span -> span.Tracer.name <> "parent") spans in
  List.iter
    (fun span ->
      Alcotest.(check (option int)) span.Tracer.name (Some parent.span_id)
        span.parent_id)
    children

let test_duration_constructors () =
  Alcotest.(check dur) "seconds" (Duration.ms 1_000) (Duration.seconds 1);
  Alcotest.(check dur) "minutes" (Duration.seconds 60) (Duration.minutes 1);
  Alcotest.(check dur) "hours" (Duration.minutes 60) (Duration.hours 1);
  Alcotest.(check dur) "days" (Duration.hours 24) (Duration.days 1);
  Alcotest.(check dur) "weeks" (Duration.days 7) (Duration.weeks 1)

let test_duration_ordering () =
  Alcotest.(check int) "lt" (-1)
    (Duration.compare (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check int) "eq" 0
    (Duration.compare (Duration.ms 2) (Duration.ms 2));
  Alcotest.(check int) "gt" 1
    (Duration.compare (Duration.ms 2) (Duration.ms 1));
  Alcotest.(check bool) "between" true
    (Duration.between ~min:(Duration.minutes 59) ~max:(Duration.minutes 61)
       (Duration.hours 1))

let test_duration_algebra () =
  Alcotest.(check dur) "sum" (Duration.minutes 1)
    (Duration.add (Duration.seconds 30) (Duration.seconds 30));
  Alcotest.(check dur) "subtract clamps at zero" Duration.zero
    (Duration.subtract (Duration.seconds 30) (Duration.seconds 40));
  Alcotest.(check dur) "times" (Duration.minutes 1)
    (Duration.times (Duration.seconds 1) 60);
  Alcotest.(check some_dur) "divide" (Some (Duration.seconds 30))
    (Duration.divide (Duration.minutes 1) 2);
  Alcotest.(check some_dur) "divide by zero" None
    (Duration.divide (Duration.minutes 1) 0)

let test_duration_min_max_clamp () =
  Alcotest.(check dur) "max" (Duration.ms 2)
    (Duration.max (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "min" (Duration.ms 1)
    (Duration.min (Duration.ms 1) (Duration.ms 2));
  Alcotest.(check dur) "clamp lower" (Duration.ms 2)
    (Duration.clamp ~min:(Duration.ms 2) ~max:(Duration.ms 3)
       (Duration.ms 1));
  Alcotest.(check dur) "clamp inside" (Duration.minutes 90)
    (Duration.clamp ~min:(Duration.minutes 60) ~max:(Duration.minutes 120)
       (Duration.minutes 90))

let test_recurs () =
  let s = Schedule.recurs 3 in
  Alcotest.(check some_dur) "0" (Some Duration.zero)
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "exhausted" None
    (Schedule.next_delay s ~step:3)

let test_exponential () =
  let s = Schedule.exponential ~factor:2.0 (dur_ms 10) in
  Alcotest.(check some_dur) "step 0" (Some (dur_ms 10))
    (Schedule.next_delay s ~step:0);
  Alcotest.(check some_dur) "step 2 = 40ms" (Some (dur_ms 40))
    (Schedule.next_delay s ~step:2)

let test_spaced_fixed_linear () =
  Alcotest.(check some_dur) "spaced" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.spaced (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "fixed" (Some (Duration.seconds 1))
    (Schedule.next_delay (Schedule.fixed (Duration.seconds 1)) ~step:4);
  Alcotest.(check some_dur) "linear step 3" (Some (Duration.seconds 7))
    (Schedule.next_delay
       (Schedule.linear ~initial:(Duration.seconds 1)
          ~step:(Duration.seconds 2))
       ~step:3)

let test_schedule_composition () =
  Alcotest.(check some_dur) "both takes max" (Some (Duration.seconds 2))
    (Schedule.next_delay
       (Schedule.both (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "either takes min" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.either (Schedule.spaced (Duration.seconds 1))
          (Schedule.spaced (Duration.seconds 2)))
       ~step:0);
  Alcotest.(check some_dur) "and_then falls through" (Some (Duration.seconds 1))
    (Schedule.next_delay
       (Schedule.and_then (Schedule.recurs 1)
          (Schedule.spaced (Duration.seconds 1)))
       ~step:1)

let test_effect_map_bind_tap_runtime () =
  with_runtime @@ fun rt ->
  let observed = ref [] in
  let eff =
    Effect.pure 1
    |> Effect.map (fun n -> n + 1)
    |> Effect.bind (fun n -> Effect.pure (n * 2))
    |> Effect.tap (fun n ->
           Effect.sync "tap" (fun () -> observed := n :: !observed))
    |> Effect.map (fun n -> n + 1)
  in
  Alcotest.(check int) "value" 5 (run_ok rt eff);
  Alcotest.(check (list int)) "tap saw pre-map value" [ 4 ] !observed

let test_effect_catch_success_and_failure () =
  with_runtime @@ fun rt ->
  let success =
    Effect.pure 1
    |> Effect.catch (fun (`Unexpected : [ `Unexpected ]) ->
           Effect.fail `Handler_ran)
  in
  let failure =
    Effect.fail `First
    |> Effect.catch (fun (`First : [ `First ]) -> Effect.fail `Second)
    |> Effect.catch (fun (`Second : [ `Second ]) -> Effect.pure "recovered")
  in
  Alcotest.(check int) "success bypasses catch" 1 (run_ok rt success);
  Alcotest.(check string) "failure recovers" "recovered" (run_ok rt failure)

let test_effect_tap_error_observes_and_rethrows () =
  with_runtime @@ fun rt ->
  let observed = ref false in
  let eff =
    Effect.fail `Boom
    |> Effect.tap_error (fun (`Boom : [ `Boom ]) -> observed := true)
    |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure "recovered")
  in
  Alcotest.(check string) "recovered" "recovered" (run_ok rt eff);
  Alcotest.(check bool) "observed" true !observed

let test_runtime_exit_fail_die_interrupt () =
  with_runtime @@ fun rt ->
  let die = Failure "boom" in
  let fail_exit = Runtime.run rt (Effect.fail "bad") in
  let die_exit = Runtime.run rt (Effect.sync "die" (fun () -> raise die)) in
  let interrupt_exit =
    Runtime.run rt
      (Effect.sync "interrupt" (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  check_exit_error string_cause "typed failure" (Cause.Fail "bad") fail_exit;
  (match die_exit with
  | Exit.Error (Cause.Die (exn, _)) ->
      Alcotest.(check bool) "same exception" true (exn == die)
  | _ -> Alcotest.fail "expected Die");
  (match interrupt_exit with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt")

let test_effect_catch_does_not_catch_interrupt () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.sync "interrupt" (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
    |> Effect.catch (fun (_ : string) -> Effect.pure "caught")
  in
  match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt"

let test_effect_retry_does_not_retry_interrupt () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.sync "interrupt" (fun () ->
        incr attempts;
        raise (Eio.Cancel.Cancelled (Failure "cancel")))
  in
  let eff = Effect.retry (Schedule.recurs 3) (fun (_ : string) -> true) attempt in
  (match Runtime.run rt eff with
  | Exit.Error (Cause.Interrupt None) -> ()
  | _ -> Alcotest.fail "expected Interrupt");
  Alcotest.(check int) "not retried" 1 !attempts

let test_acquire_release () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.sync name (fun () -> trail := name :: !trail) in
  let eff =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(mark "acquired" |> Effect.map (fun () -> 1))
         ~release:(fun _ -> mark "released")
      |> Effect.bind (fun _ -> mark "body"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "ordering" [ "acquired"; "body"; "released" ] (List.rev !trail)

let test_acquire_release_on_failure () =
  with_runtime @@ fun rt ->
  let trail = ref [] in
  let mark name = Effect.sync name (fun () -> trail := name :: !trail) in
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(mark "acq") ~release:(fun () ->
           mark "rel")
      |> Effect.bind (fun () -> Effect.fail `Boom)
      |> Effect.catch (fun (`Boom : [ `Boom ]) -> mark "caught"))
  in
  run_ok rt eff;
  Alcotest.(check (list string))
    "release after recovered body failure"
    [ "acq"; "caught"; "rel" ] (List.rev !trail)

let test_acquire_release_suppresses_release_failure () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.fail "body"))
  in
  match Runtime.run rt eff with
  | Exit.Error
      (Cause.Suppressed
        { primary = Cause.Fail "body"; finalizer = Cause.Fail "release" }) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed release failure, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok () -> Alcotest.fail "expected suppressed release failure"

let test_acquire_release_release_failure_after_success () =
  with_runtime @@ fun rt ->
  let eff =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure ())
         ~release:(fun () -> Effect.fail "release")
      |> Effect.bind (fun () -> Effect.pure "body"))
  in
  check_exit_error string_cause "release failure" (Cause.Fail "release")
    (Runtime.run rt eff)

let test_effect_timeout_uses_virtual_clock () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 10)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 5);
  check_exit_ok Alcotest.string "timed out" "timeout"
    (Eio.Promise.await promise)

let test_effect_timeout_allows_fast_success () =
  with_test_clock @@ fun sw clock rt ->
  let eff =
    Effect.pure "done"
    |> Effect.delay (Duration.seconds 2)
    |> Effect.timeout (Duration.seconds 5)
    |> Effect.catch (fun (`Timeout : [ `Timeout ]) -> Effect.pure "timeout")
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.seconds 2);
  check_exit_ok Alcotest.string "completed" "done"
    (Eio.Promise.await promise)

let test_effect_race_ignores_early_failure_until_success () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_success ms value =
    Effect.pure value |> Effect.delay (Duration.ms ms)
  in
  let eff =
    Effect.race
      [
        Effect.fail `Boom |> Effect.delay Duration.zero;
        delayed_success 200 200;
        delayed_success 100 100;
      ]
  in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 2;
  Alcotest.(check int) "race sleepers registered" 2
    (Test_clock.sleeper_count clock);
  Test_clock.adjust clock (Duration.ms 100);
  check_exit_ok Alcotest.int "first success wins" 100
    (Eio.Promise.await promise)

let test_effect_race_all_failures_returns_concurrent_causes () =
  with_test_clock @@ fun sw clock rt ->
  let delayed_failure ms error =
    Effect.fail error |> Effect.delay (Duration.ms ms)
  in
  let eff = Effect.race [ delayed_failure 0 "first"; delayed_failure 10 "second" ] in
  let promise = fork_run sw rt eff in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_error string_cause "failures combined"
    (Cause.Concurrent [ Cause.Fail "first"; Cause.Fail "second" ])
    (Eio.Promise.await promise)

let test_effect_repeat_schedule () =
  with_runtime @@ fun rt ->
  let ticks = ref 0 in
  let tick = Effect.sync "tick" (fun () -> incr ticks) in
  run_ok rt (Effect.repeat (Schedule.recurs 3) tick);
  Alcotest.(check int) "initial run plus three repeats" 4 !ticks

let test_effect_repeat_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let ticks = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 3) (Schedule.spaced (Duration.ms 5))
  in
  let promise =
    fork_run sw rt (Effect.sync "tick" (fun () -> incr ticks) |> Effect.repeat schedule)
  in
  yield ();
  Alcotest.(check int) "initial tick" 1 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second tick" 2 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "third tick" 3 !ticks;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.unit "repeat done" () (Eio.Promise.await promise);
  Alcotest.(check int) "three delayed repeats" 4 !ticks

let test_effect_retry_schedule_until_success () =
  with_runtime @@ fun rt ->
  let attempts = ref 0 in
  let attempt =
    Effect.sync "attempt" (fun () ->
        incr attempts;
        !attempts)
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  Alcotest.(check int) "succeeded" 3
    (run_ok rt (Effect.retry (Schedule.recurs 5) (fun (`Again _) -> true) attempt))

let test_effect_retry_schedule_uses_virtual_delays () =
  with_test_clock @@ fun sw clock rt ->
  let attempts = ref 0 in
  let schedule =
    Schedule.both (Schedule.recurs 5) (Schedule.spaced (Duration.ms 5))
  in
  let attempt =
    Effect.sync "attempt" (fun () ->
        incr attempts;
        !attempts)
    |> Effect.bind (fun n ->
           if n < 3 then Effect.fail (`Again n) else Effect.pure n)
  in
  let promise =
    fork_run sw rt (Effect.retry schedule (fun (`Again _) -> true) attempt)
  in
  yield ();
  Alcotest.(check int) "first attempt before delay" 1 !attempts;
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  check_exit_ok Alcotest.int "succeeded on delayed third attempt" 3
    (Eio.Promise.await promise)

let test_supervisor_observes_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          failures sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Ok [ Cause.Fail `Boom ] -> ()
  | _ -> Alcotest.fail "expected observed child failure"

let test_supervisor_await_rethrows_child_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], int) Supervisor.child) =
            start sup (fail `Boom)
          in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Fail `Boom) -> ()
  | _ -> Alcotest.fail "expected await to rethrow child failure"

let test_supervisor_cancel_runs_finalizer () =
  with_test_clock @@ fun _sw clock rt ->
  let finalizer_ran = ref false in
  let child =
    Effect.acquire_release
      ~acquire:(Effect.sync "supervisor.acquire" (fun _ -> ()))
      ~release:(fun () ->
        Effect.sync "supervisor.release" (fun _ -> finalizer_ran := true))
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1_000) Effect.unit)
  in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () =
            lift
              (Effect.sync "supervisor.wait_for_child" (fun _ ->
                   wait_for_sleepers clock 1))
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) ->
      Alcotest.(check bool) "finalizer ran" true !finalizer_ran
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_cancel_before_await_does_not_deadlock () =
  with_test_clock @@ fun _sw _clock rt ->
  let child = Effect.delay (Duration.ms 1_000) Effect.unit in
  let program =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (child : (s, [> `Boom ], unit) Supervisor.child) =
            start sup (lift child)
          in
          let* () = cancel child in
          await child;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Interrupt None) -> ()
  | Exit.Error cause ->
      Alcotest.failf "expected Interrupt, got %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "err"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected Interrupt, got Ok"

let test_supervisor_threshold_failure () =
  with_runtime @@ fun rt ->
  let program =
    Supervisor.scoped ~max_failures:1 {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child :
                  (s, [> `Boom | `Supervisor_failed of int ], int)
                  Supervisor.child) =
            start sup (fail `Boom)
          in
          let* () = yield in
          check sup;
    }
  in
  match Runtime.run rt program with
  | Exit.Error (Cause.Fail (`Supervisor_failed 1)) -> ()
  | _ -> Alcotest.fail "expected supervisor threshold failure"

let test_supervisor_nested_scopes_compose () =
  with_runtime @@ fun rt ->
  let inner =
    Supervisor.scoped {
      run =
        fun (type s) sup ->
          let open Supervisor.Scope in
          let* (_child : (s, [> `Inner ], unit) Supervisor.child) =
            start sup (fail `Inner)
          in
          let* () = yield in
          failures sup;
    }
  in
  let outer =
    Supervisor.scoped {
      run =
        fun (_ : (_, _) Supervisor.t) ->
          let open Supervisor.Scope in
          let* inner_failures = lift inner in
          pure (List.length inner_failures);
    }
  in
  Alcotest.(check int) "inner failure observed" 1 (run_ok rt outer)

let test_effect_uninterruptible_defers_race_cancellation () =
  with_test_clock @@ fun sw clock rt ->
  let slow_completed = ref false in
  let slow =
    Effect.sync "slow.done" (fun () ->
        slow_completed := true;
        "slow")
    |> Effect.delay (Duration.ms 10)
    |> Effect.uninterruptible
  in
  let promise = fork_run sw rt (Effect.race [ slow; Effect.pure "fast" ]) in
  wait_for_sleepers clock 1;
  yield ();
  Alcotest.(check bool) "race waits for protected loser" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.ms 10);
  check_exit_ok Alcotest.string "winner preserved" "fast"
    (Eio.Promise.await promise);
  Alcotest.(check bool) "protected loser completed" true !slow_completed

let test_clock_sleep_without_wall_time () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 11);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_delays_until_adjusted () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.hours 9);
  yield ();
  Alcotest.(check bool) "not elapsed after 9h" false
    (Eio.Promise.is_resolved promise);
  Test_clock.adjust clock (Duration.hours 1);
  check_exit_ok Alcotest.string "elapsed" "elapsed"
    (Eio.Promise.await promise)

let test_clock_sleep_handles_multiple_sleeps () =
  with_test_clock @@ fun sw clock rt ->
  let append message acc = acc ^ message in
  let slow =
    Effect.pure (append "World!")
    |> Effect.delay (Duration.hours 3)
  in
  let fast =
    Effect.pure (append "Hello, ")
    |> Effect.delay (Duration.hours 1)
  in
  let promise = fork_run sw rt (Effect.race [ slow; fast ]) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.hours 1);
  let f =
    match Eio.Promise.await promise with
    | Exit.Ok f -> f
    | Exit.Error _ -> Alcotest.fail "expected Ok"
  in
  Alcotest.(check string) "first sleeper wins" "Hello, " (f "")

let test_clock_set_time_wakes_due_sleepers () =
  with_test_clock @@ fun sw clock rt ->
  let promise =
    fork_run sw rt
      (Effect.pure "elapsed" |> Effect.delay (Duration.hours 10))
  in
  wait_for_sleepers clock 1;
  Test_clock.set_time clock (Duration.to_ms (Duration.hours 11));
  check_exit_ok Alcotest.string "elapsed after set_time" "elapsed"
    (Eio.Promise.await promise)

let test_scope_finalizers_run_in_parallel () =
  with_test_clock @@ fun sw clock rt ->
  let released = ref 0 in
  let resource =
    Effect.acquire_release ~acquire:Effect.unit ~release:(fun () ->
        Effect.sync "release" (fun () -> incr released)
        |> Effect.delay (Duration.seconds 1))
  in
  let promise =
    fork_run sw rt (Effect.scoped (Effect.concat [ resource; resource; resource ]))
  in
  yield ();
  wait_for_sleepers clock 3;
  Test_clock.adjust clock (Duration.seconds 1);
  check_exit_ok Alcotest.unit "scope done" () (Eio.Promise.await promise);
  Alcotest.(check int) "all finalizers released" 3 !released

let test_resource_manual_refresh () =
  with_runtime @@ fun rt ->
  let source = ref 0 in
  let load = Effect.sync "resource.load" (fun () -> !source) in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Resource.get resource
           |> Effect.bind (fun initial ->
                  Effect.sync "source.set" (fun () -> source := 1)
                  |> Effect.bind (fun () -> Resource.refresh resource)
                  |> Effect.bind (fun () -> Resource.get resource)
                  |> Effect.map (fun refreshed -> (initial, refreshed))))
  in
  Alcotest.(check (pair int int)) "initial then refreshed" (0, 1)
    (run_ok rt eff)

let test_resource_failed_refresh_keeps_cached_value () =
  with_runtime @@ fun rt ->
  let source = ref (Ok 0) in
  let load =
    Effect.sync "resource.load" (fun () -> !source)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let eff =
    Resource.manual load
    |> Effect.bind (fun resource ->
           Effect.sync "source.fail" (fun () -> source := Error "Uh oh!")
           |> Effect.bind (fun () -> Resource.refresh resource)
           |> Effect.catch (fun (`Refresh_failed _ : [ `Refresh_failed of string ]) ->
                  Effect.unit)
           |> Effect.bind (fun () -> Resource.get resource))
  in
  Alcotest.(check int) "cached value survived failed refresh" 0 (run_ok rt eff)

let test_resource_auto_refreshes_on_schedule () =
  with_test_clock @@ fun _sw clock rt ->
  let source = ref 0 in
  let load =
    Effect.sync "resource.auto.load" (fun () ->
        incr source;
        !source)
  in
  let resource =
    run_ok rt (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "first refresh" 2 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "second refresh" 3 (run_ok rt (Resource.get resource))

let test_resource_auto_failed_refresh_keeps_cached_value () =
  with_test_clock @@ fun _sw clock rt ->
  let results = ref [ Ok 1; Error "boom"; Ok 2 ] in
  let load =
    Effect.sync "resource.auto.load" (fun () ->
        match !results with
        | [] -> Ok 999
        | result :: rest ->
            results := rest;
            result)
    |> Effect.bind (function
         | Ok value -> Effect.pure value
         | Error message -> Effect.fail (`Refresh_failed message))
  in
  let errors = ref [] in
  let resource =
    run_ok rt
      (Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5))
         ~on_error:(fun err -> errors := err :: !errors) ())
  in
  Alcotest.(check int) "initial value" 1 (run_ok rt (Resource.get resource));
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "failed refresh keeps old value" 1
    (run_ok rt (Resource.get resource));
  Alcotest.(check (list string)) "observed refresh error" [ "boom" ]
    (List.map (fun (`Refresh_failed message) -> message) (List.rev !errors));
  (match run_ok rt (Resource.failures resource) with
  | [ Cause.Fail (`Refresh_failed "boom") ] -> ()
  | _ -> Alcotest.fail "expected resource failure sink to record refresh error");
  wait_for_sleepers clock 1;
  Test_clock.adjust clock (Duration.ms 5);
  yield ();
  Alcotest.(check int) "subsequent refresh updates" 2
    (run_ok rt (Resource.get resource))

(* Auto-DI regression: A defined without naming services or threading.
   The env-row property is the whole reason for the 'env channel.
   See journal V-R10 and scratch/r_research/r_b_env_row.ml. *)
let test_env_row_auto_di () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let log_calls = ref [] in
  let env =
    object
      method db = object method query s = "row:" ^ s end
      method log =
        object method info m = log_calls := m :: !log_calls end
    end
  in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env ()
  in
  let b msg = Effect.sync "log" (fun env -> env#log#info msg) in
  let c id = Effect.sync "db" (fun env -> env#db#query id) in
  (* A composes B and C without naming services or threading. *)
  let a id =
    let open Effect in
    bind (fun () -> c id) (b ("fetching " ^ id))
  in
  match Runtime.run rt (a "42") with
  | Exit.Error _ -> Alcotest.fail "expected Ok"
  | Exit.Ok value ->
      Alcotest.(check string) "db result" "row:42" value;
      Alcotest.(check (list string))
        "log calls" [ "fetching 42" ] (List.rev !log_calls)

(* V-F1 (F-A): par / all / for_each_par. Fail-fast semantics. *)
let test_par_returns_both_successes () =
  with_runtime @@ fun rt ->
  let result = run_ok rt (Effect.par (Effect.pure 1) (Effect.pure 2)) in
  Alcotest.(check (pair int int)) "par returns pair" (1, 2) result

let test_par_fail_fast_cancels_sibling () =
  with_runtime @@ fun rt ->
  let other_done = ref false in
  let slow_other =
    Effect.sync "slow" (fun _ ->
        Eio.Fiber.yield ();
        other_done := true;
        99)
  in
  let cause =
    match Runtime.run rt (Effect.par (Effect.fail "boom") slow_other) with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "par cause" (Cause.Fail "boom") cause;
  Alcotest.(check bool) "sibling cancelled before completion" false !other_done

let test_all_collects_in_input_order () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt (Effect.all [ Effect.pure 1; Effect.pure 2; Effect.pure 3 ])
  in
  Alcotest.(check (list int)) "all order" [ 1; 2; 3 ] result

let test_all_fail_fast () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.all [ Effect.pure 1; Effect.fail "boom"; Effect.pure 3 ])
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "all cause" (Cause.Fail "boom") cause

let test_all_settled_collects_successes_and_failures () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.all_settled
         [ Effect.pure 1; Effect.fail `Boom; Effect.pure 3 ])
  in
  match result with
  | [ Ok 1; Error (Cause.Fail `Boom); Ok 3 ] -> ()
  | _ -> Alcotest.fail "unexpected all_settled result"

let test_all_settled_runs_all_children () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref 0 in
  let slow name =
    Effect.sync name (fun () -> incr slow_done)
    |> Effect.delay (Duration.ms 50)
  in
  let promise =
    fork_run sw rt (Effect.all_settled [ Effect.fail `Boom; slow "a"; slow "b" ])
  in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 50);
  ignore
    (Eio.Promise.await promise :
      ((unit, [> `Boom ] Cause.t) result list, _) Exit.t);
  Alcotest.(check int) "slow children completed" 2 !slow_done

let test_all_settled_empty () =
  with_runtime @@ fun rt ->
  Alcotest.(check int) "empty" 0 (List.length (run_ok rt (Effect.all_settled [])))

let test_for_each_par_success () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.for_each_par [ 10; 20; 30 ] (fun x -> Effect.pure (x + 1)))
  in
  Alcotest.(check (list int)) "for_each_par results" [ 11; 21; 31 ] result

let test_for_each_par_one_fails () =
  with_runtime @@ fun rt ->
  let cause =
    match
      Runtime.run rt
        (Effect.for_each_par [ 1; 2; 3 ] (fun x ->
             if x = 2 then Effect.fail "bad" else Effect.pure x))
    with
    | Exit.Ok _ -> Alcotest.fail "expected Error"
    | Exit.Error c -> c
  in
  Alcotest.check string_cause "for_each_par cause" (Cause.Fail "bad") cause

let test_for_each_par_bounded_caps_concurrency () =
  with_test_clock @@ fun sw clock rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.sync "enter" (fun () ->
        incr active;
        max_seen := max !max_seen !active)
    |> Effect.bind (fun () ->
           Effect.pure x
           |> Effect.delay (Duration.ms 10)
           |> Effect.tap (fun _ ->
                  Effect.sync "leave" (fun () -> decr active)))
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3; 4; 5 ] worker)
  in
  for _ = 1 to 3 do
    wait_for_sleepers clock 1;
    Test_clock.adjust clock (Duration.ms 10);
    yield ()
  done;
  check_exit_ok (Alcotest.list Alcotest.int) "results" [ 1; 2; 3; 4; 5 ]
    (Eio.Promise.await promise);
  Alcotest.(check int) "max concurrency" 2 !max_seen

let test_for_each_par_bounded_max_one_is_sequential () =
  with_runtime @@ fun rt ->
  let active = ref 0 in
  let max_seen = ref 0 in
  let worker x =
    Effect.sync "worker" (fun () ->
        incr active;
        max_seen := max !max_seen !active;
        decr active;
        x)
  in
  Alcotest.(check (list int)) "results" [ 1; 2; 3 ]
    (run_ok rt (Effect.for_each_par_bounded ~max:1 [ 1; 2; 3 ] worker));
  Alcotest.(check int) "max concurrency" 1 !max_seen

let test_for_each_par_bounded_fail_fast () =
  with_test_clock @@ fun sw clock rt ->
  let slow_done = ref false in
  let worker = function
    | 1 -> Effect.fail "boom"
    | _ ->
        Effect.sync "slow" (fun () -> slow_done := true)
        |> Effect.delay (Duration.ms 10)
  in
  let promise =
    fork_run sw rt (Effect.for_each_par_bounded ~max:2 [ 1; 2; 3 ] worker)
  in
  yield ();
  check_exit_error string_cause "cause" (Cause.Fail "boom")
    (Eio.Promise.await promise);
  Test_clock.adjust clock (Duration.ms 10);
  yield ();
  Alcotest.(check bool) "slow cancelled" false !slow_done

let () =
  Alcotest.run "effet"
    [
      ( "Effect",
        [
          Alcotest.test_case "Pure" `Quick test_pure;
          Alcotest.test_case "Map" `Quick test_map;
          Alcotest.test_case "env row auto DI" `Quick test_env_row_auto_di;
          Alcotest.test_case "par returns pair" `Quick
            test_par_returns_both_successes;
          Alcotest.test_case "par fail-fast cancels sibling" `Quick
            test_par_fail_fast_cancels_sibling;
          Alcotest.test_case "all collects in input order" `Quick
            test_all_collects_in_input_order;
          Alcotest.test_case "all fail-fast" `Quick test_all_fail_fast;
          Alcotest.test_case "all_settled collects outcomes" `Quick
            test_all_settled_collects_successes_and_failures;
          Alcotest.test_case "all_settled runs all children" `Quick
            test_all_settled_runs_all_children;
          Alcotest.test_case "all_settled empty" `Quick test_all_settled_empty;
          Alcotest.test_case "for_each_par success" `Quick
            test_for_each_par_success;
          Alcotest.test_case "for_each_par one fails" `Quick
            test_for_each_par_one_fails;
          Alcotest.test_case "for_each_par_bounded caps concurrency" `Quick
            test_for_each_par_bounded_caps_concurrency;
          Alcotest.test_case "for_each_par_bounded max one is sequential" `Quick
            test_for_each_par_bounded_max_one_is_sequential;
          Alcotest.test_case "for_each_par_bounded fail-fast" `Quick
            test_for_each_par_bounded_fail_fast;
          Alcotest.test_case "collect_names" `Quick test_collect_names;
          Alcotest.test_case "map bind tap runtime" `Quick
            test_effect_map_bind_tap_runtime;
          Alcotest.test_case "catch success and failure" `Quick
            test_effect_catch_success_and_failure;
          Alcotest.test_case "tap_error observes and rethrows" `Quick
            test_effect_tap_error_observes_and_rethrows;
          Alcotest.test_case "runtime exit fail die interrupt" `Quick
            test_runtime_exit_fail_die_interrupt;
          Alcotest.test_case "catch does not catch interrupt" `Quick
            test_effect_catch_does_not_catch_interrupt;
          Alcotest.test_case "acquire release" `Quick test_acquire_release;
          Alcotest.test_case "acquire release on failure" `Quick
            test_acquire_release_on_failure;
          Alcotest.test_case "acquire release suppresses release failure" `Quick
            test_acquire_release_suppresses_release_failure;
          Alcotest.test_case "acquire release release failure after success"
            `Quick test_acquire_release_release_failure_after_success;
          Alcotest.test_case "timeout uses virtual clock" `Quick
            test_effect_timeout_uses_virtual_clock;
          Alcotest.test_case "timeout allows fast success" `Quick
            test_effect_timeout_allows_fast_success;
          Alcotest.test_case "race ignores early failure until success" `Quick
            test_effect_race_ignores_early_failure_until_success;
          Alcotest.test_case "race all failures returns concurrent causes" `Quick
            test_effect_race_all_failures_returns_concurrent_causes;
          Alcotest.test_case "repeat schedule" `Quick test_effect_repeat_schedule;
          Alcotest.test_case "repeat schedule uses virtual delays" `Quick
            test_effect_repeat_schedule_uses_virtual_delays;
          Alcotest.test_case "retry schedule until success" `Quick
            test_effect_retry_schedule_until_success;
          Alcotest.test_case "retry schedule uses virtual delays" `Quick
            test_effect_retry_schedule_uses_virtual_delays;
          Alcotest.test_case "retry does not retry interrupt" `Quick
            test_effect_retry_does_not_retry_interrupt;
          Alcotest.test_case "uninterruptible defers race cancellation" `Quick
            test_effect_uninterruptible_defers_race_cancellation;
        ] );
      ( "Supervisor",
        [
          Alcotest.test_case "observes child failure" `Quick
            test_supervisor_observes_child_failure;
          Alcotest.test_case "await rethrows child failure" `Quick
            test_supervisor_await_rethrows_child_failure;
          Alcotest.test_case "cancel runs finalizer" `Quick
            test_supervisor_cancel_runs_finalizer;
          Alcotest.test_case "cancel before await does not deadlock" `Quick
            test_supervisor_cancel_before_await_does_not_deadlock;
          Alcotest.test_case "threshold failure" `Quick
            test_supervisor_threshold_failure;
          Alcotest.test_case "nested scopes compose" `Quick
            test_supervisor_nested_scopes_compose;
        ] );
      ( "Clock",
        [
          Alcotest.test_case "sleep without wall time" `Quick
            test_clock_sleep_without_wall_time;
          Alcotest.test_case "sleep delays until adjusted" `Quick
            test_clock_sleep_delays_until_adjusted;
          Alcotest.test_case "multiple sleeps" `Quick
            test_clock_sleep_handles_multiple_sleeps;
          Alcotest.test_case "set_time wakes due sleepers" `Quick
            test_clock_set_time_wakes_due_sleepers;
        ] );
      ( "Duration",
        [
          Alcotest.test_case "constructors" `Quick test_duration_constructors;
          Alcotest.test_case "ordering" `Quick test_duration_ordering;
          Alcotest.test_case "algebra" `Quick test_duration_algebra;
          Alcotest.test_case "min max clamp" `Quick test_duration_min_max_clamp;
        ] );
      ( "Schedule",
        [
          Alcotest.test_case "recurs" `Quick test_recurs;
          Alcotest.test_case "exponential" `Quick test_exponential;
          Alcotest.test_case "spaced fixed linear" `Quick
            test_spaced_fixed_linear;
          Alcotest.test_case "composition" `Quick test_schedule_composition;
        ] );
      ( "Scope",
        [
          Alcotest.test_case "finalizers run in parallel" `Quick
            test_scope_finalizers_run_in_parallel;
        ] );
      ( "Resource",
        [
          Alcotest.test_case "manual refresh" `Quick test_resource_manual_refresh;
          Alcotest.test_case "failed refresh keeps cached value" `Quick
            test_resource_failed_refresh_keeps_cached_value;
          Alcotest.test_case "auto refreshes on schedule" `Quick
            test_resource_auto_refreshes_on_schedule;
          Alcotest.test_case "auto failed refresh keeps cached value" `Quick
            test_resource_auto_failed_refresh_keeps_cached_value;
        ] );
      ( "Observability",
        [
          Alcotest.test_case "manual tracer spans" `Quick
            test_tracer_manual_spans;
          Alcotest.test_case "named span status ok" `Quick
            test_observability_named_ok;
          Alcotest.test_case "span kind" `Quick test_observability_span_kind;
          Alcotest.test_case "fn records location" `Quick test_observability_fn_loc;
          Alcotest.test_case "annotation order" `Quick
            test_observability_annotation_order;
          Alcotest.test_case "nested spans" `Quick test_observability_nested_spans;
          Alcotest.test_case "statuses" `Quick test_observability_statuses;
          Alcotest.test_case "concurrent status" `Quick
            test_observability_concurrent_status;
          Alcotest.test_case "cancelled child status" `Quick
            test_observability_cancelled_parallel_child_status;
          Alcotest.test_case "uninterruptible child status" `Quick
            test_observability_uninterruptible_parallel_child_status;
          Alcotest.test_case "par children inherit parent" `Quick
            test_observability_par_children_inherit_parent;
          Alcotest.test_case "par pending attrs links are fiber-local" `Quick
            test_observability_par_pending_attrs_links_are_fiber_local;
          Alcotest.test_case "sampler always off" `Quick
            test_observability_sampler_always_off;
          Alcotest.test_case "sampler ratio" `Quick
            test_observability_sampler_ratio;
          Alcotest.test_case "sampler parent based" `Quick
            test_observability_sampler_parent_based;
          Alcotest.test_case "sampler suppresses par children" `Quick
            test_observability_sampler_unsampled_parent_suppresses_par_children;
          Alcotest.test_case "auto instrument default off" `Quick
            test_observability_auto_instrument_default_off;
          Alcotest.test_case "auto instrument sync leaves" `Quick
            test_observability_auto_instrument_sync_leaves;
          Alcotest.test_case "auto instrument leaves nest" `Quick
            test_observability_auto_instrument_leaves_nest_under_named;
          Alcotest.test_case "auto instrument failure status" `Quick
            test_observability_auto_instrument_failure_status;
          Alcotest.test_case "all for_each_par supervisor inherit parent" `Quick
            test_observability_all_for_each_supervisor_inherit_parent;
        ] );
    ]
