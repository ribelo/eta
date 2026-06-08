let attack =
  let open Malicious_server in
  {
    id = "data_frame_slowloris";
    group = Q5;
    title = "DATA-frame slowloris";
    falsifier =
      "A response that trickles DATA forever must hit the body idle timeout and release stream state.";
    coverage = H_d1_multiplexer;
    default =
      default ~knob:"max_data_idle_per_stream" ~value:"10s"
        ~justification:
          "Matches existing eta-http timeout taxonomy: body progress must be observed. The lab uses a shorter internal timeout to avoid a slow test."
        ~error_variant:"Response_body_idle_timeout";
    expected_error_class = "response_body_idle_timeout";
    frames_per_second = 1;
  }
