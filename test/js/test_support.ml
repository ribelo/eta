let fail name message = failwith (name ^ ": " ^ message)

let check name condition =
  if not condition then fail name "check failed"

let check_equal_int name expected actual =
  if expected <> actual then
    fail name (Printf.sprintf "expected %d, got %d" expected actual)

let check_exit_ok_int name expected = function
  | Eta_js.Exit.Ok actual -> check_equal_int name expected actual
  | Eta_js.Exit.Error _ -> fail name "expected Exit.Ok"

let check_exit_fail_int name expected = function
  | Eta_js.Exit.Error (Eta_js.Cause.Fail actual) ->
      check_equal_int name expected actual
  | _ -> fail name "expected typed Cause.Fail"

let check_exit_interrupt name = function
  | Eta_js.Exit.Error (Eta_js.Cause.Interrupt _) -> ()
  | _ -> fail name "expected interrupt"

let check_exit_ok_unit name = function
  | Eta_js.Exit.Ok () -> ()
  | Eta_js.Exit.Error _ -> fail name "expected Exit.Ok ()"

let check_exit_finalizer name = function
  | Eta_js.Exit.Error
      (Eta_js.Cause.Finalizer (Eta_js.Cause.Finalizer.Fail _)) ->
      ()
  | _ -> fail name "expected finalizer failure"

let check_exit_suppressed_fail_int name expected = function
  | Eta_js.Exit.Error
      (Eta_js.Cause.Suppressed
        {
          primary = Eta_js.Cause.Fail actual;
          finalizer = Eta_js.Cause.Finalizer.Fail _;
        }) ->
      check_equal_int name expected actual
  | _ -> fail name "expected suppressed primary failure"

let deep_bind depth =
  let open Eta_js in
  let eff = ref (Effect.pure 0) in
  for index = 1 to depth do
    ignore index;
    eff := Effect.bind (fun value -> Effect.pure (value + 1)) !eff
  done;
  !eff
