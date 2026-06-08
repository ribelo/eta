open Test_eta_http_support

type read_action = Return of string | Await : unit Eio.Promise.t -> read_action
type write_gate = { write_started : unit Eio.Promise.u; write_release : unit Eio.Promise.t }

type scripted_flow = {
  reads : read_action Stdlib.Queue.t;
  write_gates : write_gate Stdlib.Queue.t;
  mutable pending : string option;
  writes : Buffer.t;
  mutable closed : int;
}

module Scripted_flow = struct
  type t = scripted_flow

  let read_methods = []

  let rec next_chunk t =
    match t.pending with
    | Some chunk -> chunk
    | None -> (
        match Stdlib.Queue.take_opt t.reads with
        | Some (Return chunk) -> chunk
        | Some (Await promise) ->
            Eio.Promise.await promise;
            raise End_of_file
        | None -> raise End_of_file)

  let single_read t dst =
    let chunk = next_chunk t in
    let len = min (String.length chunk) (Cstruct.length dst) in
    Cstruct.blit_from_string chunk 0 dst 0 len;
    if len = String.length chunk then t.pending <- None
    else t.pending <- Some (String.sub chunk len (String.length chunk - len));
    len

  let single_write t bufs =
    (match Stdlib.Queue.take_opt t.write_gates with
    | None -> ()
    | Some gate ->
        Eio.Promise.resolve gate.write_started ();
        Eio.Promise.await gate.write_release);
    List.iter (fun buf -> Buffer.add_string t.writes (Cstruct.to_string buf)) bufs;
    Cstruct.lenv bufs

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown _ _ = ()
  let close t = t.closed <- t.closed + 1
end

let scripted_flow actions =
  let reads = Stdlib.Queue.create () in
  List.iter (fun action -> Stdlib.Queue.push action reads) actions;
  let state =
    {
      reads;
      write_gates = Stdlib.Queue.create ();
      pending = None;
      writes = Buffer.create 512;
      closed = 0;
    }
  in
  let flow : Eta_http.Ws.Client.flow =
    Eio.Resource.T
      ( state,
        Eio.Resource.handler
          (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings
               (Eio.Flow.Pi.two_way (module Scripted_flow))) )
  in
  (state, flow)

let gate_next_write state ~started ~release =
  Stdlib.Queue.push { write_started = started; write_release = release }
    state.write_gates

let switching_response ?protocol key =
  "HTTP/1.1 101 Switching Protocols\r\n"
  ^ "Upgrade: websocket\r\n"
  ^ "Connection: keep-alive, Upgrade\r\n"
  ^ "Sec-WebSocket-Accept: "
  ^ Eta_http.Ws.Codec.accept_key key
  ^ "\r\n"
  ^ (match protocol with
    | None -> ""
    | Some protocol -> "Sec-WebSocket-Protocol: " ^ protocol ^ "\r\n")
  ^ "\r\n"

let close_payload code reason =
  let payload = Bytes.create (2 + String.length reason) in
  Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
  Bytes.set payload 1 (Char.chr (code land 0xff));
  Bytes.blit_string reason 0 payload 2 (String.length reason);
  payload

let find_headers_end value =
  let rec loop index =
    if index + 3 >= String.length value then None
    else if String.equal "\r\n\r\n" (String.sub value index 4) then Some (index + 4)
    else loop (index + 1)
  in
  loop 0

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let request_target raw =
  match String.split_on_char '\n' raw with
  | request_line :: _ -> (
      match String.split_on_char ' ' request_line with
      | _method_ :: target :: _ -> Some target
      | _ -> None)
  | [] -> None

