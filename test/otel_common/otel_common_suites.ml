module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  module Tracer_suites = Tracer_common_suites.Make (B)
  module Logger_suites = Logger_common_suites.Make (B)
  module Metrics_suites = Metrics_common_suites.Make (B)
  module Terminal_suites = Terminal_common_suites.Make (B)

  let tests =
    [
      Tracer_suites.suite;
      Logger_suites.suite;
      Metrics_suites.suite;
      Terminal_suites.suite;
      Cause_json_common_suites.suite;
    ]
end
