let attack =
  let open Malicious_server in
  {
    id = "huffman_cpu_amplification";
    group = Q5;
    title = "Huffman CPU amplification";
    falsifier =
      "Small encoded headers must be bounded by decoded-header byte caps before HPACK/Huffman CPU dominates.";
    coverage =
      Deferred_missing_capability
        "H-D1 has no HPACK/Huffman decoder; H-Q3 covers decoded-size caps but not Huffman CPU cost.";
    default =
      default ~knob:"hpack_decoded_max_bytes" ~value:"256KiB"
        ~justification:
          "Inherited from H-Q3: 4x the synthetic OTel/header inventory p99 and aborts 10KiB->100MiB decoded bombs."
        ~error_variant:"Hpack_decode_overflow";
    expected_error_class = "hpack_decode_overflow";
    frames_per_second = 1000;
  }
