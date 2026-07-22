open Eta

module type Backend = sig
  val run :
    ('a, 'err) Effect.t -> on_result:(('a, 'err) Exit.t -> unit) -> unit

  val complete : done_:(unit -> unit) -> (unit -> unit) -> unit
  val fail : string -> 'a
end

module Make (B : Backend) = struct
  let pp_hidden fmt _ = Format.pp_print_string fmt "<async-error>"

  let failf fmt = Printf.ksprintf B.fail fmt

  let expect_ok_int expected = function
    | Exit.Ok actual when actual = expected -> ()
    | Exit.Ok actual -> failf "expected Ok %d, got Ok %d" expected actual
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "expected Ok %d, got %a" expected
             (Cause.pp pp_hidden) cause)

  let expect_die = function
    | Exit.Error (Cause.Die _) -> ()
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "expected Die, got %a" (Cause.pp pp_hidden) cause)
    | Exit.Ok _ -> B.fail "expected Die, got Ok"

  let expect_interrupt = function
    | Exit.Error cause when Cause.is_interrupt_only cause -> ()
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "expected interruption, got %a"
             (Cause.pp pp_hidden) cause)
    | Exit.Ok _ -> B.fail "expected interruption, got Ok"

  let run done_ eff check =
    B.run eff ~on_result:(fun result ->
        B.complete ~done_ (fun () -> check result))

  let rec wait_until ?(attempts = 200) label predicate =
    if predicate () then Effect.unit
    else if attempts = 0 then
      Effect.die_message ("Effect.async test wait timed out: " ^ label)
    else
      Effect.bind
        (fun () -> wait_until ~attempts:(attempts - 1) label predicate)
        Effect.yield

  let install_cancel_handle slot eff =
    Effect.Expert.make ~capabilities:[ `Concurrency ] ~inherit_:eff
      ~leaf_name:"test.async.cancel-handle" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
    slot := Some (fun () -> contract.Runtime_contract.cancel cancel_context Exit);
    Effect.Expert.eval context eff

  let call_cancel = function
    | Some cancel -> cancel ()
    | None -> B.fail "Effect.async test cancel handle was not installed"

  let test_one_shot_first_resolution_wins done_ =
    let resume_calls = ref 0 in
    let eff =
      Effect.async ~register:(fun resume ->
          incr resume_calls;
          resume (Exit.Ok 11);
          incr resume_calls;
          resume (Exit.Ok 22);
          incr resume_calls;
          resume (Exit.Error (Cause.Fail `Late));
          None)
    in
    run done_ eff (fun exit ->
        expect_ok_int 11 exit;
        if !resume_calls <> 3 then
          failf "expected three callback attempts, got %d" !resume_calls)

  let test_canceler_runs_once_on_interruption done_ =
    let cancel_handle = ref None in
    let registered = ref false in
    let canceler_calls = ref 0 in
    let async =
      Effect.async ~register:(fun _resume ->
          registered := true;
          Some (Effect.sync (fun () -> incr canceler_calls)))
    in
    let target = install_cancel_handle cancel_handle (Effect.to_exit async) in
    let controller =
      Effect.bind
        (fun () ->
          Effect.sync (fun () ->
              call_cancel !cancel_handle;
              call_cancel !cancel_handle))
        (wait_until "registration" (fun () -> !registered))
    in
    run done_ (Effect.par target controller) (function
      | Exit.Ok (target_exit, ()) ->
          expect_interrupt target_exit;
          if !canceler_calls <> 1 then
            failf "expected canceler once, got %d" !canceler_calls
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "cancellation program failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_canceler_uninterruptible_under_second_interrupt done_ =
    let cancel_handle = ref None in
    let registered = ref false in
    let canceler_started = ref false in
    let canceler_released = ref false in
    let canceler_finished = ref false in
    let canceler_calls = ref 0 in
    let canceler =
      Effect.bind
        (fun () ->
          Effect.bind
            (fun () ->
              Effect.sync (fun () -> canceler_finished := true))
            (wait_until "canceler release" (fun () -> !canceler_released)))
        (Effect.sync (fun () ->
             incr canceler_calls;
             canceler_started := true))
    in
    let async =
      Effect.async ~register:(fun _resume ->
          registered := true;
          Some canceler)
    in
    let target = install_cancel_handle cancel_handle (Effect.to_exit async) in
    let controller =
      Effect.bind
        (fun () ->
          Effect.bind
            (fun () ->
              Effect.bind
                (fun () ->
                  Effect.sync (fun () -> canceler_released := true))
                (Effect.sync (fun () -> call_cancel !cancel_handle)))
            (wait_until "canceler start" (fun () -> !canceler_started)))
        (Effect.bind
           (fun () -> Effect.sync (fun () -> call_cancel !cancel_handle))
           (wait_until "registration" (fun () -> !registered)))
    in
    run done_ (Effect.par target controller) (function
      | Exit.Ok (target_exit, ()) ->
          expect_interrupt target_exit;
          if not !canceler_finished then
            B.fail "second interruption preempted the canceler";
          if !canceler_calls <> 1 then
            failf "expected canceler once, got %d" !canceler_calls
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "protected canceler program failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_canceler_never_after_resolution done_ =
    let cancel_handle = ref None in
    let canceler_calls = ref 0 in
    let async =
      Effect.async ~register:(fun resume ->
          resume (Exit.Ok 17);
          call_cancel !cancel_handle;
          Some (Effect.sync (fun () -> incr canceler_calls)))
    in
    run done_ (install_cancel_handle cancel_handle async) (fun exit ->
        expect_ok_int 17 exit;
        if !canceler_calls <> 0 then
          failf "canceler ran %d times after resolution" !canceler_calls)

  let test_register_raise_becomes_die done_ =
    let eff =
      Effect.async ~register:(fun _resume ->
          raise (Failure "async register boom"))
    in
    run done_ eff expect_die

  let test_register_raise_wins_after_synchronous_resume done_ =
    let eff =
      Effect.async ~register:(fun resume ->
          resume (Exit.Ok 31);
          raise (Failure "async register failed after resume"))
    in
    run done_ eff expect_die

  let test_canceler_failure_is_suppressed_under_interruption done_ =
    let cancel_handle = ref None in
    let registered = ref false in
    let async =
      Effect.async ~register:(fun _resume ->
          registered := true;
          Some (Effect.fail `Cleanup_failed))
    in
    let target = install_cancel_handle cancel_handle (Effect.to_exit async) in
    let controller =
      Effect.bind
        (fun () -> Effect.sync (fun () -> call_cancel !cancel_handle))
        (wait_until "registration" (fun () -> !registered))
    in
    run done_ (Effect.par target controller) (function
      | Exit.Ok
          ( Exit.Error
              (Cause.Suppressed
                { primary; finalizer = Cause.Finalizer.Fail _ }),
            () )
        when Cause.is_interrupt_only primary ->
          ()
      | Exit.Ok (_target_exit, ()) ->
          B.fail "expected suppressed canceler failure"
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "canceler failure program failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_canceler_defect_is_suppressed_under_interruption done_ =
    let cancel_handle = ref None in
    let registered = ref false in
    let async =
      Effect.async ~register:(fun _resume ->
          registered := true;
          Some (Effect.die_message "canceler defect"))
    in
    let target = install_cancel_handle cancel_handle (Effect.to_exit async) in
    let controller =
      Effect.bind
        (fun () -> Effect.sync (fun () -> call_cancel !cancel_handle))
        (wait_until "registration" (fun () -> !registered))
    in
    run done_ (Effect.par target controller) (function
      | Exit.Ok
          ( Exit.Error
              (Cause.Suppressed
                { primary; finalizer = Cause.Finalizer.Die _ }),
            () )
        when Cause.is_interrupt_only primary ->
          ()
      | Exit.Ok (_target_exit, ()) ->
          B.fail "expected suppressed canceler defect"
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "canceler defect program failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_synchronous_resolution_does_not_deadlock done_ =
    let eff =
      Effect.async ~register:(fun resume ->
          resume (Exit.Ok 29);
          None)
    in
    run done_ eff (expect_ok_int 29)

  let seeded_case seed =
    let cancel_handle = ref None in
    let callback = ref None in
    let registered = ref false in
    let canceler_calls = ref 0 in
    let mode = seed mod 3 in
    let async =
      Effect.async ~register:(fun resume ->
          callback := Some resume;
          registered := true;
          if mode = 0 then resume (Exit.Ok seed);
          Some (Effect.sync (fun () -> incr canceler_calls)))
    in
    let target = install_cancel_handle cancel_handle (Effect.to_exit async) in
    let call_resume () =
      match !callback with
      | Some resume -> resume (Exit.Ok seed)
      | None -> B.fail "Effect.async test callback was not installed"
    in
    let controller =
      Effect.bind
        (fun () ->
          match mode with
          | 0 -> Effect.unit
          | 1 ->
              Effect.sync (fun () ->
                  call_resume ();
                  call_cancel !cancel_handle)
          | _ ->
              Effect.bind
                (fun () -> Effect.sync call_resume)
                (Effect.bind
                   (fun () ->
                     wait_until "seeded canceler" (fun () -> !canceler_calls = 1))
                   (Effect.sync (fun () -> call_cancel !cancel_handle))))
        (wait_until "seeded registration" (fun () -> !registered))
    in
    Effect.map
      (fun (target_exit, ()) -> (seed, mode, target_exit, !canceler_calls))
      (Effect.par target controller)

  let rec seeded_cases acc = function
    | [] -> Effect.pure (List.rev acc)
    | seed :: rest ->
        Effect.bind
          (fun result -> seeded_cases (result :: acc) rest)
          (seeded_case seed)

  let test_no_lost_wakeup_under_seeded_register_cancel_races done_ =
    let seeds = [ 0; 7; 2; 9; 4; 5; 12; 13; 8; 18; 10; 11 ] in
    run done_ (seeded_cases [] seeds) (function
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "seeded async program failed: %a"
               (Cause.pp pp_hidden) cause)
      | Exit.Ok results ->
          List.iter
            (fun (seed, mode, target_exit, canceler_calls) ->
              if mode = 2 then (
                expect_interrupt target_exit;
                if canceler_calls <> 1 then
                  failf "seed %d: expected one canceler, got %d" seed
                    canceler_calls)
              else (
                expect_ok_int seed target_exit;
                if canceler_calls <> 0 then
                  failf "seed %d: resolution ran canceler %d times" seed
                    canceler_calls))
            results)

  let tests =
    [
      ("async one-shot first resolution wins", test_one_shot_first_resolution_wins);
      ( "async canceler runs once on interruption",
        test_canceler_runs_once_on_interruption );
      ( "async canceler is uninterruptible under second interrupt",
        test_canceler_uninterruptible_under_second_interrupt );
      ( "async canceler never runs after resolution",
        test_canceler_never_after_resolution );
      ("async register raise becomes die", test_register_raise_becomes_die);
      ( "async register raise wins after synchronous resume",
        test_register_raise_wins_after_synchronous_resume );
      ( "async canceler failure is suppressed under interruption",
        test_canceler_failure_is_suppressed_under_interruption );
      ( "async canceler defect is suppressed under interruption",
        test_canceler_defect_is_suppressed_under_interruption );
      ( "async synchronous resolution does not deadlock",
        test_synchronous_resolution_does_not_deadlock );
      ( "async no lost wakeup under seeded register/cancel races",
        test_no_lost_wakeup_under_seeded_register_cancel_races );
    ]
end
