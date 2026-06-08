let attack =
  let open Malicious_server in
  {
    id = "header_normalization_edges";
    group = Q5;
    title = "Header normalization edge cases";
    falsifier =
      "Very long names, embedded nulls, mixed case, and zero-length names must fail typed before entering public headers.";
    coverage =
      Deferred_missing_capability
        "H-D1 Frame.Headers lacks header names/values; this belongs to the ocaml-h2 adapter normalization boundary.";
    default =
      default ~knob:"max_header_name_bytes" ~value:"8192"
        ~justification:
          "Large enough for real custom metadata names by a wide margin; paired with value/list caps from H-Q3 to bound normalization."
        ~error_variant:"Header_invalid";
    expected_error_class = "header_invalid";
    frames_per_second = 64;
  }
