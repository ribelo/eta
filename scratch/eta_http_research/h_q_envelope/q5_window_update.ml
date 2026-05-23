let attack =
  let open Malicious_server in
  {
    id = "window_update_accounting";
    group = Q5;
    title = "WINDOW_UPDATE accounting attacks";
    falsifier =
      "WINDOW_UPDATE storms and inconsistent increments must not overflow accounting or leave stalled stream state live.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_window_updates_per_second" ~value:"1000/sec"
        ~justification:
          "Window updates are expected under large streaming responses. The default allows high-throughput flow control while bounding storms."
        ~error_variant:"Decode_error";
    expected_error_class = "decode_error";
    frames_per_second = 2000;
  }
