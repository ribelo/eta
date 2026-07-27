open Eta
open Eta_test
open Test_eta_support

module Counting_host_eio = struct
  let switch_runs = Atomic.make 0
  let active_switch = Atomic.make None

  module Eio_ops = struct
    module Time = struct
      let now _ = 0.0
      let sleep _ _ = invalid_arg "Counting_host_eio.Time.sleep: unexpected sleep"
    end

    module Net = struct
      let getaddrinfo_stream = Eio.Net.getaddrinfo_stream
      let connect = Eio.Net.connect
    end

    module Flow = struct
      let single_read = Eio.Flow.single_read
      let write = Eio.Flow.write
    end

    module Switch = struct
      let run ?name f =
        ignore name;
        Atomic.incr switch_runs;
        match Atomic.get active_switch with
        | Some sw -> f sw
        | None -> invalid_arg "Counting_host_eio.Switch.run: no active switch"

      let fail ?bt sw exn = Eio.Switch.fail ?bt sw exn
    end

    module Fiber = struct
      let get _ = None
      let with_binding _ _ f = f ()
      let first ?combine left right = Eio.Fiber.first ?combine left right
      let await_cancel = Eio.Fiber.await_cancel
      let fork ~sw f = Eio.Fiber.fork ~sw f
      let fork_daemon ~sw f = Eio.Fiber.fork_daemon ~sw f
      let yield = Eio.Fiber.yield
      let check = Eio.Fiber.check
    end

    module Stream = struct
      type 'a t = 'a Eio.Stream.t

      let create = Eio.Stream.create
      let add = Eio.Stream.add
      let take = Eio.Stream.take
      let take_nonblocking = Eio.Stream.take_nonblocking
    end

    module Cancel = struct
      let sub = Eio.Cancel.sub
      let cancel = Eio.Cancel.cancel
    end
  end

  let with_host sw f =
    Atomic.set switch_runs 0;
    Atomic.set active_switch (Some sw);
    Fun.protect
      ~finally:(fun () -> Atomic.set active_switch None)
      (fun () -> f (Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()))
end

let run_in_system_thread f =
  let result = ref None in
  let thread =
    Thread.create
      (fun () ->
        result :=
          Some
            (try Ok (f ())
             with exn -> Error (exn, Printexc.get_raw_backtrace ())))
      ()
  in
  Thread.join thread;
  match !result with
  | Some (Ok value) -> value
  | Some (Error (exn, backtrace)) ->
      Printexc.raise_with_backtrace exn backtrace
  | None -> Alcotest.fail "system thread did not return a result"

let test_effect_scoped_creates_switch_in_fiberless_host_run () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  Counting_host_eio.with_host sw @@ fun host ->
  Eta_eio.Runtime.with_host host ~sw ~clock:(Eio.Stdenv.clock stdenv)
  @@ fun rt ->
  let before = Atomic.get Counting_host_eio.switch_runs in
  let exit =
    run_in_system_thread (fun () ->
        Runtime.run rt (Effect.with_scope Effect.unit))
  in
  check_exit_ok Alcotest.unit "scoped result" () exit;
  Alcotest.(check int)
    "fiberless scoped host switch runs" 1
    (Atomic.get Counting_host_eio.switch_runs - before)

let test_effect_fiberless_frame_is_domain_local () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let sleep_a = Atomic.make 0 in
  let sleep_b = Atomic.make 0 in
  let rt_a =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(fun _ -> Atomic.incr sleep_a)
      ()
  in
  let rt_b =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(fun _ -> Atomic.incr sleep_b)
      ()
  in
  let ready = Atomic.make 0 in
  let barrier () =
    ignore (Atomic.fetch_and_add ready 1 : int);
    while Atomic.get ready < 2 do
      Domain.cpu_relax ()
    done
  in
  let eff =
    Effect.sync barrier
    |> Effect.bind (fun () -> Effect.delay (Duration.ms 1) Effect.unit)
  in
  let run rt =
    match Runtime.run rt eff with
    | Exit.Ok () -> ()
    | Exit.Error cause ->
        Alcotest.failf "expected Ok, got %a"
          (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<fiberless>"))
          cause
  in
  let domain_a =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () -> run rt_a)
  in
  let domain_b =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () -> run rt_b)
  in
  Domain.join domain_a;
  Domain.join domain_b;
  Alcotest.(check int) "runtime A sleep" 1 (Atomic.get sleep_a);
  Alcotest.(check int) "runtime B sleep" 1 (Atomic.get sleep_b)

