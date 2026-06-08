let attack =
  let open Malicious_server in
  {
    id = "rst_rate_exceeded";
    group = Q2;
    title = "RST_STREAM rate exceeds configured limit";
    falsifier =
      "RST storms must trip a circuit breaker and return cancelled stream state to baseline.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_rst_per_second_per_connection" ~value:"100/sec"
        ~justification:
          "Above normal retry/cancel behavior by two orders of magnitude for a single client connection; H-Q2 uses 250/sec as the malicious row."
        ~error_variant:"Rst_rate_exceeded";
    expected_error_class = "rst_rate_exceeded";
    frames_per_second = 250;
  }
