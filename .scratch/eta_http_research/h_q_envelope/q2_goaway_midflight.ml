let attack =
  let open Malicious_server in
  {
    id = "goaway_mid_flight";
    group = Q2;
    title = "GOAWAY mid-flight while client expects more streams";
    falsifier =
      "Connection close while streams are active must fail typed, stop admission, and release stream permits.";
    coverage =
      Deferred_missing_capability
        "H-D1 Frame has no GOAWAY constructor or last_stream_id cutoff hook; covered as connection teardown only.";
    default =
      default ~knob:"max_goaway_per_connection" ~value:"1"
        ~justification:
          "HTTP/2 GOAWAY is terminal for the connection. Repeated GOAWAY belongs to connection churn handling, not per-stream recovery."
        ~error_variant:"Connection_closed";
    expected_error_class = "connection_closed";
    frames_per_second = 1;
  }
