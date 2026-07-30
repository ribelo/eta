open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let require label condition =
  if not condition then failwith ("observability sinks check failed: " ^ label)

let step name =
  let open Syntax in
  Eta_observability.named ~error_pp:pp_error name
    (let* () =
       Eta_observability.log ~attrs:[ ("step", name) ] "step.finished"
     in
     let* () =
       Eta_observability.metric_counter ~name:"example.step.finished"
         ~attrs:[ ("step", name) ]
         (Eta_observability.Meter.Int 1)
     in
     Eta_observability.event ~attrs:[ ("step", name) ] "step.event")

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "observability sinks failed: %a@." (Cause.pp pp_error)
        cause;
      exit 1

let span_named name span =
  String.equal span.Eta_observability.Tracer.name name

let has_trace record =
  (not (String.equal record.Eta_observability.Logger.trace_id ""))
  && not (String.equal record.Eta_observability.Logger.span_id "")

let point_for step point =
  String.equal point.Eta_observability.Meter.name "example.step.finished"
  && match List.assoc_opt "step" point.attrs with
     | Some actual -> String.equal actual step
     | None -> false

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta_observability.Tracer.in_memory () in
  let logger = Eta_observability.Logger.in_memory () in
  let meter = Eta_observability.Meter.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta_observability.Tracer.as_capability tracer)
      ~logger:(Eta_observability.Logger.as_capability logger) ~meter:(Eta_observability.Meter.as_capability meter)
      ()
  in
  run_ok rt (step "first");
  run_ok rt (step "second");
  Eta_observability.Tracer.retain_recent tracer ~max:1;
  let spans = Eta_observability.Tracer.dump tracer in
  let logs = Eta_observability.Logger.dump logger in
  let points = Eta_observability.Meter.dump meter in
  require "retained span count" (List.length spans = 1);
  require "retained second span" (List.exists (span_named "second") spans);
  require "log count" (List.length logs = 2);
  require "logs linked to spans" (List.for_all has_trace logs);
  require "metric count" (List.length points = 2);
  require "second metric" (List.exists (point_for "second") points);
  Format.printf "observability-sinks:spans=%d logs=%d metrics=%d retained=second@."
    (List.length spans) (List.length logs) (List.length points)
