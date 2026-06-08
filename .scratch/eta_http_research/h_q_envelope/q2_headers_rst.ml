let attack =
  let open Malicious_server in
  {
    id = "headers_rst_every_stream";
    group = Q2;
    title = "HEADERS + RST_STREAM after every stream";
    falsifier =
      "Admission counter must cap ACTIVE+CANCELLED stream attempts and return stream state to baseline.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_concurrent_stream_attempts" ~value:"128"
        ~justification:
          "Inherited from H-D1 max_streams stress evidence: 1000 rapid reset attempts stay bounded while admitting useful h2 concurrency."
        ~error_variant:"Stream_admission_rejected";
    expected_error_class = "stream_admission_rejected";
    frames_per_second = 256;
  }
