open Test_eta_http_support
open Test_eta_http_h2_support

let test_h2_frame_parse_header () =
  let base =
    Eta_http.H2.Frame.header ~length:0x010203 ~frame_type:(Other 0xfe)
      ~flags:0xa5 ~stream_id:0x01020304
  in
  let raw = Bytes.of_string base in
  Bytes.set raw 5 (Char.chr (Char.code (Bytes.get raw 5) lor 0x80));
  let data = Bytes.unsafe_to_string raw in
  let check label envelope =
    let open Eta_http.H2.Frame in
    Alcotest.(check int) (label ^ " length") 0x010203 envelope.length;
    Alcotest.(check int) (label ^ " type") 0xfe envelope.frame_type;
    Alcotest.(check int) (label ^ " flags") 0xa5 envelope.flags;
    Alcotest.(check int) (label ^ " stream_id") 0x01020304 envelope.stream_id
  in
  check "string" (Eta_http.H2.Frame.parse_header_string data ~off:0);
  check "bytes" (Eta_http.H2.Frame.parse_header_bytes raw ~off:0);
  let buffer = Buffer.create 16 in
  Buffer.add_string buffer data;
  check "buffer" (Eta_http.H2.Frame.parse_header_buffer buffer ~off:0)

let test_h2_multiplexer_buffer_full_is_security_error () =
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> Alcotest.fail "unexpected h2 client error")
      ()
  in
  let reader = Eta_http.H2.Multiplexer.create_client_reader ~buffer_size:8 client in
  let partial_headers =
    String.sub
      (h2_frame_header ~length:64 ~frame_type:0x1 ~flags:0 ~stream_id:1)
      0 8
  in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:8 partial_headers)
  in
  match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
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
  let reader = Eta_http.H2.Multiplexer.create_client_reader ~buffer_size:64 client in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:11 (String.concat "" (List.init 11 (fun _ -> h2_settings_frame))))
  in
  let rec loop attempts =
    if attempts = 0 then Alcotest.fail "settings churn was not detected"
    else
      match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Security_error (Settings_churn_rate_exceeded { observed_rate_hz; limit_hz }) ->
          Alcotest.(check int) "observed" 11 observed_rate_hz;
          Alcotest.(check int) "limit" 10 limit_hz
      | Security_error kind ->
          Alcotest.failf "unexpected security error: %s"
            (Eta_http.Error.kind_name kind)
      | Read _ | Eof _ -> loop (attempts - 1)
      | Close -> Alcotest.fail "client closed before settings churn detection"
  in
  loop 32

let test_h2_security_hpack_block_cap () =
  let frame =
    h2_frame_header ~length:(300 * 1024) ~frame_type:0x1 ~flags:0x4
      ~stream_id:1
  in
  match h2_observe_security frame with
  | Some (Hpack_decode_overflow { decoded_bytes; limit_bytes }) ->
      Alcotest.(check int) "decoded" (300 * 1024) decoded_bytes;
      Alcotest.(check int) "limit" (256 * 1024) limit_bytes
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "hpack block cap was not detected"

let test_h2_security_continuation_cap () =
  let data =
    h2_frame_header ~length:(40 * 1024) ~frame_type:0x1 ~flags:0
      ~stream_id:1
    ^ h2_payload (40 * 1024)
    ^ h2_frame_header ~length:(30 * 1024) ~frame_type:0x9 ~flags:0x4
        ~stream_id:1
  in
  match h2_observe_security data with
  | Some (Continuation_flood { accumulated_bytes; limit_bytes; frames }) ->
      Alcotest.(check int) "accumulated" (70 * 1024) accumulated_bytes;
      Alcotest.(check int) "limit" (64 * 1024) limit_bytes;
      Alcotest.(check int) "frames" 2 frames
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "continuation cap was not detected"

