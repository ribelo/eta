let attack =
  let open Malicious_server in
  {
    id = "allocator_pressure";
    group = Allocator;
    title = "Allocator pressure falsifier for stream lifecycle, WINDOW_UPDATE, and stream-id churn";
    falsifier =
      "Active-path Gc.minor_words between attack start and breaker fire for the selected high-risk attacks must stay below the documented cap.";
    coverage = Adapter_policy_only;
    default =
      default ~knob:"max_allocator_words_per_admitted_frame_active" ~value:"2260 words/frame"
        ~justification:
          "Twice the H-D1 benign baseline of 1129.6 minor words/stream; this rejects attack-proportional active-path allocation before the breaker fires."
        ~error_variant:"Connection_protocol_violation";
    expected_error_class = "connection_protocol_violation";
    frames_per_second = 1000;
  }
