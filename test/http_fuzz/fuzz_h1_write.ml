open Eta_http_fuzz_support

let header_gen =
  Crowbar.map
    [ bounded_string 32; bounded_string 128 ]
    (fun name value -> (name, value))

let headers_gen = bounded_list 8 header_gen

let body_gen =
  Crowbar.choose
    [
      Crowbar.const Eta_http_h1.Write.Empty;
      Crowbar.map
        [ bounded_list 4 (bounded_bytes 128) ]
        (fun chunks -> Eta_http_h1.Write.Fixed chunks);
    ]

let url = Eta_http.Core.Url.of_string "https://example.test:8443/fuzz/path?x=1"

let () =
  Crowbar.add_test ~name:"h1 writers agree or reject together"
    [ bounded_string 16; headers_gen; body_gen ]
    (fun method_ headers body ->
      let string_result =
        Eta_http_h1.Write.to_string ~method_ ~url ~headers ~body
      in
      let bytes = Bytes.make 8192 '\000' in
      let bytes_result =
        Eta_http_h1.Write.write_to_bytes bytes ~pos:0 ~method_ ~url ~headers
          ~body
      in
      let buffer = Buffer.create 512 in
      let buffer_result =
        Eta_http_h1.Write.write buffer ~method_ ~url ~headers ~body
      in
      let flow_buffer = Buffer.create 512 in
      let flow = Eio.Flow.buffer_sink flow_buffer in
      let flow_result =
        Eta_http_eio.H1.Write.write_to_flow flow ~method_ ~url ~headers ~body
      in
      match (string_result, bytes_result, buffer_result, flow_result) with
      | Ok expected, Ok len, Ok (), Ok () ->
          check_same_string "bytes writer" expected
            (Bytes.sub_string bytes 0 len);
          check_same_string "buffer writer" expected (Buffer.contents buffer);
          check_same_string "flow writer" expected (Buffer.contents flow_buffer)
      | Error _, Error _, Error _, Error _ ->
          check_same_string "buffer writer rejected before writing" ""
            (Buffer.contents buffer);
          check_same_string "flow writer rejected before writing" ""
            (Buffer.contents flow_buffer)
      | Ok _, Error error, _, _ ->
          Crowbar.failf "bytes writer rejected string-accepted input: %s"
            (Eta_http.Error.to_string error)
      | Ok _, _, Error error, _ ->
          Crowbar.failf "buffer writer rejected string-accepted input: %s"
            (Eta_http.Error.to_string error)
      | Ok _, _, _, Error error ->
          Crowbar.failf "flow writer rejected string-accepted input: %s"
            (Eta_http.Error.to_string error)
      | Error error, Ok len, _, _ ->
          Crowbar.failf
            "bytes writer accepted string-rejected input (%s), len=%d"
            (Eta_http.Error.to_string error) len
      | Error error, _, Ok (), _ ->
          Crowbar.failf "buffer writer accepted string-rejected input: %s"
            (Eta_http.Error.to_string error)
      | Error error, _, _, Ok () ->
          Crowbar.failf "flow writer accepted string-rejected input: %s"
            (Eta_http.Error.to_string error))
