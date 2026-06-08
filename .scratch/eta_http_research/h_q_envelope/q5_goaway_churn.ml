let attack =
  let open Malicious_server in
  {
    id = "goaway_churn";
    group = Q5;
    title = "GOAWAY churn across repeated connections";
    falsifier =
      "Repeated terminal connection teardown must not leak h2 cells, fds, fibers, or stream counters.";
    coverage =
      Deferred_missing_capability
        "H-D1 Frame has no GOAWAY; H-D5 can model close/reopen churn but not raw GOAWAY last_stream_id semantics.";
    default =
      default ~knob:"max_goaway_churn_per_origin_per_minute" ~value:"30/min"
        ~justification:
          "A healthy origin should not repeatedly terminate fresh h2 connections. 30/min allows deploy churn while bounding loops."
        ~error_variant:"Connection_closed";
    expected_error_class = "connection_closed";
    frames_per_second = 2;
  }
