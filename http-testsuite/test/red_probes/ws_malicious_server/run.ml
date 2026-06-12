(* Red probe: WebSocket adversarial server against eta_http_eio Ws.Client.
   These probes start a malicious in-process WebSocket server, connect the Eta
   client, and observe whether it handles pathological frames / handshake
   behavior within a deadline. Exit code is always 0: this is a bug finder,
   not a green gate. *)

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected TCP listener"

let pp_ws_error fmt = function
  | `Connect msg -> Format.fprintf fmt "connect %s" msg
  | `Upgrade_failed status -> Format.fprintf fmt "upgrade %d" status
  | `Closed (code, reason) -> Format.fprintf fmt "closed %d %s" code reason
  | `Protocol msg -> Format.fprintf fmt "protocol %s" msg
  | `Timeout -> Format.fprintf fmt "timeout"

type raw_result =
  | Hang
  | Crash of string
  | Error of Eta_http_eio.Ws.Client.ws_error
  | Ok_close

let string_of_raw = function
  | Hang -> "deadline exceeded"
  | Crash msg -> Printf.sprintf "crash %s" msg
  | Error err -> Format.asprintf "%a" pp_ws_error err
  | Ok_close -> "clean close"

type outcome =
  | Pass of string
  | Fail of string
  | Hang_out
  | Crash_out of string
  | Policy_gap of string

let string_of_outcome = function
  | Pass d -> "PASS", d
  | Fail d -> "FAIL", d
  | Hang_out -> "HANG", ""
  | Crash_out d -> "CRASH", d
  | Policy_gap d -> "POLICY_GAP", d

type expectation =
  | Expect_protocol_error
  | Expect_typed_error
  | Expect_clean_close

let raw_of_exit : type a. (a, Eta_http_eio.Ws.Client.ws_error) Eta.Exit.t -> raw_result =
  function
  | Eta.Exit.Ok _ -> Ok_close
  | Eta.Exit.Error (Eta.Cause.Fail `Timeout) -> Hang
  | Eta.Exit.Error (Eta.Cause.Fail error) -> Error error
  | Eta.Exit.Error (Eta.Cause.Die d) ->
      Crash (Printexc.to_string d.Eta.Cause.exn)
  | Eta.Exit.Error
      (Eta.Cause.Interrupt _ | Eta.Cause.Sequential _ | Eta.Cause.Concurrent _
      | Eta.Cause.Finalizer _ | Eta.Cause.Suppressed _) ->
      Crash "unexpected cause shape"

let classify ~expected raw =
  match raw, expected with
  | Hang, _ -> Hang_out
  | Crash msg, _ -> Crash_out msg
  | Error (`Protocol _), Expect_protocol_error -> Pass (string_of_raw raw)
  | Error (`Protocol _ | `Connect _ | `Upgrade_failed _ | `Closed _ | `Timeout),
    (Expect_protocol_error | Expect_typed_error) ->
      Pass (string_of_raw raw)
  | Ok_close, Expect_clean_close -> Pass (string_of_raw raw)
  | Ok_close, (Expect_protocol_error | Expect_typed_error) ->
      Fail (string_of_raw raw)
  | Error _, Expect_clean_close -> Fail (string_of_raw raw)

(* ---------------------------------------------------------------------------
   Low-level helpers: read HTTP upgrade request, build handshake response,
   construct raw (possibly invalid) WebSocket frames.
   --------------------------------------------------------------------------- *)

let read_http_request flow =
  let scratch = Cstruct.create 1 in
  let buffer = Buffer.create 512 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> raise End_of_file
    | _ ->
        Buffer.add_char buffer (Cstruct.get_char scratch 0);
        let s = Buffer.contents buffer in
        if String.ends_with ~suffix:"\r\n\r\n" s then s else loop ()
  in
  loop ()

let extract_key request =
  let lines = String.split_on_char '\n' request in
  List.find_map
    (fun line ->
      let trimmed = String.trim line in
      match String.index_opt trimmed ':' with
      | None -> None
      | Some idx ->
          let name =
            String.lowercase_ascii (String.trim (String.sub trimmed 0 idx))
          in
          if String.equal name "sec-websocket-key" then
            Some
              (String.trim
                 (String.sub trimmed (idx + 1)
                    (String.length trimmed - idx - 1)))
          else None)
    lines

