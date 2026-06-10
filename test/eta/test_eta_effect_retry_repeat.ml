open Eta
open Test_eta_support

let test_effect_retry_preserves_structured_exception_causes () =
  with_runtime @@ fun rt ->
  let left = Failure "retry-left" in
  let right = Failure "retry-right" in
  let backtrace = Printexc.get_callstack 4 in
  let attempt =
    Effect.sync (fun () ->
        raise (Eio.Exn.Multiple [ (left, backtrace); (right, backtrace) ]))
  in
  match
    Runtime.run rt
      (Effect.retry (Schedule.recurs 0) (fun (_ : string) -> false) attempt)
  with
  | Exit.Error (Cause.Concurrent [ Cause.Die left_die; Cause.Die right_die ]) ->
      Alcotest.(check bool) "left exception" true (left_die.exn == left);
      Alcotest.(check bool) "right exception" true (right_die.exn == right)
  | Exit.Error cause ->
      Alcotest.failf "expected concurrent retry cause, got %a"
        (Cause.pp Format.pp_print_string)
        cause
  | Exit.Ok _ -> Alcotest.fail "expected retry failure"
