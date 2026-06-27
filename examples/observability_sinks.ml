open Eta

let require label condition =
  if not condition then failwith ("observability sinks check failed: " ^ label)

let step name =
  let open Syntax in
  Effect.named name
    (let* () =
       Effect.log ~attrs:[ ("step", name) ] "step.finished"
     in
     let* () =
       Effect.metric_counter ~name:"example.step.finished"
         ~attrs:[ ("step", name) ]
         (Meter.Int 1)
     in
     Effect.event ~attrs:[ ("step", name) ] "step.event")

let pp_error fmt = function _ -> Format.pp_print_string fmt "<error>"

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "observability sinks failed: %a@." (Cause.pp pp_error)
        cause;
      exit 1

let span_named name span =
  String.equal span.Tracer.name name

let has_trace record =
  (not (String.equal record.Logger.trace_id ""))
  && not (String.equal record.Logger.span_id "")

let point_for step point =
  String.equal point.Meter.name "example.step.finished"
  && match List.assoc_opt "step" point.attrs with
     | Some actual -> String.equal actual step
     | None -> false

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let logger = Logger.in_memory () in
  let meter = Meter.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ~logger:(Logger.as_capability logger) ~meter:(Meter.as_capability meter)
      ()
  in
  run_ok rt (step "first");
  run_ok rt (step "second");
  Tracer.retain_recent tracer ~max:1;
  let spans = Tracer.dump tracer in
  let logs = Logger.dump logger in
  let points = Meter.dump meter in
  require "retained span count" (List.length spans = 1);
  require "retained second span" (List.exists (span_named "second") spans);
  require "log count" (List.length logs = 2);
  require "logs linked to spans" (List.for_all has_trace logs);
  require "metric count" (List.length points = 2);
  require "second metric" (List.exists (point_for "second") points);
  Format.printf "observability-sinks:spans=%d logs=%d metrics=%d retained=second@."
    (List.length spans) (List.length logs) (List.length points)
