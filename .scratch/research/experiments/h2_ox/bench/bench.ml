open H2_ox
let () =
  (* Roundtrip: serialize HEADERS frame, then parse it back *)
  let buf = Bytes.create 256 in
  let pos_ref = ref 0 in
  let header_block = "\x82\x84\x87\x41\x0cexample.test" in
  Serialize.write_headers_frame buf pos_ref ~stream_id:1l ~flags:0x4 (* END_HEADERS *) header_block;
  let len = !pos_ref in
  Printf.printf "Serialized %d bytes\n" len;
  match Frame.parse_frame buf 0 with
  | Ok (frame, off) ->
      Printf.printf "Parsed: type=%d len=%d flags=%d stream=%ld\n"
        (match frame.header.frame_type with Headers -> 1 | _ -> -1)
        frame.header.payload_length frame.header.flags frame.header.stream_id;
      (match frame.payload with
       | Frame.Headers_payload h -> Printf.printf "Headers: %d bytes\n" (String.length h)
       | _ -> print_endline "wrong type");
      if off = len then print_endline "ROUNDTRIP OK" else print_endline "SIZE MISMATCH"
  | Error _ -> print_endline "PARSE FAIL"
