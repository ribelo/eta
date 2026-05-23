let attack =
  let open Malicious_server in
  {
    id = "header_churn";
    group = Q2;
    title = "Response header churn between SETTINGS";
    falsifier =
      "Repeated header shape changes must be capped before header storage or normalization grows without bound.";
    coverage =
      Deferred_missing_capability
        "H-D1 Frame.Headers carries only stream_id/tag/end_stream; no header block is exposed to mutate.";
    default =
      default ~knob:"response_header_max_change_rate" ~value:"32/sec"
        ~justification:
          "One response header block per request is normal. 32/sec leaves room for redirects/retries while bounding malicious metadata churn."
        ~error_variant:"Decode_error";
    expected_error_class = "decode_error";
    frames_per_second = 128;
  }
