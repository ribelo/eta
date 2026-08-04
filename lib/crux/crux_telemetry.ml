module Observability = Eta_observability

let advancement_boundaries =
  [
    0.01;
    0.025;
    0.05;
    0.1;
    0.25;
    0.5;
    1.;
    2.5;
    5.;
    10.;
    25.;
    50.;
    100.;
    250.;
    500.;
    1000.;
  ]

let timed_if_metrics operation =
  Eta.Spi.Expert.make ~leaf_name:"Eta_crux.advance"
    (fun context ->
      let enabled =
        Eta.Spi.Expert.observability_metrics_enabled context
      in
      let started_ms =
        if enabled then
          Eta.Spi.Expert.observability_now_ms context
        else 0
      in
      let result = operation () in
      let duration_ms =
        if enabled then
          float_of_int
            (max 0
               (Eta.Spi.Expert.observability_now_ms context
               - started_ms))
        else 0.
      in
      Eta.Exit.Ok (result, duration_ms))

let with_span ?(attrs = []) name effect =
  Observability.named name
    (Observability.annotate_all attrs effect)

let advance effect = with_span "eta_crux.advance" effect

let point ?(attrs = []) ~name ~unit_ ~kind value =
  Observability.metric ~attrs ~name ~unit_ ~kind value

let advancement ~trigger ~outcome ~duration_ms =
  Observability.metric_updates_lazy (fun () ->
      let attrs =
        [
          ("eta_crux.trigger", trigger);
          ("eta_crux.outcome", outcome);
        ]
      in
      [
        point ~attrs
          ~name:"eta_crux.advancements.total"
          ~unit_:"{advancement}"
          ~kind:(Eta.Capabilities.Counter { monotonic = true })
          (Eta.Capabilities.Number (Eta.Capabilities.Int 1));
        point ~attrs
          ~name:"eta_crux.advancement.duration" ~unit_:"ms"
          ~kind:
            (Eta.Capabilities.Histogram
               { boundaries = advancement_boundaries })
          (Eta.Capabilities.Number
             (Eta.Capabilities.Float duration_ms));
      ])

let post_commit effect =
  with_span "eta_crux.post_commit" effect

let delivery effect =
  with_span "eta_crux.driver.delivery" effect

let request effect =
  with_span "eta_crux.driver.request" effect

let session_replace effect =
  with_span "eta_crux.session.replace" effect

let root_teardown effect =
  with_span "eta_crux.root.teardown" effect

let root_started () =
  Observability.log_info "eta_crux.root.started"

let terminal_metric outcome =
  Observability.metric_updates_lazy (fun () ->
      [
        point
          ~attrs:[ ("eta_crux.outcome", outcome) ]
          ~name:"eta_crux.roots.terminal.total"
          ~unit_:"{root}"
          ~kind:(Eta.Capabilities.Counter { monotonic = true })
          (Eta.Capabilities.Number (Eta.Capabilities.Int 1));
      ])

let root_stopped () =
  let open Eta.Syntax in
  let* () =
    Observability.log_info "eta_crux.root.stopped"
  in
  terminal_metric "stopped"

let origin = function
  | Crux_failure.Failure.Transition -> "transition"
  | Crux_failure.Failure.Owned_work -> "owned_work"
  | Crux_failure.Failure.Adapter_delivery -> "adapter_delivery"
  | Crux_failure.Failure.Request_dispatch -> "request_dispatch"
  | Crux_failure.Failure.Export_dispatch -> "export_dispatch"
  | Crux_failure.Failure.Cleanup -> "cleanup"
  | Crux_failure.Failure.Crash_handler -> "crash_handler"

let trigger = function
  | Crux_failure.Failure.Initial_start -> "initial_start"
  | Crux_failure.Failure.Endpoint_message -> "endpoint_message"
  | Crux_failure.Failure.Transition_effect -> "transition_effect"
  | Crux_failure.Failure.Lifecycle_program -> "lifecycle_program"
  | Crux_failure.Failure.Source_opening -> "source_opening"
  | Crux_failure.Failure.Source_producer -> "source_producer"
  | Crux_failure.Failure.Local_export_invocation ->
      "local_export_invocation"
  | Crux_failure.Failure.Serialized_export_invocation ->
      "serialized_export_invocation"
  | Crux_failure.Failure.Outbound_request -> "outbound_request"
  | Crux_failure.Failure.Inbound_response -> "inbound_response"
  | Crux_failure.Failure.Request_cancellation ->
      "request_cancellation"
  | Crux_failure.Failure.Output_delivery -> "output_delivery"
  | Crux_failure.Failure.Stop_teardown -> "stop_teardown"
  | Crux_failure.Failure.Crash_teardown -> "crash_teardown"
  | Crux_failure.Failure.Application_crash_handler ->
      "application_crash_handler"

let crash_attrs (failure : Crux_failure.Failure.t) =
  let primary = failure.Crux_failure.Failure.primary in
  [
    ("eta_crux.failure.origin", origin primary.origin);
    ("eta_crux.failure.trigger", trigger primary.trigger);
    ( "eta_crux.observation.position",
      Int64.to_string
        (Crux_failure.Failure.Observation_position.to_int64
           primary.position) );
  ]

let root_crashed failure =
  Observability.log_error ~attrs:(crash_attrs failure)
    "eta_crux.root.crashed"

let root_crash_settled () = terminal_metric "crashed"
