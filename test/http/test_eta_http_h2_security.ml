open Test_eta_http_support
open Test_eta_http_h2_support

let test_now_ms () = 0L

let raw_h2_frame ~frame_type ~flags ~stream_id payload =
  h2_frame_header ~length:(String.length payload) ~frame_type ~flags ~stream_id
  ^ payload

let expect_h2_security_error label frame =
  match h2_observe_security frame with
  | Some (Eta_http.Error.Connection_protocol_violation _) -> ()
  | Some kind ->
      Alcotest.failf "%s: unexpected security error: %s" label
        (Eta_http.Error.kind_name kind)
  | None ->
      Alcotest.failf "%s: malformed frame passed H2.Security.observe_result"
        label

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
  Eta_http_h2.Frame.header ~length:(String.length payload)
    ~frame_type:Eta_http_h2.Frame.Settings ~flags:0 ~stream_id:0
  ^ payload

let observe_result_with ?(now_ms = 0L) security data =
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length data) data in
  Eta_http_h2.Security.observe_result security bs ~off:0
    ~len:(String.length data) ~now_ms

let observation_kind = function
  | Eta_http_h2.Security.Pass -> None
  | Eta_http_h2.Security.Connection_error { kind; _ }
  | Eta_http_h2.Security.Stream_error { kind; _ }
  | Eta_http_h2.Security.Policy_close { kind; _ } ->
      Some kind

let observe_with security data =
  observe_result_with security data |> observation_kind

let expect_h2_security_stream_error label ~stream_id frame =
  let security = Eta_http_h2.Security.create () in
  match observe_result_with security frame with
  | Eta_http_h2.Security.Stream_error { stream_id = observed; _ } ->
      Alcotest.(check int) (label ^ " stream") stream_id observed
  | Eta_http_h2.Security.Pass ->
      Alcotest.failf "%s: expected stream-scoped security error" label
  | Eta_http_h2.Security.Connection_error { kind; _ }
  | Eta_http_h2.Security.Policy_close { kind; _ } ->
      Alcotest.failf "%s: expected stream error, got %s" label
        (Eta_http.Error.kind_name kind)

let expect_h2_security_connection_error label frame =
  let security = Eta_http_h2.Security.create () in
  match observe_result_with security frame with
  | Eta_http_h2.Security.Connection_error _ -> ()
  | Eta_http_h2.Security.Pass ->
      Alcotest.failf "%s: expected connection-scoped security error" label
  | Eta_http_h2.Security.Stream_error { stream_id; kind; _ } ->
      Alcotest.failf "%s: expected connection error, got stream %d %s" label
        stream_id (Eta_http.Error.kind_name kind)
  | Eta_http_h2.Security.Policy_close { kind; _ } ->
      Alcotest.failf "%s: expected connection error, got policy close %s" label
        (Eta_http.Error.kind_name kind)

let test_h2_multiplexer_partial_frame_eof_is_protocol_error () =
  let errors = ref [] in
  let client =
    Eta_http_h2.Connection.Client.create
      ~error_handler:(fun error -> errors := error :: !errors) ()
  in
  let reader =
    Eta_http_eio.H2.Multiplexer.create_client_reader ~now_ms:test_now_ms
      ~buffer_size:8 client
  in
  let partial_headers =
    String.sub
      (h2_frame_header ~length:64 ~frame_type:0x1 ~flags:0 ~stream_id:1)
      0 8
  in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:8 partial_headers)
  in
  (match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
  | Read 8 -> ()
  | Read n -> Alcotest.failf "expected first read to consume 8 bytes, got %d" n
  | Security_error kind ->
      Alcotest.failf "partial frame produced security error before EOF: %s"
        (Eta_http.Error.kind_name kind)
  | Eof _ | Close -> Alcotest.fail "partial frame closed before EOF was read");
  (match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
  | Eof 0 -> ()
  | Eof n -> Alcotest.failf "expected EOF to consume 0 bytes, got %d" n
  | Read n -> Alcotest.failf "unexpected read after partial frame: %d" n
  | Security_error kind ->
      Alcotest.failf "EOF protocol error should come from h2 core, got %s"
        (Eta_http.Error.kind_name kind)
  | Close -> Alcotest.fail "partial frame closed without EOF");
  match !errors with
  | [ { Eta_http_h2.Connection.error_code = Eta_http_h2.Error_code.Protocol_error;
        message;
      } ]
    when String.equal message "transport EOF with incomplete HTTP/2 frame" ->
      ()
  | [ error ] ->
      Alcotest.failf "unexpected h2 client error: %a %s"
        Eta_http_h2.Error_code.pp_hum error.error_code error.message
  | [] -> Alcotest.fail "partial frame EOF did not report a protocol error"
  | _ :: _ :: _ -> Alcotest.fail "partial frame EOF reported multiple errors"