let test_effect_finally_runs_on_eio_cancellation () =
  with_test_clock @@ fun sw _clock rt ->
  let finalized = ref false in
  let cancel_ctx = ref None in
  let never, _resolver = Eio.Promise.create () in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.await never)
          |> Effect.finally (Effect.sync (fun () -> finalized := true))))
  in
  wait_until (fun () -> Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  await_cancelled promise;
  Alcotest.(check bool) "cleanup ran" true !finalized

let test_effect_finally_cleanup_failure_during_eio_cancellation_is_diagnostic () =
  with_test_clock @@ fun sw _clock rt ->
  let finalized = ref false in
  let cancel_ctx = ref None in
  let never, _resolver = Eio.Promise.create () in
  let promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt
          (Effect.sync (fun () -> Eio.Promise.await never)
          |> Effect.finally
               (Effect.sync (fun () -> finalized := true)
               |> Effect.bind (fun () -> Effect.fail `Cleanup))))
  in
  wait_until (fun () -> Option.is_some !cancel_ctx);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn promise with
  | Exit.Error
      (Cause.Suppressed
        {
          primary = Cause.Interrupt _;
          finalizer = Cause.Finalizer.Fail { error = _; rendered };
        }) when String.equal rendered "<typed failure>" ->
      ()
  | Exit.Ok _ -> Alcotest.fail "expected cancellation diagnostic failure"
  | Exit.Error cause ->
      Alcotest.failf "expected suppressed interrupt cleanup failure, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause);
  Alcotest.(check bool) "cleanup ran" true !finalized

let test_runtime_run_propagates_eio_cancellation () =
  with_test_clock @@ fun _sw _clock rt ->
  let cancelled = Failure "runtime cancelled" in
  let raised_cancelled = ref false in
  Eio.Cancel.sub @@ fun ctx ->
  Eio.Cancel.cancel ctx cancelled;
  (match Runtime.run rt (Effect.delay (Duration.ms 1) Effect.unit) with
  | Exit.Ok () -> Alcotest.fail "cancelled run returned Ok"
  | Exit.Error cause ->
      Alcotest.failf "cancelled run returned %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | exception Eio.Cancel.Cancelled actual when actual == cancelled ->
      raised_cancelled := true);
  Alcotest.(check bool) "raised Cancelled" true !raised_cancelled

let check_owner_domain owner label =
  Alcotest.(check bool) label true (Domain.self () = owner)

let test_eio_runtime_contract_callbacks_stay_on_owner_domain () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let owner = Domain.self () in
  let contract = Runtime_contract.of_runtime (Eta_eio.runtime ~sw ~clock) in
  let expect_owner label actual =
    Alcotest.(check bool) label true (actual = owner)
  in
  contract.protect (fun () -> check_owner_domain owner "protect callback");
  contract.run_scope ~name:"same-domain conformance" (fun child_scope ->
      check_owner_domain owner "run_scope callback";
      let promise, resolver = contract.create_promise () in
      contract.fork child_scope (fun () ->
          check_owner_domain owner "fork callback";
          contract.resolve_promise resolver (Domain.self ()));
      expect_owner "promise await resumed on owner"
        (contract.await_promise promise);
      let stream = contract.create_stream 1 in
      contract.fork child_scope (fun () ->
          check_owner_domain owner "stream producer callback";
          contract.stream_add stream (Domain.self ()));
      expect_owner "stream take resumed on owner"
        (contract.stream_take stream);
      contract.stream_add stream (Domain.self ());
      expect_owner "stream take_nonblocking stayed on owner"
        (Option.get (contract.stream_take_nonblocking stream)));
  let daemon_promise, daemon_resolver = contract.create_promise () in
  contract.fork_daemon contract.root_scope (fun () ->
      check_owner_domain owner "daemon callback";
      contract.resolve_promise daemon_resolver (Domain.self ());
      `Stop_daemon);
  expect_owner "daemon promise resolved on owner"
    (contract.await_promise daemon_promise);
  let cancelled = Failure "same-domain cancellation" in
  let cancellation_observed = ref false in
  contract.cancel_sub (fun ctx ->
      check_owner_domain owner "cancel_sub callback";
      contract.cancel ctx cancelled;
      try
        contract.check ();
        Alcotest.fail "expected cancellation checkpoint"
      with exn -> (
        check_owner_domain owner "cancellation observed on owner";
        match contract.cancellation_reason exn with
        | Some reason when reason == cancelled ->
            cancellation_observed := true
        | Some reason ->
            Alcotest.failf "unexpected cancellation reason: %s"
              (Printexc.to_string reason)
        | None -> raise exn));
  Alcotest.(check bool)
    "cancellation reason observed" true !cancellation_observed;
  let local = Runtime_contract.create_local () in
  contract.local_with_binding local 42 (fun () ->
      check_owner_domain owner "local callback";
      Alcotest.(check (option int))
        "local binding" (Some 42) (contract.local_get local));
  let cross_domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"]
       [@alert "-unsafe_multidomain"])
      (fun () ->
        try Ok (contract.yield ())
        with Invalid_argument message -> Error message)
  in
  match Domain.join cross_domain with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "contract accepted cross-domain use"

let test_effect_timeout_cancellation_stays_on_owner_domain () =
  with_test_clock @@ fun sw clock rt ->
  let owner = Domain.self () in
  let finalizer_domain = ref None in
  let body =
    Effect.delay (Duration.ms 1_000) Effect.unit
    |> Effect.finally
         (Effect.sync (fun () -> finalizer_domain := Some (Domain.self ())))
  in
  let promise = fork_run sw rt (Effect.timeout (Duration.ms 1) body) in
  wait_for_sleepers clock 2;
  Test_clock.adjust clock (Duration.ms 1);
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Fail `Timeout) ->
      Alcotest.(check (option bool))
        "timeout finalizer ran on owner" (Some true)
        (Option.map (fun domain -> domain = owner) !finalizer_domain)
  | Exit.Error cause ->
      Alcotest.failf "expected timeout, got %a"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause
  | Exit.Ok () -> Alcotest.fail "expected timeout"

let test_effect_catch_preserves_concurrent_interrupt () =
  with_test_clock @@ fun sw _clock rt ->
  let handler_ran = ref false in
  let go, release = Eio.Promise.create () in
  let ready = Eio.Stream.create 2 in
  let wait name =
    Effect.sync (fun () ->
        Eio.Stream.add ready name;
        Eio.Promise.await go)
  in
  let typed = wait "typed" |> Effect.bind (fun () -> Effect.fail "typed") in
  let interrupt =
    wait "interrupt"
    |> Effect.bind (fun () ->
           Effect.sync (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "cancel"))))
  in
  let eff =
    Effect.all [ typed; interrupt ]
    |> Effect.bind_error (fun (_ : string) ->
           Effect.sync (fun () -> handler_ran := true)
           |> Effect.map (fun () -> [ () ]))
  in
  let promise = fork_run sw rt eff in
  ignore (Eio.Stream.take ready : string);
  ignore (Eio.Stream.take ready : string);
  Eio.Promise.resolve release ();
  match Eio.Promise.await promise with
  | Exit.Error (Cause.Interrupt None) ->
      Alcotest.(check bool)
        "handler skipped because interrupt keeps eff failed" false
        !handler_ran
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent interrupt, got %a"
        (Cause.pp Format.pp_print_string) cause
  | Exit.Ok _ -> Alcotest.fail "catch swallowed concurrent interrupt"

(* ---------------------------------------------------------------- *)
(* Stack-safety regression corpus (DX-E35)                           *)
(* ---------------------------------------------------------------- *)

(* Promoted from the DX-E35 boundary probe; see
   .scratch/research/dx/e35/probe/RESULTS.md and report.md. The pinned
   contract: the interpreter completes these compositions at depth 1M
   under documented default runtime configurations on shipped
   substrates — native/bytecode with the default OCaml [stack_limit]
   (134,217,728 words = 1 GiB on 64-bit, measured on 5.4.1 and
   5.2.0+ox) and js_of_ocaml --effects=cps. The guarantee is
   configuration-dependent, not intrinsic: a user-selected
   OCAMLRUNPARAM=l=<words> lowers the native bound and reopens
   exhaustion; non-CPS js_of_ocaml is excluded by eta_jsoo.mli's own
   --effects=cps requirement; a future bounded-stack substrate reopens
   the question. Every check verifies the full semantic result — exact
   value, exact execution count, exact handler count, every cause leaf
   against its index — so skipped or reordered work fails as surely as
   a stack overflow. *)

let test_stack_safety_dynamic_bind () =
  with_test_clock @@ fun _sw _clock rt ->
  let depth = 1_000_000 in
  let rec next remaining value =
    if remaining = 0 then Effect.pure value
    else
      Effect.bind
        (fun value -> next (remaining - 1) (value + 1))
        (Effect.pure value)
  in
  match Runtime.run rt (next depth 0) with
  | Exit.Ok value -> Alcotest.(check int) "every bind evaluated" depth value
  | Exit.Error cause ->
      Alcotest.failf "deep dynamic bind chain failed: %a"
        (Cause.pp Format.pp_print_string)
        cause

let test_stack_safety_static_map () =
  with_test_clock @@ fun _sw _clock rt ->
  let depth = 1_000_000 in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.map (fun value -> value + 1) acc)
  in
  match Runtime.run rt (build depth (Effect.pure 0)) with
  | Exit.Ok value -> Alcotest.(check int) "every map applied" depth value
  | Exit.Error cause ->
      Alcotest.failf "deep static map nesting failed: %a"
        (Cause.pp Format.pp_print_string)
        cause

let test_stack_safety_concat () =
  with_test_clock @@ fun _sw _clock rt ->
  let depth = 1_000_000 in
  let executed = ref 0 in
  let rec build remaining acc =
    if remaining = 0 then acc
    else
      build (remaining - 1)
        (Effect.sync (fun () -> incr executed) :: acc)
  in
  match Runtime.run rt (Effect.concat (build depth [])) with
  | Exit.Ok () ->
      Alcotest.(check int) "every concat effect executed" depth !executed
  | Exit.Error cause ->
      Alcotest.failf "deep concat failed: %a"
        (Cause.pp Format.pp_print_string)
        cause

let test_stack_safety_bind_error () =
  with_test_clock @@ fun _sw _clock rt ->
  let depth = 1_000_000 in
  let handled = ref 0 in
  let recover (_ : string) =
    incr handled;
    Effect.fail "boom"
  in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.bind_error recover acc)
  in
  match Runtime.run rt (build depth (Effect.fail "boom")) with
  | Exit.Error (Cause.Fail "boom") ->
      Alcotest.(check int) "every recovery level ran" depth !handled
  | Exit.Error cause ->
      Alcotest.failf "deep bind_error nesting failed: %a"
        (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.fail "recovery chain lost the typed failure"

let test_stack_safety_deep_cause_trees () =
  let depth = 1_000_000 in
  let check name combine =
    let cause = ref (Cause.fail 0) in
    for value = 1 to depth do
      cause := combine [ !cause; Cause.fail value ]
    done;
    let mismatches = ref 0 in
    let rec check_leaf index = function
      | [] ->
          Alcotest.(check int) (name ^ " leaf count") (depth + 1) index
      | leaf :: rest ->
          if leaf <> index then incr mismatches;
          check_leaf (index + 1) rest
    in
    check_leaf 0 (Cause.failures !cause);
    Alcotest.(check int)
      (name ^ " every leaf matches its index") 0 !mismatches
  in
  check "sequential" Cause.sequential;
  check "concurrent" Cause.concurrent