let header_value name raw =
  let expected = String.lowercase_ascii name in
  raw |> String.split_on_char '\n'
  |> List.find_map (fun line ->
         let line =
           let len = String.length line in
           if len > 0 && Char.equal line.[len - 1] '\r' then
             String.sub line 0 (len - 1)
           else line
         in
         match String.index_opt line ':' with
         | None -> None
         | Some index ->
             let actual =
               String.sub line 0 index |> String.trim |> String.lowercase_ascii
             in
             if String.equal actual expected then
               Some
                 (String.sub line (index + 1) (String.length line - index - 1)
                  |> String.trim)
             else None)

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec contains_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then false
  else if String.sub haystack index needle_len = needle then true
  else contains_from haystack ~needle (index + 1)

let contains haystack needle = contains_from haystack ~needle 0

let find_ws_client_source () =
  let candidates =
    [
      "lib/http/ws/ws_client.ml";
      "../lib/http/ws/ws_client.ml";
      "../../lib/http/ws/ws_client.ml";
      "../../../lib/http/ws/ws_client.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate ws_client.ml from %s" (Sys.getcwd ())

let has_suffix suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  value_len >= suffix_len
  && String.equal suffix
       (String.sub value (value_len - suffix_len) suffix_len)

let read_http_head flow =
  let scratch = Cstruct.create 1 in
  let buffer = Buffer.create 512 in
  let rec loop () =
    let read = Eio.Flow.single_read flow scratch in
    if read = 0 then raise End_of_file;
    Buffer.add_char buffer (Cstruct.get_char scratch 0);
    let contents = Buffer.contents buffer in
    if has_suffix "\r\n\r\n" contents then contents else loop ()
  in
  loop ()

let bytes_concat chunks =
  let len = List.fold_left (fun acc chunk -> acc + Bytes.length chunk) 0 chunks in
  let out = Bytes.create len in
  let off = ref 0 in
  List.iter
    (fun chunk ->
      Bytes.blit chunk 0 out !off (Bytes.length chunk);
      off := !off + Bytes.length chunk)
    chunks;
  out

let read_exact flow len =
  let out = Cstruct.create len in
  let rec loop off =
    if off = len then Cstruct.to_bytes out
    else
      let read = Eio.Flow.single_read flow (Cstruct.sub out off (len - off)) in
      if read = 0 then raise End_of_file else loop (off + read)
  in
  loop 0

let ws_payload_len header ext =
  match Char.code (Bytes.get header 1) land 0x7f with
  | value when value < 126 -> value
  | 126 ->
      (Char.code (Bytes.get ext 0) lsl 8) lor Char.code (Bytes.get ext 1)
  | _ ->
      let acc = ref 0L in
      for index = 0 to 7 do
        acc :=
          Int64.logor
            (Int64.shift_left !acc 8)
            (Int64.of_int (Char.code (Bytes.get ext index)))
      done;
      Int64.to_int !acc

let read_ws_frame ~masked flow =
  let header = read_exact flow 2 in
  let len_code = Char.code (Bytes.get header 1) land 0x7f in
  let ext_len = if len_code < 126 then 0 else if len_code = 126 then 2 else 8 in
  let ext = read_exact flow ext_len in
  let mask_len = if Char.code (Bytes.get header 1) land 0x80 = 0 then 0 else 4 in
  let mask = read_exact flow mask_len in
  let payload = read_exact flow (ws_payload_len header ext) in
  match Eta_http.Ws.Codec.decode ~masked (bytes_concat [ header; ext; mask; payload ]) with
  | Ok (frame, _) -> frame
  | Error error ->
      Alcotest.failf "WebSocket frame decode failed: %s"
        (Eta_http.Ws.Codec.parse_error_to_string error)

let write_ws_switching_response ?protocol flow key =
  Eio.Flow.copy_string (switching_response ?protocol key) flow

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let find_source label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate %s from %s" label (Sys.getcwd ())

let find_ws_source file =
  find_source file
    [
      "lib/http/ws/" ^ file;
      "../lib/http/ws/" ^ file;
      "../../lib/http/ws/" ^ file;
      "../../../lib/http/ws/" ^ file;
    ]

let run_echo_ws_server ?expect_target ?protocol ~messages flow =
  let head = read_http_head flow in
  (match expect_target with
  | None -> ()
  | Some expected ->
      Alcotest.(check (option string)) "request target" (Some expected)
        (request_target head));
  let key =
    match header_value "Sec-WebSocket-Key" head with
    | Some key -> key
    | None -> Alcotest.fail "missing Sec-WebSocket-Key"
  in
  write_ws_switching_response ?protocol flow key;
  for _ = 1 to messages do
    let frame = read_ws_frame ~masked:true flow in
    let opcode = frame.Eta_http.Ws.Codec.opcode in
    match opcode with
    | Text | Binary ->
        Eta_http.Ws.Codec.encode
          { fin = true; opcode; payload = frame.payload }
        |> Bytes.to_string |> fun encoded -> Eio.Flow.copy_string encoded flow
    | Close -> ()
    | Continuation | Ping | Pong -> Alcotest.fail "unexpected client frame"
  done;
  Eta_http.Ws.Codec.encode
    { fin = true; opcode = Close; payload = close_payload 1000 "" }
  |> Bytes.to_string |> fun encoded -> Eio.Flow.copy_string encoded flow;
  try Eio.Flow.shutdown flow `Send with _ -> ()

let client_frame_after_upgrade state =
  let written = Buffer.contents state.writes in
  match find_headers_end written with
  | None -> Alcotest.fail "client upgrade request terminator missing"
  | Some off ->
      Bytes.of_string (String.sub written off (String.length written - off))

let client_frames_after_upgrade state =
  let bytes = client_frame_after_upgrade state in
  let rec loop off acc =
    if off = Bytes.length bytes then List.rev acc
    else
      match
        Eta_http.Ws.Codec.decode ~masked:true
          (Bytes.sub bytes off (Bytes.length bytes - off))
      with
      | Ok (frame, consumed) when consumed > 0 -> loop (off + consumed) (frame :: acc)
      | Ok _ -> Alcotest.fail "client frame decoder consumed no bytes"
      | Error error ->
          Alcotest.failf "client frame did not decode: %s"
            (Eta_http.Ws.Codec.parse_error_to_string error)
  in
  loop 0 []

let expect_client_frame state opcode payload =
  match Eta_http.Ws.Codec.decode ~masked:true (client_frame_after_upgrade state) with
  | Ok ({ Eta_http.Ws.Codec.opcode = actual_opcode; payload = actual_payload; _ }, _) ->
      Alcotest.(check int)
        "opcode" (Eta_http.Ws.Codec.opcode_to_int opcode)
        (Eta_http.Ws.Codec.opcode_to_int actual_opcode);
      Alcotest.(check string) "payload" payload (Bytes.to_string actual_payload)
  | Error error ->
      Alcotest.failf "client frame did not decode: %s"
        (Eta_http.Ws.Codec.parse_error_to_string error)

let test_ws_accept_key_vector () =
  Alcotest.(check string)
    "accept" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (Eta_http.Ws.Codec.accept_key "dGhlIHNhbXBsZSBub25jZQ==")

let test_ws_codec_masked_text_roundtrip () =
  let mask = Bytes.of_string "\x37\xfa\x21\x3d" in
  let encoded =
    Eta_http.Ws.Codec.encode ~mask
      { fin = true; opcode = Text; payload = Bytes.of_string "Hello" }
  in
  match Eta_http.Ws.Codec.decode ~masked:true encoded with
  | Ok ({ opcode = Text; payload; _ }, consumed) ->
      Alcotest.(check int) "consumed" (Bytes.length encoded) consumed;
      Alcotest.(check string) "payload" "Hello" (Bytes.to_string payload)
  | Ok _ -> Alcotest.fail "decoded unexpected frame"
  | Error error ->
      Alcotest.failf "masked frame failed: %s"
        (Eta_http.Ws.Codec.parse_error_to_string error)

let test_ws_codec_rejects_one_byte_close_payload () =
  let frame = Bytes.of_string "\x88\x01\000" in
  match Eta_http.Ws.Codec.decode frame with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "one-byte close payload decoded successfully"

let test_ws_codec_rejects_encoded_one_byte_close_payload () =
  Alcotest.check_raises "one-byte close payload rejected"
    (Invalid_argument
       "WebSocket close frame payload must be empty or at least two bytes")
    (fun () ->
      ignore
        (Eta_http.Ws.Codec.encode
           { fin = true; opcode = Close; payload = Bytes.of_string "\000" }
          : bytes))

let close_status_payload code =
  let payload = Bytes.create 2 in
  Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
  Bytes.set payload 1 (Char.chr (code land 0xff));
  payload

let raw_close_frame code =
  let frame = Bytes.create 4 in
  Bytes.set frame 0 (Char.chr 0x88);
  Bytes.set frame 1 (Char.chr 0x02);
  Bytes.blit (close_status_payload code) 0 frame 2 2;
  frame

let test_ws_codec_rejects_invalid_close_status_codes () =
  List.iter
    (fun code ->
      match Eta_http.Ws.Codec.decode (raw_close_frame code) with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "accepted invalid close status code %d" code)
    [ 999; 1004; 1005; 1006; 1015; 5000 ]

let test_ws_codec_encoder_rejects_invalid_close_status_code () =
  let frame : Eta_http.Ws.Codec.frame =
    { fin = true; opcode = Close; payload = close_status_payload 1005 }
  in
  match Eta_http.Ws.Codec.encode frame with
  | _ -> Alcotest.fail "encoded invalid close status code 1005"
  | exception Invalid_argument message ->
      Alcotest.(check bool)
        "mentions close status" true
        (contains message "close")

let test_ws_random_material_does_not_use_stdlib_random () =
  let codec = read_file (find_ws_source "codec.ml") in
  let client = read_file (find_ws_source "ws_client.ml") in
  Alcotest.(check bool) "codec avoids Stdlib.Random" false
    (contains codec "Stdlib.Random");
  Alcotest.(check bool) "client avoids Stdlib.Random" false
    (contains client "Stdlib.Random")

let test_ws_accept_key_does_not_own_sha1 () =
  let codec = read_file (find_ws_source "codec.ml") in
  Alcotest.(check bool) "codec does not define SHA-1" false
    (contains codec "let sha1");
  Alcotest.(check bool) "codec does not implement SHA-1 rounds" false
    (contains codec "let open Int32")

let test_ws_connect_reads_inbound_text () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let frame =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Text; payload = Bytes.of_string "ready" }
    |> Bytes.to_string
  in
  let state, flow = scripted_flow [ Return (switching_response key ^ frame) ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime?model=x" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let messages =
    Eta_http.Ws.Client.incoming conn
    |> Eta_stream.Stream.take 1
    |> Eta_stream.run_collect
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "upgrade request path" true
    (contains (Buffer.contents state.writes) "GET /realtime?model=x HTTP/1.1");
  Alcotest.(check (list string))
    "messages" [ "ready" ]
    (List.map (function `Text text -> text | `Binary _ -> "<binary>") messages)

let test_ws_rejects_oversized_frame_before_payload_read () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let header = Bytes.create 10 in
  Bytes.set header 0 (Char.chr 0x82);
  Bytes.set header 1 (Char.chr 0x7f);
  Bytes.set header 2 (Char.chr 0x00);
  Bytes.set header 3 (Char.chr 0x00);
  Bytes.set header 4 (Char.chr 0x00);
  Bytes.set header 5 (Char.chr 0x00);
  Bytes.set header 6 (Char.chr 0x00);
  Bytes.set header 7 (Char.chr 0x10);
  Bytes.set header 8 (Char.chr 0x00);
  Bytes.set header 9 (Char.chr 0x01);
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ Bytes.to_string header) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn)) with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        (`Protocol "WebSocket frame payload exceeds max_frame_size")) ->
      ()
  | Eta.Exit.Ok () -> Alcotest.fail "oversized WebSocket frame was accepted"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected oversized frame failure: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
          | `Connect message -> Format.fprintf fmt "connect %s" message
          | `Protocol message -> Format.fprintf fmt "protocol %s" message
          | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
          | `Timeout -> Format.pp_print_string fmt "timeout"))
        cause

let test_ws_rejects_64bit_length_with_msb_set_as_protocol_error () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  (* Binary frame, length code 127, extended 64-bit length 0xC000_0000_0000_0000.
     As a signed Int64 this is negative, so it slips past the upper-bound
     checks, and Int64.to_int yields a negative length. It must be rejected as a
     typed protocol error, not allocate a negative-length buffer and crash. *)
  let malicious_header = "\x82\x7f\xc0\x00\x00\x00\x00\x00\x00\x00" in
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ malicious_header) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/ws" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match
    Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn))
  with
  | Eta.Exit.Error (Eta.Cause.Fail (`Protocol _)) -> ()
  | Eta.Exit.Error (Eta.Cause.Die _) ->
      Alcotest.fail "negative 64-bit payload length escaped as defect"
  | Eta.Exit.Ok () -> Alcotest.fail "expected protocol error"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
          | `Connect message -> Format.fprintf fmt "connect %s" message
          | `Protocol message -> Format.fprintf fmt "protocol %s" message
          | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
          | `Timeout -> Format.pp_print_string fmt "timeout"))
        cause

let test_ws_send_text_masks_client_frame () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let never, _resolver = Eio.Promise.create () in
  let state, flow = scripted_flow [ Return (switching_response key); Await never ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Eta_http.Ws.Client.send_text conn "hello"
  |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok;
  expect_client_frame state Text "hello"

let test_ws_queued_send_observes_close_sent () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let never, _resolver = Eio.Promise.create () in
  let state, flow = scripted_flow [ Return (switching_response key); Await never ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let first_started, first_started_u = Eio.Promise.create () in
  let release_first, release_first_u = Eio.Promise.create () in
  gate_next_write state ~started:first_started_u ~release:release_first;
  let first_done, first_done_u = Eio.Promise.create () in
  let second_done, second_done_u = Eio.Promise.create () in
  let close_done, close_done_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http.Ws.Client.send_text conn "first"
      |> Eta.Runtime.run rt |> Eio.Promise.resolve first_done_u);
  Eio.Promise.await first_started;
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http.Ws.Client.send_text conn "second"
      |> Eta.Runtime.run rt |> Eio.Promise.resolve second_done_u);
  Eio.Fiber.yield ();
  Eio.Fiber.fork ~sw (fun () ->
      Eta_http.Ws.Client.close conn
      |> Eta.Runtime.run rt |> Eio.Promise.resolve close_done_u);
  Eio.Fiber.yield ();
  Eio.Promise.resolve release_first_u ();
  Eta_test.Expect.expect_ok (Eio.Promise.await first_done);
  (match Eio.Promise.await second_done with
  | Eta.Exit.Error (Eta.Cause.Fail (`Closed (1000, "WebSocket is closing"))) -> ()
  | Eta.Exit.Ok () -> Alcotest.fail "queued send wrote after close started"
  | Eta.Exit.Error cause ->
      Alcotest.failf "queued send failed with unexpected cause: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
          | `Connect message -> Format.fprintf fmt "connect %s" message
          | `Protocol message -> Format.fprintf fmt "protocol %s" message
          | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
          | `Timeout -> Format.pp_print_string fmt "timeout"))
        cause);
  Eta_test.Expect.expect_ok (Eio.Promise.await close_done);
  let opcodes =
    client_frames_after_upgrade state
    |> List.map (fun frame -> frame.Eta_http.Ws.Codec.opcode)
  in
  Alcotest.(check (list int))
    "client frames"
    [ Eta_http.Ws.Codec.opcode_to_int Text; Eta_http.Ws.Codec.opcode_to_int Close ]
    (List.map Eta_http.Ws.Codec.opcode_to_int opcodes)

let test_ws_close_sent_uses_atomic_state () =
  let source = read_file (find_ws_client_source ()) in
  Alcotest.(check bool) "atomic close_sent field" true
    (contains source "close_sent : bool Atomic.t;");
  Alcotest.(check bool) "atomic close_sent read" true
    (contains source "Atomic.get t.close_sent");
  Alcotest.(check bool) "atomic close_sent publish" true
    (contains source "Atomic.set t.close_sent true");
  Alcotest.(check bool) "no mutable close_sent assignment" false
    (contains source "t.close_sent <-")

let test_ws_ping_is_internal_and_pong_is_sent () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let ping =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Ping; payload = Bytes.of_string "hi" }
    |> Bytes.to_string
  in
  let text =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Text; payload = Bytes.of_string "after" }
    |> Bytes.to_string
  in
  let state, flow = scripted_flow [ Return (switching_response key ^ ping ^ text) ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let messages =
    Eta_http.Ws.Client.incoming conn
    |> Eta_stream.Stream.take 1
    |> Eta_stream.run_collect
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (list string))
    "ping hidden" [ "after" ]
    (List.map (function `Text text -> text | `Binary _ -> "<binary>") messages);
  expect_client_frame state Pong "hi"

let test_ws_close_1011_fails_inbound_stream () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let close =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Close; payload = close_payload 1011 "upstream" }
    |> Bytes.to_string
  in
  let _state, flow = scripted_flow [ Return (switching_response key ^ close) ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn)) with
  | Eta.Exit.Error (Eta.Cause.Fail (`Closed (1011, "upstream"))) -> ()
  | Eta.Exit.Ok () -> Alcotest.fail "1011 close unexpectedly ended cleanly"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected WebSocket close failure: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
          | `Connect message -> Format.fprintf fmt "connect %s" message
          | `Protocol message -> Format.fprintf fmt "protocol %s" message
          | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
          | `Timeout -> Format.pp_print_string fmt "timeout"))
        cause

let test_ws_invalid_peer_close_code_is_protocol_error () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  (* 999 is below the valid WebSocket close-code range; the peer must not be
     able to surface it as a normal `Closed` — it is a protocol violation.
     Build raw bytes directly: Codec.encode now refuses invalid close codes. *)
  let invalid_close = Bytes.to_string (raw_close_frame 999) in
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ invalid_close) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match
    Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn))
  with
  | Eta.Exit.Error (Eta.Cause.Fail (`Protocol _)) -> ()
  | Eta.Exit.Error (Eta.Cause.Fail (`Closed (999, _))) ->
      Alcotest.fail "invalid close code 999 was accepted as Closed"
  | Eta.Exit.Ok () -> Alcotest.fail "expected protocol error for invalid close code"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cause: %a"
        (Eta.Cause.pp (fun fmt -> function
          | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
          | `Connect message -> Format.fprintf fmt "connect %s" message
          | `Protocol message -> Format.fprintf fmt "protocol %s" message
          | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
          | `Timeout -> Format.pp_print_string fmt "timeout"))
        cause

