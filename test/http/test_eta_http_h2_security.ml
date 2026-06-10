open Test_eta_http_support
open Test_eta_http_h2_support

let test_h2_multiplexer_buffer_full_is_security_error () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected h2 client error")
      ()
  in
  let reader = Eta_http_eio.H2.Multiplexer.create_client_reader ~buffer_size:8 client in
  let partial_headers =
    String.sub
      (h2_frame_header ~length:64 ~frame_type:0x1 ~flags:0 ~stream_id:1)
      0 8
  in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:8 partial_headers)
  in
  match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
  | Security_error
      (Connection_protocol_violation
        { kind = "h2_read_buffer_exhausted"; message = _ }) -> ()
  | Security_error kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | Read _ | Eof _ | Close ->
      Alcotest.fail "buffer-full read did not surface a typed security error"

let test_h2_security_settings_churn_reader () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected h2 client error")
      ()
  in
  let reader = Eta_http_eio.H2.Multiplexer.create_client_reader ~buffer_size:64 client in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:11
         (String.concat "" (List.init 11 (fun _ -> h2_settings_frame))))
  in
  let rec loop attempts =
    if attempts = 0 then Alcotest.fail "settings churn was not detected"
    else
      match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
      | Security_error
          (Settings_churn_rate_exceeded { observed_rate_hz; limit_hz }) ->
          Alcotest.(check int) "observed" 11 observed_rate_hz;
          Alcotest.(check int) "limit" 10 limit_hz
      | Security_error kind ->
          Alcotest.failf "unexpected security error: %s"
            (Eta_http.Error.kind_name kind)
      | Read _ | Eof _ -> loop (attempts - 1)
      | Close -> Alcotest.fail "client closed before settings churn detection"
  in
  loop 32
