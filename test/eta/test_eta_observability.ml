open Eta
open Eta_test
open Test_eta_support

let test_observability_eio_interrupt_status () =
  with_traced_runtime @@ fun rt tracer ->
  ignore
    (Runtime.run rt
       (Eta_observability.named "interrupt"
          (Effect.sync (fun () ->
               raise (Eio.Cancel.Cancelled (Failure "cancel"))))) :
      (unit, _) Exit.t);
  let span =
    List.find
      (fun span -> String.equal span.Eta_observability.Tracer.name "interrupt")
      (Eta_observability.Tracer.dump tracer)
  in
  check_status "interrupt" Eta_observability.Tracer.Cancelled span.status