let accept_key key = Eta_http.Ws.Codec.accept_key key

let send_response ?(status = "101 Switching Protocols") ?(upgrade = "websocket")
    ?(connection = "Upgrade") ?accept ?protocol flow =
  let buf = Buffer.create 256 in
  Buffer.add_string buf ("HTTP/1.1 " ^ status ^ "\r\n");
  Buffer.add_string buf ("Upgrade: " ^ upgrade ^ "\r\n");
  Buffer.add_string buf ("Connection: " ^ connection ^ "\r\n");
  (match accept with
  | Some k -> Buffer.add_string buf ("Sec-WebSocket-Accept: " ^ k ^ "\r\n")
  | None -> ());
  (match protocol with
  | Some p ->
      Buffer.add_string buf ("Sec-WebSocket-Protocol: " ^ p ^ "\r\n")
  | None -> ());
  Buffer.add_string buf "\r\n";
  Eio.Flow.copy_string (Buffer.contents buf) flow

let close_payload code reason =
  let payload = Bytes.create (2 + String.length reason) in
  Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
  Bytes.set payload 1 (Char.chr (code land 0xff));
  Bytes.blit_string reason 0 payload 2 (String.length reason);
  Bytes.to_string payload

let valid_text_frame payload =
  Eta_http.Ws.Codec.encode
    {
      Eta_http.Ws.Codec.fin = true;
      opcode = Eta_http.Ws.Codec.Text;
      payload = Bytes.of_string payload;
    }
  |> Bytes.to_string

let valid_close_frame ?(code = 1000) ?(reason = "") () =
  Eta_http.Ws.Codec.encode
    {
      Eta_http.Ws.Codec.fin = true;
      opcode = Eta_http.Ws.Codec.Close;
      payload = Bytes.of_string (close_payload code reason);
    }
  |> Bytes.to_string

let valid_ping_frame payload =
  Eta_http.Ws.Codec.encode
    {
      Eta_http.Ws.Codec.fin = true;
      opcode = Eta_http.Ws.Codec.Ping;
      payload = Bytes.of_string payload;
    }
  |> Bytes.to_string

(* Raw frame constructor bypasses Codec.validate_frame so we can build
   intentionally malformed frames (masked server frames, reserved opcodes,
   fragmented control frames, non-minimal lengths, reserved bits, etc.). *)
let raw_frame ?(fin = true) ?(rsv = 0) opcode payload =
  let payload_len = String.length payload in
  let b0 =
    (if fin then 0x80 else 0x00) lor (rsv land 0x70) lor (opcode land 0x0f)
  in
  if payload_len <= 125 then
    let bytes = Bytes.create (2 + payload_len) in
    Bytes.set bytes 0 (Char.chr b0);
    Bytes.set bytes 1 (Char.chr payload_len);
    Bytes.blit_string payload 0 bytes 2 payload_len;
    Bytes.to_string bytes
  else if payload_len <= 0xffff then
    let bytes = Bytes.create (4 + payload_len) in
    Bytes.set bytes 0 (Char.chr b0);
    Bytes.set bytes 1 (Char.chr 126);
    Bytes.set_int16_be bytes 2 payload_len;
    Bytes.blit_string payload 0 bytes 4 payload_len;
    Bytes.to_string bytes
  else
    let bytes = Bytes.create (10 + payload_len) in
    Bytes.set bytes 0 (Char.chr b0);
    Bytes.set bytes 1 (Char.chr 127);
    Bytes.set_int64_be bytes 2 (Int64.of_int payload_len);
    Bytes.blit_string payload 0 bytes 10 payload_len;
    Bytes.to_string bytes

let masked_server_frame opcode payload =
  let mask = Bytes.of_string "\x01\x02\x03\x04" in
  Eta_http.Ws.Codec.encode ~mask
    { Eta_http.Ws.Codec.fin = true; opcode; payload = Bytes.of_string payload }
  |> Bytes.to_string

