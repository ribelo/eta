open Test_eta_http_support
open Test_eta_http_h2_support

let raw_h2_frame ~frame_type ~flags ~stream_id payload =
  h2_frame_header ~length:(String.length payload) ~frame_type ~flags ~stream_id
  ^ payload

let expect_h2_security_error label frame =
  match h2_observe_security frame with
  | Some (Eta_http.Error.Connection_protocol_violation _) -> ()
  | Some kind ->
      Alcotest.failf "%s: unexpected security error: %s" label
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.failf "%s: malformed frame passed H2.Security.observe" label

let expect_h2_security_ok label frame =
  match h2_observe_security frame with
  | None -> ()
  | Some kind ->
      Alcotest.failf "%s: unexpected security error: %s" label
        (Eta_http.Error.kind_name kind)

let h2_settings_pair id value =
  let bytes = Bytes.create 6 in
  Bytes.set bytes 0 (Char.chr ((id lsr 8) land 0xff));
  Bytes.set bytes 1 (Char.chr (id land 0xff));
  Bytes.blit_string (h2_uint32 value) 0 bytes 2 4;
  Bytes.unsafe_to_string bytes

let h2_settings_payload payload =
  Eta_http.H2.Frame.header ~length:(String.length payload)
    ~frame_type:Eta_http.H2.Frame.Settings ~flags:0 ~stream_id:0
  ^ payload

let observe_with security data =
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
  Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length data)

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

let test_h2_security_rejects_invalid_control_frame_envelopes () =
  expect_h2_security_error "PING wrong length"
    (raw_h2_frame ~frame_type:0x6 ~flags:0 ~stream_id:0 "1234567");
  expect_h2_security_error "PING nonzero stream"
    (raw_h2_frame ~frame_type:0x6 ~flags:0 ~stream_id:1 "12345678");
  expect_h2_security_error "SETTINGS nonzero stream"
    (raw_h2_frame ~frame_type:0x4 ~flags:0 ~stream_id:1 "");
  expect_h2_security_error "SETTINGS ACK with payload"
    (raw_h2_frame ~frame_type:0x4 ~flags:0x1 ~stream_id:0 "123456");
  expect_h2_security_error "SETTINGS invalid length"
    (raw_h2_frame ~frame_type:0x4 ~flags:0 ~stream_id:0 "12345");
  expect_h2_security_error "RST_STREAM zero stream"
    (raw_h2_frame ~frame_type:0x3 ~flags:0 ~stream_id:0 "1234");
  expect_h2_security_error "RST_STREAM wrong length"
    (raw_h2_frame ~frame_type:0x3 ~flags:0 ~stream_id:1 "123");
  expect_h2_security_error "GOAWAY nonzero stream"
    (raw_h2_frame ~frame_type:0x7 ~flags:0 ~stream_id:1 "12345678");
  expect_h2_security_error "GOAWAY too short"
    (raw_h2_frame ~frame_type:0x7 ~flags:0 ~stream_id:0 "1234567")

let test_h2_security_rejects_invalid_stream_frame_envelopes () =
  expect_h2_security_error "DATA stream 0"
    (raw_h2_frame ~frame_type:0x0 ~flags:0 ~stream_id:0 "x");
  expect_h2_security_error "HEADERS stream 0"
    (raw_h2_frame ~frame_type:0x1 ~flags:0x4 ~stream_id:0 "");
  expect_h2_security_error "PRIORITY wrong length"
    (raw_h2_frame ~frame_type:0x2 ~flags:0 ~stream_id:1
       "\000\000\000\001");
  expect_h2_security_error "PRIORITY stream 0"
    (raw_h2_frame ~frame_type:0x2 ~flags:0 ~stream_id:0
       "\000\000\000\000\001");
  expect_h2_security_error "PUSH_PROMISE stream 0"
    (raw_h2_frame ~frame_type:0x5 ~flags:0x4 ~stream_id:0
       "\000\000\000\002");
  expect_h2_security_error "PUSH_PROMISE too short"
    (raw_h2_frame ~frame_type:0x5 ~flags:0x4 ~stream_id:1
       "\000\000\000");
  expect_h2_security_error "CONTINUATION stream 0"
    (raw_h2_frame ~frame_type:0x9 ~flags:0x4 ~stream_id:0 "")

let test_h2_security_rejects_invalid_continuation_envelopes () =
  expect_h2_security_error "CONTINUATION without HEADERS"
    (raw_h2_frame ~frame_type:0x9 ~flags:0x4 ~stream_id:1 "");
  expect_h2_security_error "CONTINUATION wrong stream"
    (raw_h2_frame ~frame_type:0x1 ~flags:0 ~stream_id:1 "a"
    ^ raw_h2_frame ~frame_type:0x9 ~flags:0x4 ~stream_id:3 "b");
  expect_h2_security_error "non-CONTINUATION during header block"
    (raw_h2_frame ~frame_type:0x1 ~flags:0 ~stream_id:1 "a"
    ^ raw_h2_frame ~frame_type:0x4 ~flags:0 ~stream_id:0 "")

let test_h2_security_accepts_valid_split_header_block () =
  expect_h2_security_ok "split HEADERS/CONTINUATION"
    (raw_h2_frame ~frame_type:0x1 ~flags:0 ~stream_id:1 "a"
    ^ raw_h2_frame ~frame_type:0x9 ~flags:0x4 ~stream_id:1 "b")

let test_h2_security_rejects_invalid_settings_payload_values () =
  expect_h2_security_error "SETTINGS_ENABLE_PUSH=2"
    (h2_settings_payload (h2_settings_pair 0x2 2));
  expect_h2_security_error "SETTINGS_MAX_FRAME_SIZE too small"
    (h2_settings_payload (h2_settings_pair 0x5 1));
  expect_h2_security_error "SETTINGS_INITIAL_WINDOW_SIZE too large"
    (h2_settings_payload (h2_settings_pair 0x4 0x80000000));
  expect_h2_security_ok "unknown SETTINGS identifier"
    (h2_settings_payload (h2_settings_pair 0xbeef 0x80000000))

let test_h2_security_allows_graceful_repeated_goaway () =
  let security = Eta_http.H2.Security.create () in
  let first = Eta_http.H2.Frame.goaway_no_error ~last_stream_id:3 in
  let second = Eta_http.H2.Frame.goaway_no_error ~last_stream_id:1 in
  Alcotest.(check bool) "first GOAWAY accepted" true
    (Option.is_none (observe_with security first));
  match observe_with security second with
  | None -> ()
  | Some kind ->
      Alcotest.failf "valid repeated GOAWAY rejected: %s"
        (Eta_http.Error.kind_name kind)

let test_h2_security_rejects_increasing_goaway_last_stream_id () =
  let security = Eta_http.H2.Security.create () in
  let first = Eta_http.H2.Frame.goaway_no_error ~last_stream_id:1 in
  let second = Eta_http.H2.Frame.goaway_no_error ~last_stream_id:3 in
  Alcotest.(check bool) "first GOAWAY accepted" true
    (Option.is_none (observe_with security first));
  match observe_with security second with
  | Some
      (Eta_http.Error.Connection_protocol_violation
        { kind = "goaway_last_stream_id_increase"; _ }) ->
      ()
  | Some kind ->
      Alcotest.failf "unexpected GOAWAY sequence error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "GOAWAY last_stream_id increase was accepted"