let pp_ws_error fmt = function
  | `Connect message -> Format.fprintf fmt "connect %s" message
  | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
  | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
  | `Protocol message -> Format.fprintf fmt "protocol %s" message
  | `Timeout -> Format.pp_print_string fmt "timeout"

let expect_ws_protocol_failure label = function
  | Eta.Exit.Error (Eta.Cause.Fail (`Protocol _)) -> ()
  | Eta.Exit.Ok () -> Alcotest.failf "%s: expected protocol failure" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: unexpected failure: %a" label
        (Eta.Cause.pp pp_ws_error) cause

let test_ws_rejects_invalid_utf8_text_frame () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let invalid_text =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Text; payload = Bytes.of_string "\xff" }
    |> Bytes.to_string
  in
  let close =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Close; payload = close_payload 1000 "" }
    |> Bytes.to_string
  in
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ invalid_text ^ close) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn))
  |> expect_ws_protocol_failure "invalid UTF-8 text"

let test_ws_rejects_invalid_utf8_close_reason () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let payload = Bytes.create 3 in
  Bytes.set payload 0 (Char.chr (1000 lsr 8));
  Bytes.set payload 1 (Char.chr (1000 land 0xff));
  Bytes.set payload 2 '\xff';
  let close =
    Eta_http.Ws.Codec.encode { fin = true; opcode = Close; payload }
    |> Bytes.to_string
  in
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ close) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn))
  |> expect_ws_protocol_failure "invalid UTF-8 close reason"

