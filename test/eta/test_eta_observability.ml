open Eta
open Eta_test
open Test_eta_support

let test_observability_eio_interrupt_status () =
  with_traced_runtime @@ fun rt tracer ->
  ignore
    (Runtime.run rt
       (Effect.named "interrupt"
          (Effect.sync (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "cancel"))))) :
      (unit, _) Exit.t);
  let span =
    List.find
      (fun span -> String.equal span.Tracer.name "interrupt")
      (Tracer.dump tracer)
  in
  check_status "interrupt" Tracer.Cancelled span.status
