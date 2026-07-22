open Eta

module type Backend = sig
  val run :
    ('a, 'err) Effect.t -> on_result:(('a, 'err) Exit.t -> unit) -> unit

  val complete : done_:(unit -> unit) -> (unit -> unit) -> unit
  val fail : string -> 'a
end

module Make (B : Backend) = struct
  let pp_hidden fmt _ = Format.pp_print_string fmt "<promise-error>"
  let failf fmt = Printf.ksprintf B.fail fmt

  let run done_ eff check =
    B.run eff ~on_result:(fun result ->
        B.complete ~done_ (fun () -> check result))

  let expect_program_ok = function
    | Exit.Ok value -> value
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "promise program failed: %a" (Cause.pp pp_hidden)
             cause)

  let expect_interrupt = function
    | Exit.Error cause when Cause.is_interrupt_only cause -> ()
    | Exit.Error cause ->
        B.fail
          (Format.asprintf "expected interruption, got %a"
             (Cause.pp pp_hidden) cause)
    | Exit.Ok _ -> B.fail "expected interruption, got Ok"

  let rec wait_until ?(attempts = 200) label predicate =
    if predicate () then Effect.unit
    else if attempts = 0 then
      Effect.die_message ("Promise test wait timed out: " ^ label)
    else
      Effect.bind
        (fun () -> wait_until ~attempts:(attempts - 1) label predicate)
        Effect.yield

  let install_cancel_handle slot eff =
    Effect.Expert.make ~capabilities:[ `Concurrency ] ~inherit_:eff
      ~leaf_name:"test.promise.cancel-handle" @@ fun context ->
    let contract = Effect.Expert.contract context in
    contract.Runtime_contract.cancel_sub @@ fun cancel_context ->
    slot := Some (fun () -> contract.Runtime_contract.cancel cancel_context Exit);
    Effect.Expert.eval context eff

  let call_cancel = function
    | Some cancel -> cancel ()
    | None -> B.fail "Promise test cancel handle was not installed"

  let test_one_shot_first_exit_preserved done_ =
    let promise : (int, [ `Late ]) Promise.t = Promise.create () in
    let open Syntax in
    let program =
      let* first = Promise.resolve promise (Exit.Ok 11) in
      let* second = Promise.resolve promise (Exit.Error (Cause.Fail `Late)) in
      let+ value = Promise.await promise in
      (first, second, value)
    in
    run done_ program (fun exit ->
        match expect_program_ok exit with
        | true, false, 11 -> ()
        | first, second, value ->
            failf "expected (true, false, 11), got (%b, %b, %d)" first second
              value)

  let test_three_waiters_wake done_ =
    let promise : (int, string) Promise.t = Promise.create () in
    let started = ref 0 in
    let open Syntax in
    let waiter =
      let* () = Effect.sync (fun () -> incr started) in
      Promise.await promise
    in
    let controller =
      let* () = wait_until "three waiters" (fun () -> !started = 3) in
      Promise.resolve promise (Exit.Ok 7)
    in
    let program = Effect.par (Effect.all [ waiter; waiter; waiter ]) controller in
    run done_ program (fun exit ->
        match expect_program_ok exit with
        | [ 7; 7; 7 ], true -> ()
        | values, won ->
            failf "expected three 7s and true, got %d values and %b"
              (List.length values) won)

  let test_cancelled_waiter_does_not_consume done_ =
    let promise : (int, [ `Promise_error ]) Promise.t = Promise.create () in
    let cancel_handle = ref None in
    let started = ref 0 in
    let cancelled_exit = ref None in
    let open Syntax in
    let cancelled_waiter =
      let* () = Effect.sync (fun () -> incr started) in
      let* exit =
        install_cancel_handle cancel_handle
          (Effect.to_exit (Promise.await promise))
      in
      Effect.sync (fun () -> cancelled_exit := Some exit)
    in
    let live_waiter =
      let* () = Effect.sync (fun () -> incr started) in
      Promise.await promise
    in
    let controller =
      let* () =
        wait_until "both waiters and cancel handle" (fun () ->
            !started = 2 && Option.is_some !cancel_handle)
      in
      let* () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      let* () =
        wait_until "cancelled waiter cleanup" (fun () ->
            Option.is_some !cancelled_exit)
      in
      Promise.resolve promise (Exit.Ok 23)
    in
    let program =
      let* (((), live), won) =
        Effect.par (Effect.par cancelled_waiter live_waiter) controller
      in
      let+ later = Promise.await promise in
      (live, won, later)
    in
    run done_ program (fun exit ->
        (match !cancelled_exit with
        | Some cancelled -> expect_interrupt cancelled
        | None -> B.fail "cancelled waiter did not finish");
        match expect_program_ok exit with
        | 23, true, 23 -> ()
        | live, won, later ->
            failf "expected (23, true, 23), got (%d, %b, %d)" live won later)

  let test_boundary_close_interrupts_waiter done_ =
    let promise : (int, string) Promise.t = Promise.create () in
    let started = ref false in
    let cleanup_ran = ref false in
    let open Syntax in
    let background =
      Effect.acquire_release
        ~acquire:(Effect.sync (fun () -> started := true))
        ~release:(fun () -> Effect.sync (fun () -> cleanup_ran := true))
      |> Effect.bind (fun () -> Effect.discard (Promise.await promise))
    in
    let program =
      let* () =
        Effect.with_background background (fun () ->
            wait_until "background promise waiter" (fun () -> !started))
      in
      let* cleaned = Effect.sync (fun () -> !cleanup_ran) in
      let* won = Promise.resolve promise (Exit.Ok 31) in
      let+ later = Promise.await promise in
      (cleaned, won, later)
    in
    run done_ program (fun exit ->
        match expect_program_ok exit with
        | true, true, 31 -> ()
        | cleaned, won, later ->
            failf "expected (true, true, 31), got (%b, %b, %d)" cleaned won
              later)

  let test_resolution_before_cancellation_still_delivers done_ =
    let promise : (int, string) Promise.t = Promise.create () in
    let cancel_handle = ref None in
    let started = ref false in
    let open Syntax in
    let waiter =
      install_cancel_handle cancel_handle
        (let* () = Effect.sync (fun () -> started := true) in
         Promise.await promise)
    in
    let controller =
      let* () =
        wait_until "resolution race waiter" (fun () ->
            !started && Option.is_some !cancel_handle)
      in
      let* won = Promise.resolve promise (Exit.Ok 41) in
      let+ () = Effect.sync (fun () -> call_cancel !cancel_handle) in
      won
    in
    run done_ (Effect.par waiter controller) (fun exit ->
        match expect_program_ok exit with
        | 41, true -> ()
        | value, won ->
            failf "expected resolution race (41, true), got (%d, %b)" value won)

  let test_error_and_defect_exit_fidelity done_ =
    let typed : (int, [ `Typed ]) Promise.t = Promise.create () in
    let defect : (int, string) Promise.t = Promise.create () in
    let started = ref 0 in
    let defecting : (int, string) Effect.t =
      Effect.die_message "promise defect"
    in
    let open Syntax in
    let typed_exit = Exit.Error (Cause.Fail `Typed) in
    let typed_waiter =
      let* () = Effect.sync (fun () -> incr started) in
      Effect.to_exit (Promise.await typed)
    in
    let defect_waiter =
      let* () = Effect.sync (fun () -> incr started) in
      Effect.to_exit (Promise.await defect)
    in
    let controller =
      let* () =
        wait_until "parked exit-fidelity waiters" (fun () -> !started = 2)
      in
      let* typed_won = Promise.resolve typed typed_exit in
      let* defect_exit = Effect.to_exit defecting in
      let* defect_won = Promise.resolve defect defect_exit in
      Effect.pure (typed_won, defect_won, defect_exit)
    in
    let program =
      let+ (typed_observed, defect_observed),
           (typed_won, defect_won, defect_exit) =
        Effect.par (Effect.par typed_waiter defect_waiter) controller
      in
      ( typed_won,
        typed_exit,
        typed_observed,
        defect_won,
        defect_exit,
        defect_observed )
    in
    run done_ program (fun exit ->
        let ( typed_won,
              typed_exit,
              typed_observed,
              defect_won,
              defect_exit,
              defect_observed ) =
          expect_program_ok exit
        in
        if not typed_won then B.fail "typed failure resolution did not win";
        if typed_exit != typed_observed then
          B.fail "typed failure Exit.t was not delivered faithfully";
        if not defect_won then B.fail "defect resolution did not win";
        if defect_exit != defect_observed then
          B.fail "defect Exit.t was not delivered faithfully";
        match defect_observed with
        | Exit.Error (Cause.Die _) -> ()
        | Exit.Error cause ->
            B.fail
              (Format.asprintf "expected defect, got %a" (Cause.pp pp_hidden)
                 cause)
        | Exit.Ok _ -> B.fail "expected defect, got Ok")

  let tests =
    [
      ( "promise one-shot first exit preserved",
        test_one_shot_first_exit_preserved );
      ("promise three waiters wake", test_three_waiters_wake);
      ( "promise cancelled waiter does not consume",
        test_cancelled_waiter_does_not_consume );
      ( "promise boundary close interrupts waiter",
        test_boundary_close_interrupts_waiter );
      ( "promise resolution before cancellation still delivers",
        test_resolution_before_cancellation_still_delivers );
      ( "promise error and defect exit fidelity",
        test_error_and_defect_exit_fidelity );
    ]
end
