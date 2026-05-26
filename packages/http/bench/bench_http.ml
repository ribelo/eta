let response_bytes =
  Bytes.of_string
    "HTTP/1.1 200 OK\r\ncontent-length: 11\r\ncontent-type: text/plain\r\n\r\nhello world"

let request_body = [ Bytes.of_string "hello"; Bytes.of_string " "; Bytes.of_string "world" ]

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let parse_response () =
  match Http.H1.Parse.parse response_bytes ~len:(Bytes.length response_bytes) with
  | Ok response ->
      ignore (Http.H1.Parse.headers_to_list response_bytes response.headers);
      ignore (Http.H1.Parse.body_to_bytes response_bytes response)
  | Error err -> failwith (Http.H1.Parse.parse_error_to_string err)

let parse_response_raw () =
  let headers = Http.H1.Parse.create_raw_headers 16 in
  let response = Http.H1.Parse.create_raw_response () in
  let code =
    Http.H1.Parse.parse_raw response_bytes ~len:(Bytes.length response_bytes)
      ~max_header_bytes:4096 ~headers response
  in
  if code <> Http.H1.Parse.raw_ok then failwith "raw parse failed";
  ignore (Http.H1.Parse.raw_headers_to_list response_bytes headers response);
  ignore (Http.H1.Parse.raw_body_len response)

let write_request () =
  let body = Http.H1.Write.Fixed request_body in
  let url = Http.Core.Url.of_string "https://example.com/submit" in
  ignore
    (Http.H1.Write.to_string ~method_:"POST" ~url
       ~headers:(Http.Core.Header.unsafe_of_list [ ("host", "example.com") ])
       ~body)

let url_request () =
  let request =
    Http.Request.make ~body:(Fixed request_body) "POST"
      "https://example.com:443/path?q=1#fragment"
  in
  ignore (Http.Request.url request);
  ignore (Http.Request.body_chunks request)

let h2_security () =
  ignore (Http.H2.Security.validate_headers [ ("content-type", "text/plain") ])

let workloads =
  let item name run =
    { Bench_lib.name = "http." ^ name; run; samples = None }
  in
  [
    item "h1.parse.response.100k" (fun () -> repeat 100_000 parse_response);
    item "h1.parse_raw.response.100k" (fun () -> repeat 100_000 parse_response_raw);
    item "h1.write.request.100k" (fun () -> repeat 100_000 write_request);
    item "request.url_body.100k" (fun () -> repeat 100_000 url_request);
    item "h2.security.headers.10k" (fun () -> repeat 10_000 h2_security);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