let test_h2_connection_rejects_oversized_frame () =
  let errors = ref [] in
  let client =
    Eta_http_h2.Connection.Client.create
      ~error_handler:(fun error -> errors := error :: !errors) ()
  in
  let frame =
    h2_frame_header
      ~length:(Eta_http_h2.Settings.default.max_frame_size + 1)
      ~frame_type:0x0 ~flags:0 ~stream_id:1
  in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
  let consumed =
    Eta_http_h2.Connection.read client bs ~off:0 ~len:(String.length frame)
  in
  Alcotest.(check int) "oversized frame header consumed" 9 consumed;
  match !errors with
  | [ { Eta_http_h2.Connection.error_code = Eta_http_h2.Error_code.Frame_size_error;
        message = _;
      } ] ->
      ()
  | [ error ] ->
      Alcotest.failf "unexpected oversized-frame error: %a %s"
        Eta_http_h2.Error_code.pp_hum error.error_code error.message
  | [] -> Alcotest.fail "oversized frame did not report a frame-size error"
  | _ :: _ :: _ -> Alcotest.fail "oversized frame reported multiple errors"

let test_h2_security_settings_churn_reader () =
  let client =
    Eta_http_h2.Connection.Client.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected h2 client error")
      ()
  in
  let reader =
    Eta_http_eio.H2.Multiplexer.create_client_reader ~now_ms:test_now_ms
      ~buffer_size:64 client
  in
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
          (Settings_count_exceeded { observed_count; limit }) ->
          Alcotest.(check int) "observed" 11 observed_count;
          Alcotest.(check int) "limit" 10 limit
      | Security_error kind ->
          Alcotest.failf "unexpected security error: %s"
            (Eta_http.Error.kind_name kind)
      | Read _ | Eof _ -> loop (attempts - 1)
      | Close -> Alcotest.fail "client closed before settings churn detection"
  in
  loop 32

let test_h2_security_rejects_churn_floods () =
  let rate_limit =
    { Eta_http_h2.Security.burst = 2; window_ms = 1_000; max_per_connection = None }
  in
  let config =
    {
      Eta_http_h2.Security.default_config with
      ping_rate = rate_limit;
      empty_data_rate = rate_limit;
      window_update_rate = rate_limit;
    }
  in
  let expect_error label expected frame =
    let security = Eta_http_h2.Security.create ~config () in
    match observe_with security frame with
    | Some kind when String.equal (Eta_http.Error.kind_name kind) expected -> ()
    | Some kind ->
        Alcotest.failf "%s: unexpected security error: %s" label
          (Eta_http.Error.kind_name kind)
    | None -> Alcotest.failf "%s: flood passed H2.Security.observe_result" label
  in
  expect_error "PING churn" "Ping_count_exceeded"
    (String.concat ""
       (List.init 3 (fun _ ->
            raw_h2_frame ~frame_type:0x6 ~flags:0 ~stream_id:0 "12345678")));
  expect_error "empty DATA churn" "Empty_data_frame_count_exceeded"
    (String.concat ""
       (List.init 3 (fun _ ->
            raw_h2_frame ~frame_type:0x0 ~flags:0 ~stream_id:1 "")));
  expect_error "WINDOW_UPDATE churn" "Window_update_count_exceeded"
    (String.concat ""
      (List.init 3 (fun _ ->
            raw_h2_frame ~frame_type:0x8 ~flags:0 ~stream_id:0
              (h2_uint32 1))))

