open Eta

type error =
  [ `Declined of string
  | `Ledger_close_failed of string ]
[@@deriving eta_error]

let require label condition =
  if not condition then failwith ("error rendering check failed: " ^ label)

let attr key attrs =
  List.assoc_opt key attrs

let charge_payment =
  Effect.with_error_pp pp_error
    (Effect.named ~error_pp:pp_error "payment.charge"
       (Effect.fail (`Declined "card")))

let ledger_use =
  Effect.with_error_pp pp_error
    (Effect.named ~error_pp:pp_error "payment.ledger"
       (Effect.with_resource ~acquire:(Effect.pure "payments")
          ~release:(fun ledger -> Effect.fail (`Ledger_close_failed ledger))
          (fun ledger -> Effect.pure ledger)))

let find_span name spans =
  match List.find_opt (fun span -> String.equal span.Tracer.name name) spans with
  | Some span -> span
  | None -> failwith ("error rendering check failed: missing span " ^ name)

let event_message span =
  match span.Tracer.events with
  | [ event ] -> attr "exception.message" event.ev_attrs
  | events ->
      failwith
        (Printf.sprintf
           "error rendering check failed: expected one exception event, got %d"
           (List.length events))

let status_message span =
  match span.Tracer.status with
  | Tracer.Error message -> message
  | _ -> failwith "error rendering check failed: expected error span"

let verify charge_exit ledger_exit tracer =
  let charge =
    match charge_exit with
    | Exit.Error (Cause.Fail (`Declined reason)) -> reason
    | _ -> failwith "error rendering check failed: expected declined failure"
  in
  let finalizer =
    match ledger_exit with
    | Exit.Error (Cause.Finalizer (Cause.Finalizer.Fail message)) -> message
    | _ -> failwith "error rendering check failed: expected finalizer failure"
  in
  let spans = Tracer.dump tracer in
  let charge_span = find_span "payment.charge" spans in
  let ledger_span = find_span "payment.ledger" spans in
  let charge_status = status_message charge_span in
  let ledger_status = status_message ledger_span in
  require "typed failure preserved" (String.equal charge "card");
  require "charge status" (String.equal charge_status "declined:card");
  require "charge event" (event_message charge_span = Some "declined:card");
  require "finalizer rendered"
    (String.equal finalizer "ledger_close_failed:payments");
  require "ledger status"
    (String.equal ledger_status "finalizer: ledger_close_failed:payments");
  Format.printf
    "error-rendering:typed=%s status=%s finalizer=%s ledger_status=%s spans=%d@."
    charge charge_status finalizer ledger_status (List.length spans)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ()
  in
  let charge_exit = Eta_eio.Runtime.run rt charge_payment in
  let ledger_exit = Eta_eio.Runtime.run rt ledger_use in
  verify charge_exit ledger_exit tracer
