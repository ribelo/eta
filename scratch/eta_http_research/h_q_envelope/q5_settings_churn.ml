let attack =
  let open Malicious_server in
  {
    id = "settings_header_table_size_churn";
    group = Q5;
    title = "SETTINGS_HEADER_TABLE_SIZE churn";
    falsifier =
      "Repeated HPACK table-size changes must be rate-limited before decoder table reallocations grow allocator pressure.";
    coverage =
      Deferred_missing_capability
        "H-D1 Frame has no SETTINGS constructor; this remains an ocaml-h2 adapter parser hook.";
    default =
      default ~knob:"max_settings_per_second" ~value:"10/sec"
        ~justification:
          "SETTINGS changes are connection configuration, normally sent at handshake or rare reconfiguration. 10/sec is intentionally generous."
        ~error_variant:"Decode_error";
    expected_error_class = "decode_error";
    frames_per_second = 250;
  }