let test_h2_security_allows_long_lived_ping_keepalive () =
  let config =
    {
      Eta_http_h2.Security.default_config with
      ping_rate =
        {
          Eta_http_h2.Security.burst = 2;
          window_ms = 1_000;
          max_per_connection = Some 1_000;
        };
    }
  in
  let security = Eta_http_h2.Security.create ~config () in
  let ping = raw_h2_frame ~frame_type:0x6 ~flags:0 ~stream_id:0 "12345678" in
  for index = 0 to 150 do
    match observe_result_with ~now_ms:(Int64.of_int (index * 30_000)) security ping with
    | Eta_http_h2.Security.Pass -> ()
    | Eta_http_h2.Security.Connection_error { kind; _ }
    | Eta_http_h2.Security.Stream_error { kind; _ }
    | Eta_http_h2.Security.Policy_close { kind; _ } ->
        Alcotest.failf "keepalive ping %d rejected: %s" index
          (Eta_http.Error.kind_name kind)
  done

let test_h2_security_rejects_ping_burst () =
  let config =
    {
      Eta_http_h2.Security.default_config with
      ping_rate =
        {
          Eta_http_h2.Security.burst = 2;
          window_ms = 1_000;
          max_per_connection = None;
        };
    }
  in
  let security = Eta_http_h2.Security.create ~config () in
  let ping = raw_h2_frame ~frame_type:0x6 ~flags:0 ~stream_id:0 "12345678" in
  let rec loop count =
    match observe_result_with ~now_ms:0L security ping with
    | Eta_http_h2.Security.Pass when count < 3 -> loop (count + 1)
    | Eta_http_h2.Security.Policy_close
        { kind = Eta_http.Error.Ping_count_exceeded { observed_count; limit }; _ } ->
        Alcotest.(check int) "observed" 3 observed_count;
        Alcotest.(check int) "limit" 2 limit
    | Eta_http_h2.Security.Pass ->
        Alcotest.fail "PING burst passed H2.Security"
    | Eta_http_h2.Security.Connection_error { kind; _ }
    | Eta_http_h2.Security.Stream_error { kind; _ }
    | Eta_http_h2.Security.Policy_close { kind; _ } ->
        Alcotest.failf "unexpected PING burst error: %s"
          (Eta_http.Error.kind_name kind)
  in
  loop 1

let test_h2_security_rejects_settings_burst () =
  let config =
    {
      Eta_http_h2.Security.default_config with
      settings_rate =
        {
          Eta_http_h2.Security.burst = 2;
          window_ms = 1_000;
          max_per_connection = None;
        };
    }
  in
  let security = Eta_http_h2.Security.create ~config () in
  let rec loop count =
    match observe_result_with ~now_ms:0L security h2_settings_frame with
    | Eta_http_h2.Security.Pass when count < 3 -> loop (count + 1)
    | Eta_http_h2.Security.Policy_close
        { kind = Eta_http.Error.Settings_count_exceeded { observed_count; limit }; _ } ->
        Alcotest.(check int) "observed" 3 observed_count;
        Alcotest.(check int) "limit" 2 limit
    | Eta_http_h2.Security.Pass ->
        Alcotest.fail "SETTINGS burst passed H2.Security"
    | Eta_http_h2.Security.Connection_error { kind; _ }
    | Eta_http_h2.Security.Stream_error { kind; _ }
    | Eta_http_h2.Security.Policy_close { kind; _ } ->
        Alcotest.failf "unexpected SETTINGS burst error: %s"
          (Eta_http.Error.kind_name kind)
  in
  loop 1