let test_h2_security_rejects_oversized_initial_headers_fragment () =
  let config =
    {
      Eta_http.H2.Security.default_config with
      max_hpack_block_bytes = 1024;
      max_continuation_accumulator_bytes = 16;
    }
  in
  let security = Eta_http.H2.Security.create ~config () in
  let frame =
    Eta_http.H2.Frame.header ~length:17
      ~frame_type:Eta_http.H2.Frame.Headers ~flags:0 ~stream_id:1
  in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
  match
    Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
  with
  | Some
      (Eta_http.Error.Continuation_flood
        { accumulated_bytes; limit_bytes; _ }) ->
      Alcotest.(check int) "accumulated" 17 accumulated_bytes;
      Alcotest.(check int) "limit" 16 limit_bytes
  | Some kind ->
      Alcotest.failf "unexpected error: %s" (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "oversized initial HEADERS fragment was accepted"

let test_h2_security_rejects_oversized_push_promise_fragment () =
  let config =
    {
      Eta_http.H2.Security.default_config with
      max_hpack_block_bytes = 16;
      max_continuation_accumulator_bytes = 16;
    }
  in
  let security = Eta_http.H2.Security.create ~config () in
  let payload_len = 4 + 17 in
  let frame =
    Eta_http.H2.Frame.header ~length:payload_len
      ~frame_type:Eta_http.H2.Frame.Push_promise ~flags:0x4 ~stream_id:1
    ^ Eta_http.H2.Frame.uint32 2
    ^ String.make 17 '\000'
  in
  let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
  match
    Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
  with
  | Some (Eta_http.Error.Hpack_decode_overflow { decoded_bytes; limit_bytes }) ->
      Alcotest.(check int) "decoded" payload_len decoded_bytes;
      Alcotest.(check int) "limit" 16 limit_bytes
  | Some kind ->
      Alcotest.failf "unexpected error: %s" (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "oversized PUSH_PROMISE fragment was accepted"

let test_h2_security_goaway_churn () =
  let data =
    h2_goaway_no_error ~last_stream_id:1
    ^ h2_goaway_no_error ~last_stream_id:1
  in
  match h2_observe_security data with
  | Some (Connection_closed { during = Http_response }) -> ()
  | Some kind ->
      Alcotest.failf "unexpected security error: %s"
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.fail "GOAWAY churn was not detected"

let test_h2_security_header_churn () =
  let frame =
    h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
  in
  let data = String.concat "" (List.init 33 (fun _ -> frame)) in
  match h2_observe_security data with
  | Some
      (Response_header_change_rate_exceeded
        { observed_rate_hz; limit_hz }) ->
      Alcotest.(check int) "observed" 33 observed_rate_hz;
      Alcotest.(check int) "limit" 32 limit_hz
  | Some kind ->
	      Alcotest.failf "unexpected security error: %s"
	        (Eta_http.Error.kind_name kind)
	  | None -> Alcotest.fail "header churn was not detected"

let test_h2_security_allows_many_normal_response_headers () =
  let frame stream_id =
    h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id
  in
  let data =
    String.concat "" (List.init 100 (fun index -> frame ((index * 2) + 1)))
  in
  match h2_observe_security data with
  | None -> ()
  | Some kind ->
      Alcotest.failf "normal response headers tripped security: %s"
        (Eta_http.Error.kind_name kind)

let test_h2_security_forgets_completed_stream_headers () =
  let config =
    {
      Eta_http.H2.Security.default_config with
      max_response_headers_per_connection = 1;
    }
  in
  let security = Eta_http.H2.Security.create ~config () in
  let frame =
    h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
  in
  let observe () =
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
    Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
  in
  (match observe () with
  | None -> ()
  | Some kind ->
      Alcotest.failf "first headers tripped security: %s"
        (Eta_http.Error.kind_name kind));
  Eta_http.H2.Security.complete_stream security 1;
  match observe () with
  | None -> ()
  | Some kind ->
      Alcotest.failf "completed stream header state was retained: %s"
        (Eta_http.Error.kind_name kind)

let test_h2_security_multiplexer_release_forgets_stream_headers () =
  let config =
    {
      Eta_http.H2.Security.default_config with
      max_response_headers_per_connection = 1;
    }
  in
  let security = Eta_http.H2.Security.create ~config () in
  let mux = Eta_http.H2.Multiplexer.create ~security () in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/release"
  in
  let opened =
    match
      Eta_http.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream error")
        ~response_handler:(fun _ _ _ -> Alcotest.fail "unexpected response")
    with
    | Ok opened -> opened
    | Error (Eta_http.H2.Multiplexer.Admission_rejected { limit }) ->
        Alcotest.failf "request rejected by admission limit %d" limit
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "request rejected by closed connection"
    | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "request failed: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  let frame =
    h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1
  in
  let observe () =
    let bs = Bigstringaf.of_string ~off:0 ~len:(String.length frame) frame in
    Eta_http.H2.Security.observe security bs ~off:0 ~len:(String.length frame)
  in
  (match observe () with
  | None -> ()
  | Some kind ->
      Alcotest.failf "first headers tripped security: %s"
        (Eta_http.Error.kind_name kind));
  ignore (Eta_http.H2.Multiplexer.release mux opened.stream);
  match observe () with
  | None -> ()
  | Some kind ->
      Alcotest.failf "released stream header state was retained: %s"
        (Eta_http.Error.kind_name kind)

let expect_header_invalid label headers =
  match Eta_http.H2.Security.validate_headers headers with
  | Some (Header_invalid _) -> ()
  | Some kind ->
      Alcotest.failf "%s unexpected error: %s" label
        (Eta_http.Error.kind_name kind)
  | None -> Alcotest.failf "%s was accepted" label

let test_h2_security_header_normalization_edges () =
  expect_header_invalid "empty" [ "", "value" ];
  expect_header_invalid "nul name" [ "x\000bad", "value" ];
  expect_header_invalid "nul value" [ "x-good", "bad\000value" ];
  expect_header_invalid "uppercase" [ "X-Bad", "value" ];
  expect_header_invalid "crlf name" [ "x-good\r\ninjected", "value" ];
  expect_header_invalid "crlf value" [ "x-good", "ok\r\ninjected: 1" ];
  expect_header_invalid "lf value" [ "x-good", "ok\ninjected: 1" ];
  expect_header_invalid "cr value" [ "x-good", "ok\rinjected: 1" ];
  expect_header_invalid "obs-fold value" [ "x-good", "ok\n injected: 1" ];
  expect_header_invalid "bad token name" [ "x bad", "value" ];
  expect_header_invalid "long name" [ String.make (8 * 1024 + 1) 'x', "value" ];
  expect_header_invalid "long value" [ "x-good", String.make (64 * 1024 + 1) 'x' ];
  Alcotest.(check bool) "valid" true
    (Option.is_none
       (Eta_http.H2.Security.validate_headers [ "x-good", "value" ]))
