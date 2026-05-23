(* Scratch-only R1 allocation probe for the h1 raw response parser. *)

let fail msg =
  Printf.eprintf "eta_http_r1_parser_alloc verdict=FAIL detail=%S\n%!" msg;
  exit 1

let iterations = 100_000
let max_header_bytes = 32 * 1024

let run_once buffer headers raw =
  Eta_http.H1.Parse.parse_raw buffer ~len:(Bytes.length buffer)
    ~max_header_bytes ~headers raw

let rec loop corpus headers raw remaining checksum =
  if remaining = 0 then checksum
  else
    let buffer = Array.unsafe_get corpus (remaining mod Array.length corpus) in
    let code = run_once buffer headers raw in
    if code <> Eta_http.H1.Parse.raw_ok then
      fail (Printf.sprintf "parser returned %d" code);
    loop corpus headers raw (remaining - 1)
      (checksum + Eta_http.H1.Parse.raw_status raw
     + Eta_http.H1.Parse.raw_body_len raw)

let () =
  let corpus =
    [|
      Bytes.of_string
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nX-Probe: r1\r\n\r\nhello";
      Bytes.of_string
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 14\r\nConnection: keep-alive\r\n\r\n{\"error\":true}";
      Bytes.of_string
        "HTTP/1.0 204 No Content\r\nServer: probe\r\nContent-Length: 0\r\n\r\n";
      Bytes.of_string
        "HTTP/1.1 302 Found\r\nLocation: https://example.test/next\r\nContent-Length: 0\r\n\r\n";
    |]
  in
  let headers = Eta_http.H1.Parse.create_raw_headers 16 in
  let raw = Eta_http.H1.Parse.create_raw_response () in
  Gc.full_major ();
  let before = (Gc.quick_stat ()).Gc.minor_words in
  let checksum = loop corpus headers raw iterations 0 in
  let after = (Gc.quick_stat ()).Gc.minor_words in
  let minor_words = after -. before in
  let words_per_parse = minor_words /. float_of_int iterations in
  let verdict = if minor_words = 0.0 then "PASS" else "FAIL" in
  Printf.printf
    "eta_http_r1_parser_alloc verdict=%s iterations=%d minor_words=%.0f words_per_parse=%.6f checksum=%d body_off=%d body_len=%d\n%!"
    verdict iterations minor_words words_per_parse checksum
    (Eta_http.H1.Parse.raw_body_off raw)
    (Eta_http.H1.Parse.raw_body_len raw);
  if minor_words <> 0.0 then exit 1
