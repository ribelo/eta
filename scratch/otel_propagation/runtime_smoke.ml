open Otel_propagation

let () =
  P_a_pair_only.scenario_drops_state_and_baggage ();
  P_b_core_context.scenario_full_round_trip ();
  P_b_core_context.scenario_unsampled_suppresses_child ();
  P_c_exporter_only.scenario_headers_without_runtime_context ();
  print_endline "otel propagation lab passed"
