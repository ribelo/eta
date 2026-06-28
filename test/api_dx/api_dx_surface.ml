let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let length = in_channel_length input in
      really_input_string input length)

let source_path path =
  let candidates =
    [
      path;
      Filename.concat ".." path;
      Filename.concat "../.." path;
      Filename.concat "../../.." path;
      Filename.concat "../../../.." path;
      Filename.concat "../../../../.." path;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> failwith (Printf.sprintf "could not locate %s from %s" path (Sys.getcwd ()))

let count_sub haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index acc =
    if needle_len = 0 || index + needle_len > hay_len then acc
    else if String.sub haystack index needle_len = needle then
      loop (index + needle_len) (acc + 1)
    else loop (index + 1) acc
  in
  loop 0 0

let forbidden_tokens =
  [
    "Effect.bind";
    "Eta.Effect.bind";
    ">>=";
  ]

let check_no_explicit_bind path =
  let source_path = source_path path in
  let contents = read_file source_path in
  forbidden_tokens
  |> List.iter (fun token ->
         let count = count_sub contents token in
         if count > 0 then
           failwith
             (Printf.sprintf
                "%s exposes %s %d time(s); use syntax or a named helper in \
                 user-facing surfaces"
                path token count))

let promoted_examples =
  [
    "examples/quickstart.ml";
    "examples/catch_recovery.ml";
    "examples/validation_boundary.ml";
    "examples/sync_defect_boundary.ml";
    "examples/resource_retry.ml";
    "examples/retry_schedule.ml";
    "examples/repeat_heartbeat.ml";
    "examples/cached_resource.ml";
    "examples/manual_resource_refresh.ml";
    "examples/scoped_resource.ml";
    "examples/service_composition.ml";
    "examples/source_locations.ml";
    "examples/tap_success.ml";
    "examples/map_projection.ml";
    "examples/stream_decode.ml";
    "examples/batch_concurrency.ml";
    "examples/all_health_checks.ml";
    "examples/blueprint_names.ml";
    "examples/bounded_channel.ml";
    "examples/channel_probe.ml";
    "examples/unbounded_queue.ml";
    "examples/queue_probe.ml";
    "examples/mutable_ref_state.ml";
    "examples/deterministic_random.ml";
    "examples/duration_budget.ml";
    "examples/timeout_policy.ml";
    "examples/uninterruptible_commit.ml";
    "examples/error_rendering.ml";
    "examples/log_level_policy.ml";
    "examples/trace_sampling.ml";
    "examples/trace_context_boundary.ml";
    "examples/span_linking.ml";
    "examples/exit_cause_boundary.ml";
    "examples/finally_cleanup.ml";
    "examples/runtime_boundary.ml";
    "examples/race_mirror.ml";
    "examples/typed_error_boundary.ml";
    "examples/admission_control.ml";
    "examples/semaphore_permits.ml";
    "examples/connection_pool.ml";
    "examples/pubsub_subscription.ml";
    "examples/pubsub_poll.ml";
    "examples/http_handlers.ml";
    "examples/cli_business.ml";
    "examples/blocking_result.ml";
    "examples/supervisor_scope.ml";
    "examples/background_lifecycle.ml";
    "examples/daemon_drain.ml";
    "examples/observability.ml";
    "examples/observability_controls.ml";
    "examples/observability_sinks.ml";
    "examples/metric_batching.ml";
    "examples/workflow_test.ml";
  ]

let preferred_docs =
  [
    "README.md";
    "examples/README.md";
    "docs/hardening.md";
    "docs/packages.md";
    "docs/services.md";
    "docs/background-work.md";
    "docs/concurrency-guide.md";
    "docs/zio-boundaries.md";
    "docs/tutorial-eta-ai.md";
    "docs/tutorial-eta-otel.md";
    "lib/ai/README.md";
    "lib/ai/anthropic/README.md";
    "lib/ai/openai/README.md";
    "lib/ai/openai_compat/README.md";
    "lib/ai/openrouter/README.md";
    "lib/http/README.md";
    "lib/otel/README.md";
    "lib/par/README.md";
    "lib/schema/README.md";
    "lib/schema_test/README.md";
    "lib/sql/README.md";
    "lib/stream/README.md";
    "lib/test/README.md";
  ]

let () =
  List.iter check_no_explicit_bind promoted_examples;
  List.iter check_no_explicit_bind preferred_docs