(* ---------------------------------------------------------------------------
   Probe harness: start a TCP server, run the malicious server_fn, connect an
   Eta Ws.Client, and drain the inbound stream under a deadline.
   --------------------------------------------------------------------------- *)

let run_ws_probe ~env ~name:_ ~deadline_sec ~server_fn =
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Time.with_timeout_exn clock (deadline_sec +. 1.0) (fun () ->
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
              ~finally:(fun () ->
                ignore (Eio.Promise.try_resolve resolve_server_done ()))
              (fun () ->
                Eio.Switch.run @@ fun conn_sw ->
                let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
                Fun.protect
                  ~finally:(fun () ->
                    try Eio.Flow.shutdown flow `All with _ -> ())
                  (fun () -> server_fn ~env flow)));
        let rt = Eta_eio.Runtime.create ~sw ~clock () in
        let url = Printf.sprintf "ws://127.0.0.1:%d/ws" port in
        let timeout_ms = max 1 (int_of_float (deadline_sec *. 1000.0)) in
        let connect_result =
          Eta_http_eio.Ws.Client.connect ~sw ~net url
          |> Eta.Effect.timeout_as (Eta.Duration.ms timeout_ms)
               ~on_timeout:`Timeout
          |> Eta.Runtime.run rt
        in
        let raw_result =
          match connect_result with
          | Eta.Exit.Ok conn ->
              let stream_result =
                Eta_http_eio.Ws.Client.incoming conn
                |> Eta_stream.run_drain
                |> Eta.Effect.timeout_as (Eta.Duration.ms timeout_ms)
                     ~on_timeout:`Timeout
                |> Eta.Runtime.run rt
              in
              (match stream_result with
              | Eta.Exit.Error (Eta.Cause.Fail `Timeout) ->
                  ignore
                    (Eta.Runtime.run rt (Eta_http_eio.Ws.Client.close conn))
              | Eta.Exit.Ok ()
              | Eta.Exit.Error
                  (Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _
                  | Eta.Cause.Sequential _ | Eta.Cause.Concurrent _
                  | Eta.Cause.Finalizer _ | Eta.Cause.Suppressed _) ->
                  ());
              raw_of_exit stream_result
          | Eta.Exit.Error _ -> raw_of_exit connect_result
        in
        ignore (Eio.Promise.try_resolve resolve_server_done ());
        (try Eio.Promise.await server_done with _ -> ());
        raw_result)
  with
  | Eio.Time.Timeout -> Hang
  | Eio.Cancel.Cancelled _ -> Hang
  | exn -> Crash (Printexc.to_string exn)

let probe ~env ~name ~deadline_sec ~expected ~server_fn () =
  let raw = run_ws_probe ~env ~name ~deadline_sec ~server_fn in
  (name, classify ~expected raw)

(* ---------------------------------------------------------------------------
   Server builders
   --------------------------------------------------------------------------- *)

let drain_flow flow =
  let buf = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read flow buf with
    | 0 -> ()
    | _ -> loop ()
    | exception End_of_file -> ()
    | exception Eio.Io _ -> ()
  in
  loop ()

let handshake_then_frames frames ~env:_ flow =
  let request = read_http_request flow in
  let accept = Option.map accept_key (extract_key request) in
  send_response ?accept flow;
  List.iter (fun frame -> Eio.Flow.copy_string frame flow) frames;
  drain_flow flow

let handshake_then_one_frame frame ~env:_ flow =
  let request = read_http_request flow in
  let accept = Option.map accept_key (extract_key request) in
  send_response ?accept flow;
  Eio.Flow.copy_string frame flow;
  drain_flow flow

