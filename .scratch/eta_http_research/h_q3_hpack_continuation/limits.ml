type config = {
  hpack_decoded_max_bytes : int;
  continuation_max_accumulator_bytes : int;
}

let default_config =
  {
    hpack_decoded_max_bytes = 256 * 1024;
    continuation_max_accumulator_bytes = 64 * 1024;
  }

type hpack_result = {
  encoded_bytes : int;
  decoded_bytes : int;
  limit_bytes : int;
  error : Error.t option;
}

type continuation_result = {
  frame_count : int;
  frame_bytes : int;
  abort_frame : int;
  accumulated_bytes : int;
  limit_bytes : int;
  error : Error.t option;
}

let hpack_error ~decoded_bytes ~limit_bytes =
  Error.make ~protocol:Error.H2 ~method_:"GET"
    ~uri:"https://malicious.example.test/hpack"
    (Hpack_decode_overflow { decoded_bytes; limit_bytes })

let continuation_error ~accumulated_bytes ~limit_bytes ~frames =
  Error.make ~protocol:Error.H2 ~method_:"GET"
    ~uri:"https://malicious.example.test/continuation"
    (Continuation_flood { accumulated_bytes; limit_bytes; frames })

let run_hpack_bomb ?(config = default_config) () =
  let encoded_bytes = 10 * 1024 in
  let decoded_bytes = 100 * 1024 * 1024 in
  let limit_bytes = config.hpack_decoded_max_bytes in
  let error =
    if decoded_bytes > limit_bytes then
      Some (hpack_error ~decoded_bytes ~limit_bytes)
    else None
  in
  { encoded_bytes; decoded_bytes; limit_bytes; error }

let run_continuation_flood ?(config = default_config) () =
  let frame_count = 1_000 in
  let frame_bytes = 1024 in
  let limit_bytes = config.continuation_max_accumulator_bytes in
  let rec loop frame accumulated =
    if frame > frame_count then (frame_count, accumulated, None)
    else
      let accumulated = accumulated + frame_bytes in
      if accumulated >= limit_bytes then
        ( frame,
          accumulated,
          Some (continuation_error ~accumulated_bytes:accumulated ~limit_bytes ~frames:frame) )
      else loop (frame + 1) accumulated
  in
  let abort_frame, accumulated_bytes, error = loop 1 0 in
  { frame_count; frame_bytes; abort_frame; accumulated_bytes; limit_bytes; error }

let inventory_header_sizes =
  [
    ("traceparent", 55);
    ("tracestate", 256);
    ("baggage", 4096);
    ("authorization", 8192);
    ("cookie", 16384);
    ("set-cookie", 16384);
    ("grpc metadata large", 32768);
    ("otlp resource attrs synthetic p99", 65536);
  ]

let percentile_99_header_bytes () =
  inventory_header_sizes |> List.map snd |> List.sort compare |> List.rev |> List.hd

let decoded_cap_safety_factor config =
  config.hpack_decoded_max_bytes / percentile_99_header_bytes ()

let continuation_cap_safety_factor config =
  config.continuation_max_accumulator_bytes / 16_384
