let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let check_hpack () =
  let result = Limits.run_hpack_bomb () in
  let elevated =
    Limits.run_hpack_bomb
      ~config:{ Limits.default_config with hpack_decoded_max_bytes = 1024 * 1024 }
      ()
  in
  Printf.printf "HPACK encoded=%d decoded=%d limit=%d\n%!" result.encoded_bytes
    result.decoded_bytes result.limit_bytes;
  check "HPACK bomb shape is 10KB to 100MB"
    (result.encoded_bytes = 10 * 1024
    && result.decoded_bytes = 100 * 1024 * 1024);
  check "HPACK decoded cap aborts at 256KB"
    (match result.error with
    | Some err -> Error.error_class err = "hpack_decode_overflow"
    | None -> false);
  check "HPACK user-elevated 1MB cap still aborts"
    (elevated.limit_bytes = 1024 * 1024
    && match elevated.error with
       | Some err -> Error.error_class err = "hpack_decode_overflow"
       | None -> false)

let check_continuation () =
  let result = Limits.run_continuation_flood () in
  Printf.printf
    "CONTINUATION frames=%d frame_bytes=%d abort_frame=%d accumulated=%d limit=%d\n%!"
    result.frame_count result.frame_bytes result.abort_frame
    result.accumulated_bytes result.limit_bytes;
  check "CONTINUATION flood has 1000 1KB frames"
    (result.frame_count = 1_000 && result.frame_bytes = 1024);
  check "CONTINUATION accumulator aborts around frame 64"
    (result.abort_frame >= 64 && result.abort_frame <= 65
    && result.accumulated_bytes >= result.limit_bytes);
  check "CONTINUATION flood maps typed error"
    (match result.error with
    | Some err -> Error.error_class err = "continuation_flood"
    | None -> false)

let check_defaults () =
  let config = Limits.default_config in
  check "decoded cap is 4x p99 inventory"
    (Limits.decoded_cap_safety_factor config = 4);
  check "continuation cap is 4x large-header baseline"
    (Limits.continuation_cap_safety_factor config = 4)

let () =
  check_hpack ();
  check_continuation ();
  check_defaults ();
  Printf.printf "h_q3_hpack_continuation fixtures passed\n%!"