let test_h2_security_allows_large_window_update_sequence () =
  let config =
    {
      Eta_http_h2.Security.default_config with
      window_update_rate =
        {
          Eta_http_h2.Security.burst = 4;
          window_ms = 1_000;
          max_per_connection = Some 20_000;
        };
    }
  in
  let security = Eta_http_h2.Security.create ~config () in
  let window_update =
    raw_h2_frame ~frame_type:0x8 ~flags:0 ~stream_id:0 (h2_uint32 65_535)
  in
  for index = 0 to 10_050 do
    match observe_result_with ~now_ms:(Int64.of_int (index * 1_000)) security window_update with
    | Eta_http_h2.Security.Pass -> ()
    | Eta_http_h2.Security.Connection_error { kind; _ }
    | Eta_http_h2.Security.Stream_error { kind; _ }
    | Eta_http_h2.Security.Policy_close { kind; _ } ->
        Alcotest.failf "WINDOW_UPDATE %d rejected: %s" index
          (Eta_http.Error.kind_name kind)
  done

let test_h2_security_classifies_stream_scoped_errors () =
  expect_h2_security_stream_error "PRIORITY wrong length" ~stream_id:3
    (raw_h2_frame ~frame_type:0x2 ~flags:0 ~stream_id:3
       "\000\000\000\001");
  expect_h2_security_stream_error "stream WINDOW_UPDATE zero" ~stream_id:5
    (raw_h2_frame ~frame_type:0x8 ~flags:0 ~stream_id:5 (h2_uint32 0));
  expect_h2_security_connection_error "connection WINDOW_UPDATE zero"
    (raw_h2_frame ~frame_type:0x8 ~flags:0 ~stream_id:0 (h2_uint32 0))

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
  let security = Eta_http_h2.Security.create () in
  let first = Eta_http_h2.Frame.goaway_no_error ~last_stream_id:3 in
  let second = Eta_http_h2.Frame.goaway_no_error ~last_stream_id:1 in
  Alcotest.(check bool) "first GOAWAY accepted" true
    (Option.is_none (observe_with security first));
  match observe_with security second with
  | None -> ()
  | Some kind ->
      Alcotest.failf "valid repeated GOAWAY rejected: %s"
        (Eta_http.Error.kind_name kind)

let test_h2_security_rejects_increasing_goaway_last_stream_id () =
  let security = Eta_http_h2.Security.create () in
  let first = Eta_http_h2.Frame.goaway_no_error ~last_stream_id:1 in
  let second = Eta_http_h2.Frame.goaway_no_error ~last_stream_id:3 in
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

let test_h2_security_complete_stream_bounds_header_state () =
  let config =
    {
      Eta_http_h2.Security.default_config with
      max_response_headers_per_stream = 1;
    }
  in
  let security = Eta_http_h2.Security.create ~config () in
  let headers stream_id =
    raw_h2_frame ~frame_type:0x1 ~flags:0x4 ~stream_id ""
  in
  let expect_ok label frame =
    match observe_with security frame with
    | None -> ()
    | Some kind ->
        Alcotest.failf "%s: unexpected security error: %s" label
          (Eta_http.Error.kind_name kind)
  in
  expect_ok "first stream 1 HEADERS" (headers 1);
  Alcotest.(check int) "tracked after HEADERS" 1
    (Eta_http_h2.Security.tracked_header_streams security);
  Eta_http_h2.Security.complete_stream security 1;
  Alcotest.(check int) "tracked after complete" 0
    (Eta_http_h2.Security.tracked_header_streams security);
  expect_ok "stream 1 HEADERS after complete" (headers 1);
  Eta_http_h2.Security.complete_stream security 1;
  for index = 0 to 127 do
    let stream_id = (2 * index) + 1 in
    expect_ok
      (Printf.sprintf "stream %d HEADERS" stream_id)
      (headers stream_id);
    Eta_http_h2.Security.complete_stream security stream_id
  done;
  Alcotest.(check int) "tracked after many complete streams" 0
    (Eta_http_h2.Security.tracked_header_streams security)
