let attack =
  let open Malicious_server in
  {
    id = "allocator_pressure";
    group = Allocator;
    title = "Allocator pressure falsifier for header, SETTINGS, and WINDOW_UPDATE churn";
    falsifier =
      "After warm-up, per-frame minor/major allocation for the three highest-risk attacks must be flat or below the documented cap.";
    coverage = Adapter_policy_only;
    default =
      default ~knob:"max_allocator_words_per_attack_frame_after_warmup" ~value:"128 words/frame"
        ~justification:
          "The envelope allows small adapter bookkeeping but rejects attack-proportional allocation after the circuit breaker has disconnected."
        ~error_variant:"Decode_error";
    expected_error_class = "decode_error";
    frames_per_second = 1000;
  }