let test_ws_selected_subprotocol () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let _state, flow =
    scripted_flow [ Return (switching_response ~protocol:"realtime" key) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~protocols:[ "realtime"; "json" ]
      ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (option string)) "protocol" (Some "realtime")
    (Eta_http.Ws.Client.selected_protocol conn)

let test_ws_fragmented_text_reassembles () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let first =
    Eta_http.Ws.Codec.encode
      { fin = false; opcode = Text; payload = Bytes.of_string "hel" }
    |> Bytes.to_string
  in
  let second =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Continuation; payload = Bytes.of_string "lo" }
    |> Bytes.to_string
  in
  let _state, flow =
    scripted_flow [ Return (switching_response key ^ first ^ second) ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  let messages =
    Eta_http.Ws.Client.incoming conn
    |> Eta_stream.Stream.take 1
    |> Eta_stream.run_collect
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (list string)) "messages" [ "hello" ]
    (List.map (function `Text text -> text | `Binary _ -> "<binary>") messages)

let test_ws_clean_close_ends_inbound_stream () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let close =
    Eta_http.Ws.Codec.encode
      { fin = true; opcode = Close; payload = close_payload 1000 "" }
    |> Bytes.to_string
  in
  let _state, flow = scripted_flow [ Return (switching_response key ^ close) ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn)) with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error _ -> Alcotest.fail "clean close failed inbound stream"

