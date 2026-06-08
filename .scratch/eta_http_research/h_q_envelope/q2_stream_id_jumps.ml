let attack =
  let open Malicious_server in
  {
    id = "stream_id_jumps";
    group = Q2;
    title = "Server stream-id jumps";
    falsifier =
      "Frames for skipped or unknown stream IDs must not create stream state or bypass admission.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_concurrent_stream_attempts" ~value:"128"
        ~justification:
          "Unknown stream IDs are dropped and do not allocate stream state; valid local stream attempts still share the H-D1 admission cap."
        ~error_variant:"Stream_admission_rejected";
    expected_error_class = "stream_admission_rejected";
    frames_per_second = 512;
  }