let handshake_then_close ~env:_ flow =
  ignore (read_http_request flow);
  try Eio.Flow.shutdown flow `All with _ -> ()

let garbage_response ~env:_ flow =
  ignore (read_http_request flow);
  Eio.Flow.copy_string "this is not an HTTP response\r\n\r\n" flow;
  drain_flow flow

let invalid_upgrade_response ?status ?upgrade ?connection ?accept () ~env:_ flow =
  let request = read_http_request flow in
  let accept =
    match accept with
    | Some k -> Some k
    | None -> Option.map accept_key (extract_key request)
  in
  send_response ?status ?upgrade ?connection ?accept flow;
  drain_flow flow

(* ---------------------------------------------------------------------------
   Individual probes
   --------------------------------------------------------------------------- *)

(* 1. Fragmented control frames must be rejected. *)
let probe_fragmented_control_ping ~env =
  probe ~env ~name:"fragmented_control_ping" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame ~fin:false 0x9 "ping"))
    ()

let probe_fragmented_control_close ~env =
  probe ~env ~name:"fragmented_control_close" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (handshake_then_one_frame
         (raw_frame ~fin:false 0x8 (close_payload 1000 "")))
    ()

(* 2. Ping flood: server sends many pings. The client must not crash, but
      because there is no rate limit and pongs are sent synchronously the
      inbound stream does not make progress within the deadline. Treating the
      resulting hang as a policy gap documents the absence of ping throttling
      and the synchronous pong path that prevents Eta's own timeout from
      firing promptly. *)
let probe_ping_flood ~env =
  let pings = List.init 10000 (fun _ -> valid_ping_frame "x") in
  let raw =
    run_ws_probe ~env ~name:"ping_flood" ~deadline_sec:3.0
      ~server_fn:(handshake_then_frames pings)
  in
  let outcome =
    match raw with
    | Hang ->
        Policy_gap
          "no ping rate limit; synchronous pong loop blocks timeout/cancellation"
    | Crash msg -> Crash_out msg
    | (Ok_close | Error _) -> Pass (string_of_raw raw)
  in
  ("ping_flood", outcome)

(* 3. Close frame malformations. *)
let probe_close_oversized_payload ~env =
  probe ~env ~name:"close_oversized_payload" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 (String.make 126 'x')))
    ()

let probe_close_one_byte_payload ~env =
  probe ~env ~name:"close_one_byte_payload" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 "\x00"))
    ()

let probe_close_invalid_code_999 ~env =
  probe ~env ~name:"close_invalid_code_999" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 (close_payload 999 "")))
    ()

let probe_close_reserved_code_1004 ~env =
  probe ~env ~name:"close_reserved_code_1004" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 (close_payload 1004 "")))
    ()

let probe_close_reserved_code_1005 ~env =
  probe ~env ~name:"close_reserved_code_1005" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 (close_payload 1005 "")))
    ()

let probe_close_reserved_code_1015 ~env =
  probe ~env ~name:"close_reserved_code_1015" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 (close_payload 1015 "")))
    ()

let probe_close_invalid_utf8_reason ~env =
  probe ~env ~name:"close_invalid_utf8_reason" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (handshake_then_one_frame
         (raw_frame 0x8 (close_payload 1000 "\xff\xfe")))
    ()

(* 4. Invalid opcodes. *)
let probe_invalid_opcode_3 ~env =
  probe ~env ~name:"invalid_opcode_3" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x3 "x"))
    ()

let probe_invalid_opcode_7 ~env =
  probe ~env ~name:"invalid_opcode_7" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x7 "x"))
    ()

let probe_invalid_opcode_15 ~env =
  probe ~env ~name:"invalid_opcode_15" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0xf "x"))
    ()

(* 5. Unmasked vs masked server frames. Server-to-client frames must be
      unmasked; a masked server frame is a protocol violation. *)
let probe_unmasked_server_text ~env =
  probe ~env ~name:"unmasked_server_text" ~deadline_sec:2.0
    ~expected:Expect_clean_close
    ~server_fn:
      (handshake_then_frames
         [ valid_text_frame "hello"; valid_close_frame () ])
    ()

let probe_masked_server_text ~env =
  probe ~env ~name:"masked_server_text" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (handshake_then_one_frame
         (masked_server_frame Eta_http.Ws.Codec.Text "hello"))
    ()

(* 6. Interleaved data/control frames. Control frames may be interleaved
      between fragments of a data message. *)
let probe_interleaved_ping_during_fragment ~env =
  probe ~env ~name:"interleaved_ping_during_fragment" ~deadline_sec:2.0
    ~expected:Expect_clean_close
    ~server_fn:
      (handshake_then_frames
         [
           raw_frame ~fin:false 0x1 "hel";
           valid_ping_frame "x";
           raw_frame ~fin:true 0x0 "lo";
           valid_close_frame ();
         ])
    ()

let probe_interleaved_close_during_fragment ~env =
  probe ~env ~name:"interleaved_close_during_fragment" ~deadline_sec:2.0
    ~expected:Expect_clean_close
    ~server_fn:
      (handshake_then_frames
         [ raw_frame ~fin:false 0x1 "hel"; valid_close_frame () ])
    ()

(* 7. Reserved bits and non-minimal length encoding. *)
let probe_reserved_bits_rsv1 ~env =
  probe ~env ~name:"reserved_bits_rsv1" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame ~rsv:0x40 0x1 "x"))
    ()

let probe_non_minimal_length ~env =
  probe ~env ~name:"non_minimal_length" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (handshake_then_one_frame
         (* Text frame, length code 126, but payload length 5 (<126). *)
         "\x81\x7e\x00\x05hello")
    ()

(* 8. Invalid upgrade responses. *)
let probe_invalid_upgrade_missing_upgrade ~env =
  probe ~env ~name:"invalid_upgrade_missing_upgrade" ~deadline_sec:2.0
    ~expected:Expect_typed_error
    ~server_fn:(invalid_upgrade_response ~upgrade:"" ())
    ()

let probe_invalid_upgrade_wrong_accept ~env =
  probe ~env ~name:"invalid_upgrade_wrong_accept" ~deadline_sec:2.0
    ~expected:Expect_typed_error
    ~server_fn:(invalid_upgrade_response ~accept:"d2lsbC1mYWls" ())
    ()

let probe_invalid_upgrade_200_ok ~env =
  probe ~env ~name:"invalid_upgrade_200_ok" ~deadline_sec:2.0
    ~expected:Expect_typed_error
    ~server_fn:(invalid_upgrade_response ~status:"200 OK" ())
    ()

let probe_invalid_upgrade_http10 ~env =
  let raw =
    run_ws_probe ~env ~name:"invalid_upgrade_http10" ~deadline_sec:2.0
      ~server_fn:(fun ~env:_ flow ->
        let request = read_http_request flow in
        let accept = Option.map accept_key (extract_key request) in
        (* RFC 6455 requires an HTTP/1.1 Upgrade request/response. *)
        let buf = Buffer.create 256 in
        Buffer.add_string buf "HTTP/1.0 101 Switching Protocols\r\n";
        Buffer.add_string buf "Upgrade: websocket\r\n";
        Buffer.add_string buf "Connection: Upgrade\r\n";
        (match accept with
        | Some k ->
            Buffer.add_string buf ("Sec-WebSocket-Accept: " ^ k ^ "\r\n")
        | None -> ());
        Buffer.add_string buf "\r\n";
        Eio.Flow.copy_string (Buffer.contents buf) flow;
        drain_flow flow)
  in
  let outcome =
    match raw with
    | Hang ->
        Policy_gap "accepted HTTP/1.0 101 response (RFC 6455 requires HTTP/1.1)"
    | Crash msg -> Crash_out msg
    | Ok_close ->
        Policy_gap "accepted HTTP/1.0 101 response (RFC 6455 requires HTTP/1.1)"
    | Error _ -> Pass (string_of_raw raw)
  in
  ("invalid_upgrade_http10", outcome)

(* 9. Server closes during handshake. *)
let probe_handshake_close_immediately ~env =
  probe ~env ~name:"handshake_close_immediately" ~deadline_sec:2.0
    ~expected:Expect_typed_error ~server_fn:handshake_then_close ()

let probe_handshake_garbage_response ~env =
  probe ~env ~name:"handshake_garbage_response" ~deadline_sec:2.0
    ~expected:Expect_typed_error ~server_fn:garbage_response ()

(* 10. Huge frames. Use an explicit small max_frame_size and declare one more
       byte. *)
let probe_huge_frame_declared_length ~env =
  probe ~env ~name:"huge_frame_declared_length" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (fun ~env:_ flow ->
        let request = read_http_request flow in
        let accept = Option.map accept_key (extract_key request) in
        send_response ?accept flow;
        (* Binary frame declaring 2 MiB + 1 bytes; default max_frame_size is 1 MiB. *)
        Eio.Flow.copy_string "\x82\x7f\x00\x00\x00\x00\x00\x20\x00\x01" flow;
        drain_flow flow)
    ()

(* 11. Additional useful edge cases. *)
let probe_text_invalid_utf8 ~env =
  probe ~env ~name:"text_invalid_utf8" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:
      (handshake_then_frames
         [
           raw_frame 0x1 "\xff\xfe";
           valid_close_frame ();
         ])
    ()

let probe_empty_close_frame ~env =
  probe ~env ~name:"empty_close_frame" ~deadline_sec:2.0
    ~expected:Expect_clean_close
    ~server_fn:(handshake_then_one_frame (raw_frame 0x8 ""))
    ()

let probe_ping_oversized_payload ~env =
  probe ~env ~name:"ping_oversized_payload" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x9 (String.make 126 'x')))
    ()

let probe_unsolicited_pong ~env =
  probe ~env ~name:"unsolicited_pong" ~deadline_sec:2.0
    ~expected:Expect_clean_close
    ~server_fn:
      (handshake_then_frames
         [
           Eta_http.Ws.Codec.encode
             {
               Eta_http.Ws.Codec.fin = true;
               opcode = Eta_http.Ws.Codec.Pong;
               payload = Bytes.of_string "ignored";
             }
           |> Bytes.to_string;
           valid_close_frame ();
         ])
    ()

let probe_continuation_without_start ~env =
  probe ~env ~name:"continuation_without_start" ~deadline_sec:2.0
    ~expected:Expect_protocol_error
    ~server_fn:(handshake_then_one_frame (raw_frame 0x0 "orphan"))
    ()

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let probes ~env =
  [
    probe_fragmented_control_ping ~env;
    probe_fragmented_control_close ~env;
    probe_ping_flood ~env;
    probe_close_oversized_payload ~env;
    probe_close_one_byte_payload ~env;
    probe_close_invalid_code_999 ~env;
    probe_close_reserved_code_1004 ~env;
    probe_close_reserved_code_1005 ~env;
    probe_close_reserved_code_1015 ~env;
    probe_close_invalid_utf8_reason ~env;
    probe_invalid_opcode_3 ~env;
    probe_invalid_opcode_7 ~env;
    probe_invalid_opcode_15 ~env;
    probe_unmasked_server_text ~env;
    probe_masked_server_text ~env;
    probe_interleaved_ping_during_fragment ~env;
    probe_interleaved_close_during_fragment ~env;
    probe_reserved_bits_rsv1 ~env;
    probe_non_minimal_length ~env;
    probe_invalid_upgrade_missing_upgrade ~env;
    probe_invalid_upgrade_wrong_accept ~env;
    probe_invalid_upgrade_200_ok ~env;
    probe_invalid_upgrade_http10 ~env;
    probe_handshake_close_immediately ~env;
    probe_handshake_garbage_response ~env;
    probe_huge_frame_declared_length ~env;
    probe_text_invalid_utf8 ~env;
    probe_empty_close_frame ~env;
    probe_ping_oversized_payload ~env;
    probe_unsolicited_pong ~env;
    probe_continuation_without_start ~env;
  ]

let () =
  let results = Eio_main.run (fun env -> probes ~env) in
  List.iter
    (fun (name, outcome) ->
      let status, detail = string_of_outcome outcome in
      if String.equal detail "" then Printf.printf "probe %s %s\n%!" name status
      else Printf.printf "probe %s %s %s\n%!" name status detail)
    results;
  Printf.printf "ws_malicious_server done probes=%d\n%!" (List.length results)
