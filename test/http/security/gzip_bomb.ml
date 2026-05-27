let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop index =
    index + n_len <= h_len
    && (String.equal needle (String.sub haystack index n_len)
       || loop (index + 1))
  in
  n_len = 0 || loop 0

let test_gzip_expansion_cap () =
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let input = Eta_http.Body.Stream.of_bytes [ Bytes.make 4096 'x' ] in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  let compressed =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
    |> Eta_test.Expect.expect_ok
  in
  let decoded =
    Eta_http.Body.Transducer.gzip_decode ~max_decoded_bytes:1024
      (Eta_http.Body.Stream.of_bytes [ compressed ])
  in
  match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded) with
  | Eta.Exit.Ok _ -> Alcotest.fail "gzip expansion cap unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec; message }; _ }) ->
      Alcotest.(check string) "codec" "gzip" codec;
      Alcotest.(check bool) "cap message" true (contains message "exceeds")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let () =
  Alcotest.run "eta-http-security"
    [ ("gzip", [ Alcotest.test_case "expansion cap" `Quick test_gzip_expansion_cap ]) ]
