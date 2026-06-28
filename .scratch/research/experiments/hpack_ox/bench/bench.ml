open Hpack_ox
let () =
  let enc = encoder_create 4096 in
  let headers = [
    {name=":status"; value="200"; sensitive=false};
    {name="content-type"; value="text/plain"; sensitive=false};
  ] in
  let encoded = encode_headers enc headers in
  Printf.printf "Encoded %d bytes\n" (String.length encoded);
  (* Decode to verify *)
  let dec = create 4096 in
  match decode_headers_string dec encoded with
  | Ok hs -> List.iter (fun h -> Printf.printf "  %s: %s\n" h.name h.value) hs
  | Error _ -> print_endline "  DECODE ERROR"
