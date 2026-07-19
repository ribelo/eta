open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let require label condition =
  if not condition then failwith ("observability controls check failed: " ^ label)

let expensive_attrs builds () =
  incr builds;
  [ ("expensive", "built") ]

let hidden_export =
  let open Syntax in
  Effect.named ~error_pp:pp_error "hidden.export"
    (let* () = Effect.log "hidden.log" in
     let* () =
       Effect.metric_counter ~name:"hidden.metric" ~monotonic:false
         (Meter.Int 1)
     in
     Effect.event "hidden.event")
  |> Effect.suppress_observability

let program attr_builds =
  let open Syntax in
  Effect.named ~error_pp:pp_error "visible.request"
    (let* tracing = Effect.is_tracing_enabled in
     let* () =
       Effect.annotate_all_lazy (expensive_attrs attr_builds)
         (Effect.event "visible.event")
     in
     let* () = hidden_export in
     Effect.pure tracing)

let run_bool rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "observability controls failed: %a@."
        (Cause.pp pp_error) cause;
      exit 1

let has_attr key value attrs =
  match List.assoc_opt key attrs with
  | Some actual -> String.equal actual value
  | None -> false

let span_named name span =
  String.equal span.Tracer.name name

let event_named name event =
  String.equal event.Tracer.ev_name name

let verify_enabled attr_builds tracer logger meter tracing =
  let spans = Tracer.dump tracer in
  let logs = Logger.dump logger in
  let metrics = Meter.dump meter in
  require "tracing enabled" tracing;
  require "lazy attrs built once" (!attr_builds = 1);
  require "hidden span suppressed"
    (not (List.exists (span_named "hidden.export") spans));
  require "hidden logs suppressed" (logs = []);
  require "hidden metrics suppressed" (metrics = []);
  let visible =
    match List.find_opt (span_named "visible.request") spans with
    | Some span -> span
    | None -> failwith "observability controls check failed: visible span"
  in
  require "visible attr" (has_attr "expensive" "built" visible.attrs);
  require "visible event"
    (List.exists (event_named "visible.event") visible.events);
  List.length spans

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let disabled_attrs = ref 0 in
  let disabled_rt = Eta_eio.Runtime.create ~sw ~clock () in
  let disabled_tracing = run_bool disabled_rt (program disabled_attrs) in
  require "tracing disabled" (not disabled_tracing);
  require "disabled lazy attrs" (!disabled_attrs = 0);

  let enabled_attrs = ref 0 in
  let tracer = Tracer.in_memory () in
  let logger = Logger.in_memory () in
  let meter = Meter.in_memory () in
  let enabled_rt =
    Eta_eio.Runtime.create ~sw ~clock
      ~tracer:(Tracer.as_capability tracer)
      ~logger:(Logger.as_capability logger) ~meter:(Meter.as_capability meter)
      ()
  in
  let enabled_tracing = run_bool enabled_rt (program enabled_attrs) in
  let visible_spans =
    verify_enabled enabled_attrs tracer logger meter enabled_tracing
  in
  Format.printf
    "observability-controls:disabled_trace=%b disabled_attrs=%d visible_spans=%d hidden_logs=%d hidden_metrics=%d@."
    disabled_tracing !disabled_attrs visible_spans
    (List.length (Logger.dump logger))
    (List.length (Meter.dump meter))
