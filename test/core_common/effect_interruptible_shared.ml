open Eta

module type Backend = sig
  val run :
    ('a, 'err) Effect.t -> on_result:(('a, 'err) Exit.t -> unit) -> unit

  val complete : done_:(unit -> unit) -> (unit -> unit) -> unit
  val fail : string -> 'a
end

module Make (B : Backend) = struct
  let pp_hidden fmt _ = Format.pp_print_string fmt "<interruptible-error>"
  let failf fmt = Printf.ksprintf B.fail fmt
  let ( let* ) eff f = Effect.bind f eff
  let ( let+ ) eff f = Effect.map f eff

  let run done_ eff check =
    B.run eff ~on_result:(fun result ->
        B.complete ~done_ (fun () -> check result))

  let rec pause = function
    | 0 -> Effect.unit
    | count ->
        let* () = Effect.yield in
        pause (count - 1)

  let rec wait_until ?(attempts = 500) label predicate =
    if predicate () then Effect.unit
    else if attempts = 0 then
      Effect.die_message ("Effect.interruptible test timed out: " ^ label)
    else
      let* () = Effect.yield in
      wait_until ~attempts:(attempts - 1) label predicate

  let install_cancel_handle slot eff =
    Effect.Expert.make ~capabilities:[ `Concurrency ] ~inherit_:eff
      ~leaf_name:"test.interruptible.cancel-handle" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
    slot := Some (fun () -> contract.Runtime_contract.cancel cancel_context Exit);
    Effect.Expert.eval context eff

  let call_cancel = function
    | Some cancel -> cancel ()
    | None -> B.fail "Effect.interruptible test cancel handle was not installed"

  let expect_interrupt = function
    | Exit.Error (Cause.Interrupt _) -> ()
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "expected one interruption, got %a"
             (Cause.pp pp_hidden) cause)
    | Exit.Ok _ -> B.fail "expected interruption, got Ok"

  let expect_target_interrupt = function
    | Exit.Ok (target_exit, ()) -> expect_interrupt target_exit
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "cancellation controller failed: %a"
             (Cause.pp pp_hidden) cause)

  let test_outside_mask_is_identity done_ =
    let values = List.init 17 (fun index -> index - 8) in
    let program =
      Effect.all
        (List.map
           (fun value -> Effect.interruptible (Effect.pure value))
           values)
    in
    run done_ program (function
      | Exit.Ok actual when actual = values -> ()
      | Exit.Ok _ -> B.fail "interruptible changed values outside a mask"
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "identity program failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_pending_cancellation_raises_at_restore_entry done_ =
    let cancel_handle = ref None in
    let mask_entered = ref false in
    let cancelled = ref false in
    let target =
      let body =
        let* () = Effect.sync (fun () -> mask_entered := true) in
        let* () = wait_until "pending cancellation" (fun () -> !cancelled) in
        Effect.interruptible Effect.never
      in
      install_cancel_handle cancel_handle
        (Effect.to_exit (Effect.uninterruptible body))
    in
    let controller =
      let* () = wait_until "mask entry" (fun () -> !mask_entered) in
      Effect.sync (fun () ->
          call_cancel !cancel_handle;
          cancelled := true)
    in
    run done_ (Effect.par target controller) expect_target_interrupt

  let test_cancel_during_restored_block_wakes_waiter done_ =
    let cancel_handle = ref None in
    let blocked = ref false in
    let target =
      let restored =
        let* () = Effect.sync (fun () -> blocked := true) in
        Effect.never
      in
      install_cancel_handle cancel_handle
        (Effect.to_exit
           (Effect.uninterruptible (Effect.interruptible restored)))
    in
    let controller =
      let* () = wait_until "restored block" (fun () -> !blocked) in
      Effect.sync (fun () -> call_cancel !cancel_handle)
    in
    run done_ (Effect.par target controller) expect_target_interrupt

  let test_repeated_interruptible_in_restored_region_is_identity done_ =
    let cancel_handle = ref None in
    let blocked = ref false in
    let target =
      let restored =
        let* () = Effect.sync (fun () -> blocked := true) in
        Effect.never
      in
      install_cancel_handle cancel_handle
        (Effect.to_exit
           (Effect.uninterruptible
              (Effect.interruptible (Effect.interruptible restored))))
    in
    let controller =
      let* () = wait_until "repeated restored block" (fun () -> !blocked) in
      Effect.sync (fun () -> call_cancel !cancel_handle)
    in
    run done_ (Effect.par target controller) expect_target_interrupt

  let test_cancel_at_restored_checkpoint_is_delivered done_ =
    let cancel_handle = ref None in
    let checkpoint_waiting = ref false in
    let target =
      let restored =
        let* () = Effect.sync (fun () -> checkpoint_waiting := true) in
        wait_until "checkpoint cancellation" (fun () -> false)
      in
      install_cancel_handle cancel_handle
        (Effect.to_exit
           (Effect.uninterruptible (Effect.interruptible restored)))
    in
    let controller =
      let* () = wait_until "checkpoint waiter" (fun () -> !checkpoint_waiting) in
      Effect.sync (fun () -> call_cancel !cancel_handle)
    in
    run done_ (Effect.par target controller) expect_target_interrupt

  let test_cancel_between_restore_and_exit_hits_success_boundary done_ =
    let cancel_handle = ref None in
    let returned_from_cancel = ref 0 in
    let restored_tail =
      Effect.sync (fun () ->
          call_cancel !cancel_handle;
          incr returned_from_cancel;
          42)
    in
    let target =
      install_cancel_handle cancel_handle
        (Effect.to_exit
           (Effect.uninterruptible (Effect.interruptible restored_tail)))
    in
    run done_ target (function
      | Exit.Ok target_exit ->
          expect_interrupt target_exit;
          if !returned_from_cancel <> 1 then
            failf "successful tail ran %d times" !returned_from_cancel
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "restore-exit boundary program failed: %a"
               (Cause.pp pp_hidden) cause))

  let entry_race_case target_pause controller_pause =
    let cancel_handle = ref None in
    let target =
      let* () = pause target_pause in
      Effect.uninterruptible (Effect.interruptible Effect.never)
      |> Effect.to_exit
      |> install_cancel_handle cancel_handle
    in
    let controller =
      let* () = wait_until "entry-race handle" (fun () -> Option.is_some !cancel_handle) in
      let* () = pause controller_pause in
      Effect.sync (fun () -> call_cancel !cancel_handle)
    in
    let+ target_exit, () = Effect.par target controller in
    (target_pause, controller_pause, target_exit)

  let rec entry_race_cases acc = function
    | [] -> Effect.pure (List.rev acc)
    | case :: rest ->
        let target_pause, controller_pause = case in
        let* result = entry_race_case target_pause controller_pause in
        entry_race_cases (result :: acc) rest

  let test_generated_cancel_mask_entry_races_lose_no_wakeup done_ =
    let cases =
      [ (0, 0); (1, 0); (0, 1); (2, 1); (1, 2); (3, 0); (0, 3); (3, 3) ]
    in
    run done_ (entry_race_cases [] cases) (function
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "generated entry races failed: %a"
               (Cause.pp pp_hidden) cause)
      | Exit.Ok results ->
          List.iter
            (fun (target_pause, controller_pause, target_exit) ->
              match target_exit with
              | Exit.Error (Cause.Interrupt _) -> ()
              | Exit.Error cause ->
                  B.fail
                    (Format.asprintf "entry race (%d,%d): expected interrupt, got %a"
                       target_pause controller_pause (Cause.pp pp_hidden) cause)
              | Exit.Ok _ ->
                  failf "entry race (%d,%d): cancellation was lost" target_pause
                    controller_pause)
            results)

  let mask_stack_case stacked =
    let cancel_handle = ref None in
    let body_started = ref false in
    let body_released = ref false in
    let body_finished = ref false in
    let observed_protected = ref false in
    let body =
      let* () = Effect.sync (fun () -> body_started := true) in
      let* () = wait_until "nested mask release" (fun () -> !body_released) in
      Effect.sync (fun () -> body_finished := true)
    in
    let masked =
      if stacked then
        Effect.uninterruptible
          (Effect.interruptible (Effect.uninterruptible body))
      else Effect.uninterruptible body
    in
    let target_body =
      let* () = masked in
      Effect.yield
    in
    let target =
      install_cancel_handle cancel_handle (Effect.to_exit target_body)
    in
    let controller =
      let* () = wait_until "nested mask body" (fun () -> !body_started) in
      let* () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      let* () = pause 3 in
      Effect.sync (fun () ->
          observed_protected := not !body_finished;
          body_released := true)
    in
    let+ target_exit, () = Effect.par target controller in
    (target_exit, !observed_protected, !body_finished)

  let test_mask_stack_law_inner_uninterruptible_wins done_ =
    let program =
      let* plain = mask_stack_case false in
      let+ stacked = mask_stack_case true in
      (plain, stacked)
    in
    run done_ program (function
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "mask-stack law failed: %a"
               (Cause.pp pp_hidden) cause)
      | Exit.Ok ((plain_exit, plain_protected, plain_finished),
                 (stacked_exit, stacked_protected, stacked_finished)) ->
          expect_interrupt plain_exit;
          expect_interrupt stacked_exit;
          if not (plain_protected && stacked_protected) then
            B.fail "inner uninterruptible region was cancelled while protected";
          if not (plain_finished && stacked_finished) then
            B.fail "protected mask-stack body did not finish")

  let test_nested_mask_innermost_restore_wins done_ =
    let inner_cancel_handle = ref None in
    let inner_blocked = ref false in
    let inner =
      let restored =
        let* () = Effect.sync (fun () -> inner_blocked := true) in
        Effect.never
      in
      install_cancel_handle inner_cancel_handle
        (Effect.uninterruptible (Effect.interruptible restored))
    in
    let target =
      Effect.uninterruptible (Effect.interruptible inner) |> Effect.to_exit
    in
    let controller =
      let* () = wait_until "inner restored block" (fun () -> !inner_blocked) in
      Effect.sync (fun () -> call_cancel !inner_cancel_handle)
    in
    run done_ (Effect.par target controller) expect_target_interrupt

  let test_competing_cancellation_sources_deliver_once done_ =
    let outer_cancel_handle = ref None in
    let inner_cancel_handle = ref None in
    let blocked = ref false in
    let finalizer_calls = ref 0 in
    let restored =
      let* () = Effect.sync (fun () -> blocked := true) in
      Effect.never
    in
    let target_body =
      Effect.finally
        (Effect.sync (fun () -> incr finalizer_calls))
        (Effect.interruptible restored)
      |> Effect.uninterruptible
    in
    let target =
      install_cancel_handle outer_cancel_handle
        (install_cancel_handle inner_cancel_handle (Effect.to_exit target_body))
    in
    let controller =
      let* () = wait_until "competing-cancel block" (fun () -> !blocked) in
      Effect.par
        (Effect.sync (fun () -> call_cancel !outer_cancel_handle))
        (Effect.sync (fun () -> call_cancel !inner_cancel_handle))
      |> Effect.discard
    in
    run done_ (Effect.par target controller) (fun result ->
        expect_target_interrupt result;
        if !finalizer_calls <> 1 then
          failf "competing cancellation ran finalizer %d times" !finalizer_calls)

  let test_finalizer_cannot_restore_enclosing_mask done_ =
    let cancel_handle = ref None in
    let body_blocked = ref false in
    let finalizer_started = ref false in
    let finalizer_released = ref false in
    let finalizer_finished = ref false in
    let cleanup =
      let body =
        let* () = Effect.sync (fun () -> finalizer_started := true) in
        let* () =
          wait_until "protected finalizer release" (fun () -> !finalizer_released)
        in
        Effect.sync (fun () -> finalizer_finished := true)
      in
      Effect.interruptible body
    in
    let source =
      let* () = Effect.sync (fun () -> body_blocked := true) in
      Effect.never
    in
    let target_body =
      Effect.finally cleanup (Effect.interruptible source)
      |> Effect.uninterruptible
    in
    let target =
      install_cancel_handle cancel_handle (Effect.to_exit target_body)
    in
    let controller =
      let* () = wait_until "finalizer source" (fun () -> !body_blocked) in
      let* () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      let* () = wait_until "finalizer start" (fun () -> !finalizer_started) in
      let* () = pause 3 in
      Effect.sync (fun () ->
          if !finalizer_finished then
            B.fail "finalizer escaped protection before release";
          finalizer_released := true)
    in
    run done_ (Effect.par target controller) (fun result ->
        expect_target_interrupt result;
        if not !finalizer_finished then
          B.fail "protected finalizer did not finish")

  let test_registered_finalizer_cannot_restore_enclosing_mask done_ =
    let cancel_handle = ref None in
    let body_blocked = ref false in
    let finalizer_started = ref false in
    let finalizer_released = ref false in
    let finalizer_finished = ref false in
    let release () =
      let body =
        let* () = Effect.sync (fun () -> finalizer_started := true) in
        let* () =
          wait_until "registered finalizer release" (fun () -> !finalizer_released)
        in
        Effect.sync (fun () -> finalizer_finished := true)
      in
      Effect.interruptible body
    in
    let source =
      let* () = Effect.sync (fun () -> body_blocked := true) in
      Effect.never
    in
    let target_body =
      Effect.with_scope
        (let* () = Effect.acquire_release ~acquire:Effect.unit ~release in
         Effect.interruptible source)
      |> Effect.uninterruptible
    in
    let target =
      install_cancel_handle cancel_handle (Effect.to_exit target_body)
    in
    let controller =
      let* () = wait_until "registered finalizer source" (fun () -> !body_blocked) in
      let* () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      let* () =
        wait_until "registered finalizer start" (fun () -> !finalizer_started)
      in
      let* () = pause 3 in
      Effect.sync (fun () ->
          if !finalizer_finished then
            B.fail "registered finalizer escaped protection before release";
          finalizer_released := true)
    in
    run done_ (Effect.par target controller) (fun result ->
        expect_target_interrupt result;
        if not !finalizer_finished then
          B.fail "protected registered finalizer did not finish")

  let test_mask_covers_forked_children done_ =
    let cancel_handle = ref None in
    let child_started = ref false in
    let child_released = ref false in
    let child_settled = ref false in
    let child_finished = ref false in
    let observed_masked = ref false in
    let child =
      let body =
        let* () = Effect.sync (fun () -> child_started := true) in
        let* () = wait_until "masked child release" (fun () -> !child_released) in
        Effect.sync (fun () -> child_finished := true)
      in
      Effect.finally (Effect.sync (fun () -> child_settled := true)) body
    in
    let target_body =
      let* _ = Effect.uninterruptible (Effect.par child Effect.unit) in
      Effect.yield
    in
    let target =
      install_cancel_handle cancel_handle (Effect.to_exit target_body)
    in
    let controller =
      let* () = wait_until "masked child start" (fun () -> !child_started) in
      let* () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      let* () = pause 3 in
      Effect.sync (fun () ->
          observed_masked := not !child_settled;
          child_released := true)
    in
    run done_ (Effect.par target controller) (fun result ->
        expect_target_interrupt result;
        if not !observed_masked then
          B.fail "child forked inside mask was interrupted by default";
        if not !child_finished then B.fail "masked child did not finish")

  let test_daemon_drops_restore_binding_after_mask done_ =
    let daemon_released = ref false in
    let daemon_result = ref None in
    let daemon =
      let* () = wait_until "masked daemon release" (fun () -> !daemon_released) in
      let* result = Effect.to_exit (Effect.interruptible (Effect.pure 42)) in
      Effect.sync (fun () -> daemon_result := Some result)
    in
    let program =
      let* () = Effect.uninterruptible (Effect.daemon daemon) in
      let* () = Effect.sync (fun () -> daemon_released := true) in
      let+ () =
        wait_until "masked daemon result" (fun () -> Option.is_some !daemon_result)
      in
      Option.get !daemon_result
    in
    run done_ program (function
      | Exit.Ok (Exit.Ok 42) -> ()
      | Exit.Ok (Exit.Ok value) -> failf "masked daemon returned %d" value
      | Exit.Ok (Exit.Error cause) ->
          B.fail
            (Format.asprintf "masked daemon retained restore binding: %a"
               (Cause.pp pp_hidden) cause)
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "masked daemon controller failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_daemon_drops_cleanup_forbidden_binding done_ =
    let daemon_cancel_handle = ref None in
    let daemon_blocked = ref false in
    let daemon_result = ref None in
    let restored =
      let* () = Effect.sync (fun () -> daemon_blocked := true) in
      wait_until ~attempts:50 "cleanup daemon cancellation" (fun () -> false)
    in
    let daemon =
      let target =
        Effect.uninterruptible (Effect.interruptible restored)
        |> Effect.to_exit
        |> install_cancel_handle daemon_cancel_handle
      in
      let* result = target in
      Effect.sync (fun () -> daemon_result := Some result)
    in
    let program =
      let* () =
        Effect.uninterruptible (Effect.finally (Effect.daemon daemon) Effect.unit)
      in
      let* () = wait_until "cleanup daemon block" (fun () -> !daemon_blocked) in
      let* () = Effect.sync (fun () -> call_cancel !daemon_cancel_handle) in
      let+ () =
        wait_until "cleanup daemon result" (fun () -> Option.is_some !daemon_result)
      in
      Option.get !daemon_result
    in
    run done_ program (function
      | Exit.Ok daemon_exit -> expect_interrupt daemon_exit
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "cleanup daemon controller failed: %a"
               (Cause.pp pp_hidden) cause))

  let test_forked_interruptible_child_preserves_fail_fast done_ =
    let program =
      Effect.uninterruptible
        (Effect.par (Effect.interruptible Effect.never) (Effect.fail `Boom))
    in
    run done_ program (function
      | Exit.Error (Cause.Fail `Boom) -> ()
      | Exit.Error cause ->
          B.fail
            (Format.asprintf "expected Fail Boom, got %a"
               (Cause.pp pp_hidden) cause)
      | Exit.Ok _ -> B.fail "forked interruptible child unexpectedly succeeded")

  let tests =
    [
      ("interruptible outside a mask is identity", test_outside_mask_is_identity);
      ( "interruptible pending cancellation raises at restore entry",
        test_pending_cancellation_raises_at_restore_entry );
      ( "interruptible cancel during restored block wakes waiter",
        test_cancel_during_restored_block_wakes_waiter );
      ( "repeated interruptible in restored region is identity",
        test_repeated_interruptible_in_restored_region_is_identity );
      ( "interruptible cancel at restored checkpoint is delivered",
        test_cancel_at_restored_checkpoint_is_delivered );
      ( "interruptible cancel between restore and exit hits successful boundary",
        test_cancel_between_restore_and_exit_hits_success_boundary );
      ( "interruptible generated cancel-mask-entry races lose no wakeup",
        test_generated_cancel_mask_entry_races_lose_no_wakeup );
      ( "interruptible mask-stack law inner uninterruptible wins",
        test_mask_stack_law_inner_uninterruptible_wins );
      ( "interruptible nested mask innermost restore wins",
        test_nested_mask_innermost_restore_wins );
      ( "interruptible competing cancellation sources deliver once",
        test_competing_cancellation_sources_deliver_once );
      ( "interruptible is forbidden in finalizers",
        test_finalizer_cannot_restore_enclosing_mask );
      ( "interruptible is forbidden in registered finalizers",
        test_registered_finalizer_cannot_restore_enclosing_mask );
      ( "forked interruptible child preserves fail-fast",
        test_forked_interruptible_child_preserves_fail_fast );
      ( "cancellation mask covers forked children",
        test_mask_covers_forked_children );
      ( "daemon drops restore binding after mask",
        test_daemon_drops_restore_binding_after_mask );
      ( "daemon drops cleanup-forbidden binding",
        test_daemon_drops_cleanup_forbidden_binding );
    ]
end