let test_ws_server_masked_frame_is_protocol_error () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let masked =
    Eta_http.Ws.Codec.encode ~mask:(Bytes.of_string "\001\002\003\004")
      { fin = true; opcode = Text; payload = Bytes.of_string "bad" }
    |> Bytes.to_string
  in
  let _state, flow = scripted_flow [ Return (switching_response key ^ masked) ] in
  let url = Eta_http.Core.Url.of_string "http://example.test/realtime" in
  with_test_clock @@ fun sw _clock rt ->
  let conn =
    Eta_http.Ws.Client.connect_on_flow ~key ~sw ~flow url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  match Eta.Runtime.run rt (Eta_stream.run_drain (Eta_http.Ws.Client.incoming conn)) with
  | Eta.Exit.Error (Eta.Cause.Fail (`Protocol "masked frame forbidden")) -> ()
  | Eta.Exit.Ok () -> Alcotest.fail "masked server frame unexpectedly succeeded"
  | Eta.Exit.Error _ -> Alcotest.fail "unexpected masked server frame failure"

let test_ws_connect_real_tcp_echo () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_done, resolve_server_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> ignore (Eio.Promise.try_resolve resolve_server_done ()))
        (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
          run_echo_ws_server ~expect_target:"/realtime?model=x" ~messages:2 flow));
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let url = Printf.sprintf "ws://127.0.0.1:%d/realtime?model=x" port in
  let conn =
    Eta_http.Ws.Client.connect ~sw ~net url
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Eta_http.Ws.Client.send_text conn "alpha"
  |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok;
  Eta_http.Ws.Client.send_text conn "beta"
  |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok;
  let messages =
    Eta_http.Ws.Client.incoming conn
    |> Eta_stream.Stream.take 2
    |> Eta_stream.run_collect
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (list string)) "echo" [ "alpha"; "beta" ]
    (List.map (function `Text text -> text | `Binary _ -> "<binary>") messages);
  Eio.Promise.await server_done
