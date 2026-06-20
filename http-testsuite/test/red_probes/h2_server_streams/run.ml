(** h2_server_streams: HTTP/2 server-side stream scheduling and request-body
    interleaving red probes.

    These probes start an Eta H2C server and then drive it with pathological
    client behaviour across many concurrent streams: interleaved DATA frames,
    RST_STREAM after partial bodies, peer SETTINGS lowering max concurrent
    streams, PRIORITY manipulation, tiny DATA chunks, and HEADERS floods. A hang
    past the deadline is recorded as a finding, not a test failure. *)

open Eta_http_testsuite

(* ---------------------------------------------------------------------------
   Raw HTTP/2 helpers
   --------------------------------------------------------------------------- *)

let h2_preface = Adversarial.h2_client_preface
let write_string flow s = Eio.Flow.write flow [ Cstruct.of_string s ]

let read_exact flow buf len =
  let rec loop off =
    if off >= len then ()
    else
      let n = Eio.Flow.single_read flow (Cstruct.sub buf off (len - off)) in
      if n = 0 then raise End_of_file else loop (off + n)
  in
  loop 0

let read_frame_header flow =
  let buf = Cstruct.create 9 in
  read_exact flow buf 9;
  let len =
    (Cstruct.get_uint8 buf 0 lsl 16)
    lor (Cstruct.get_uint8 buf 1 lsl 8)
    lor Cstruct.get_uint8 buf 2
  in
  let ty = Cstruct.get_uint8 buf 3 in
  let flags = Cstruct.get_uint8 buf 4 in
  let stream_id =
    ((Cstruct.get_uint8 buf 5 land 0x7F) lsl 24)
    lor (Cstruct.get_uint8 buf 6 lsl 16)
    lor (Cstruct.get_uint8 buf 7 lsl 8)
    lor Cstruct.get_uint8 buf 8
  in
  (len, ty, flags, stream_id)

let read_payload flow len =
  if len = 0 then ""
  else
    let buf = Cstruct.create len in
    read_exact flow buf len;
    Cstruct.to_string buf

let settings_ack = Malicious_h2.settings_frame ~ack:true []

let h2_handshake ?(settings = []) flow =
  write_string flow h2_preface;
  write_string flow (Malicious_h2.settings_frame settings);
  let rec loop () =
    let len, ty, _flags, _sid = read_frame_header flow in
    let payload = read_payload flow len in
    if ty = 0x04 then (
      write_string flow settings_ack;
      payload)
    else loop ()
  in
  loop ()

let parse_frames s =
  let rec loop off acc =
    if off + 9 > String.length s then List.rev acc
    else
      let len =
        (Char.code s.[off] lsl 16)
        lor (Char.code s.[off + 1] lsl 8)
        lor Char.code s.[off + 2]
      in
      let ty = Char.code s.[off + 3] in
      let flags = Char.code s.[off + 4] in
      let stream_id =
        ((Char.code s.[off + 5] land 0x7F) lsl 24)
        lor (Char.code s.[off + 6] lsl 16)
        lor (Char.code s.[off + 7] lsl 8)
        lor Char.code s.[off + 8]
      in
      if off + 9 + len > String.length s then List.rev acc
      else loop (off + 9 + len) ((ty, flags, stream_id) :: acc)
  in
  loop 0 []

let count_response_headers frames =
  List.fold_left
    (fun acc (ty, flags, sid) ->
      if ty = 0x01 && flags land 0x04 <> 0 && sid land 1 = 1 then acc + 1
      else acc)
    0 frames

let has_goaway frames = List.exists (fun (ty, _, _) -> ty = 0x07) frames
let has_rst_stream frames = List.exists (fun (ty, _, _) -> ty = 0x03) frames

(** Read until the server stops sending data for [seconds]. *)
let drain_available ~clock ~seconds flow =
  let buffer = Buffer.create 256 in
  let scratch = Cstruct.create 1024 in
  try
    Eio.Time.with_timeout_exn clock seconds (fun () ->
        let rec loop () =
          match Eio.Flow.single_read flow scratch with
          | 0 -> ()
          | n ->
              Buffer.add_string buffer
                (Cstruct.to_string (Cstruct.sub scratch 0 n));
              loop ()
          | exception End_of_file -> ()
        in
        loop ();
        `Drained (Buffer.contents buffer))
  with
  | Eio.Time.Timeout -> `Timeout (Buffer.contents buffer)
  | exn -> `Error (Printexc.to_string exn, Buffer.contents buffer)

(* ---------------------------------------------------------------------------
   Server handlers
   --------------------------------------------------------------------------- *)

let immediate_handler _request = Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

let echo_handler request =
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun body ->
         Eta_http.Server.Response.make ~status:200
           ~body:(Eta_http.Server.Response.Body.fixed [ body ])
           ())

(* ---------------------------------------------------------------------------
   Probe harness
   --------------------------------------------------------------------------- *)

type status = PASS | FAIL | HANG | CRASH | POLICY_GAP

let string_of_status = function
  | PASS -> "PASS"
  | FAIL -> "FAIL"
  | HANG -> "HANG"
  | CRASH -> "CRASH"
  | POLICY_GAP -> "POLICY_GAP"

let print_probe name status detail =
  Printf.printf "probe %s %s%s\n%!" name (string_of_status status)
    (match detail with None -> "" | Some d -> " [" ^ d ^ "]")

type outcome =
  | Closed of string
  | Read_timeout of string
  | Probe_timeout
  | Errored of string

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listener"

let h2_config_with_max_streams n =
  let base = Adversarial.h2_adversarial_config () in
  {
    base with
    Eta_http_eio.Server.Config.h2_config =
      { base.Eta_http_eio.Server.Config.h2_config with
        Eta_http_h2.Config.max_concurrent_streams = n
      };
  }

let run_h2c_probe ~env ~name ~deadline_sec ~read_deadline_sec ?config ~handler
    client_fn =
  let outcome =
    try
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port = tcp_port (Eio.Net.listening_addr socket) in
      let config = Option.value config ~default:(Adversarial.h2_adversarial_config ()) in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          let flow, peer = Eio.Net.accept ~sw:conn_sw socket in
          let runtime_factory ~sw ~connection:_ () = Eta_eio.Runtime.create ~sw ~clock () in
          Eta_http_eio.H2.Server_connection.run_h2c ~sw:conn_sw ~clock
            ~flow:(flow :> Eta_http_eio.H2.Server_connection.flow)
            ~peer ~config ~runtime_factory handler;
          `Stop_daemon);
      let flow =
        Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Fun.protect
        ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          try
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                client_fn ~clock flow;
                match drain_available ~clock ~seconds:read_deadline_sec flow with
                | `Drained bytes -> Closed bytes
                | `Timeout bytes -> Read_timeout bytes
                | `Error (msg, bytes) ->
                    Errored (msg ^ "; drained=" ^ string_of_int (String.length bytes)))
          with
          | Eio.Time.Timeout -> Probe_timeout
          | exn -> Errored (Printexc.to_string exn))
    with exn -> Errored (Printexc.to_string exn)
  in
  (name, outcome)

let assess_responses name ~expected outcome =
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      let responses = count_response_headers frames in
      if responses >= expected then
        print_probe name PASS
          (Some
             (Printf.sprintf "%d/%d responses (bytes=%d)" responses expected
                (String.length bytes)))
      else if has_goaway frames || has_rst_stream frames then
        print_probe name FAIL
          (Some
             (Printf.sprintf "only %d/%d responses, error frame seen (bytes=%d)"
                responses expected (String.length bytes)))
      else
        print_probe name HANG
          (Some
             (Printf.sprintf "only %d/%d responses, connection still open"
                responses expected))

(* ---------------------------------------------------------------------------
   Probe implementations
   --------------------------------------------------------------------------- *)

let probe_data_interleaved ~env () =
  let streams = 20 in
  let rounds = 4 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ())
    done;
    for round = 1 to rounds do
      for i = 1 to streams do
        let stream_id = (i * 2) - 1 in
        let chunk = Printf.sprintf "r%02d" round in
        write_string flow
          (Malicious_h2.data_frame ~end_stream:false ~stream_id chunk)
      done
    done;
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow (Malicious_h2.data_frame ~end_stream:true ~stream_id "")
    done;
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_data_interleaved"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0 ~handler:echo_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:streams outcome

let probe_rst_stream_during_bodies ~env () =
  let streams = 10 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ())
    done;
    (* First round of DATA on every stream. *)
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Malicious_h2.data_frame ~end_stream:false ~stream_id "first")
    done;
    (* Reset stream 1 while its body is still incomplete and other streams are
       active. *)
    write_string flow (Malicious_h2.rst_stream_frame ~stream_id:1 8);
    (* Continue completing the remaining streams. *)
    for i = 2 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Malicious_h2.data_frame ~end_stream:true ~stream_id "last")
    done;
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_rst_during_bodies"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0 ~handler:echo_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:(streams - 1) outcome

let probe_settings_lower_max_concurrent_streams ~env () =
  let streams = 10 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ())
    done;
    (* Peer tells the server it may not open more than one concurrent
       server-initiated stream. This must not affect the already-open client
       streams. *)
    write_string flow (Malicious_h2.settings_frame [ (0x3, 1) ]);
    let rec wait_ack () =
      let len, ty, flags, _sid = read_frame_header flow in
      if ty = 0x04 && flags land 0x01 <> 0 then ()
      else (
        ignore (read_payload flow len : string);
        wait_ack ())
    in
    wait_ack ();
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Malicious_h2.data_frame ~end_stream:true ~stream_id "done")
    done;
    (* Open one more stream after the peer setting took effect. *)
    let stream_id = (streams * 2) + 1 in
    write_string flow
      (Adversarial.h2_request_headers ~method_:"GET" ~stream_id
         ~end_stream:true ~end_headers:true ());
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_settings_lower_max_concurrent"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0
    ~config:(h2_config_with_max_streams 100)
    ~handler:echo_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:(streams + 1) outcome

let probe_priority_self_dependency ~env () =
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow
      (Adversarial.h2_request_headers ~stream_id:1 ~end_stream:true
         ~end_headers:true ());
    (* PRIORITY frame making stream 3 depend exclusively on itself. This is a
       protocol violation and should be rejected on stream 3. *)
    let priority_payload = "\x80\x00\x00\x03\x10" in
    write_string flow
      (Malicious_h2.frame ~ty:0x02 ~flags:0x00 ~stream_id:3 priority_payload);
    write_string flow
      (Adversarial.h2_request_headers ~stream_id:3 ~end_stream:true
         ~end_headers:true ());
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_priority_self_dependency"
    ~deadline_sec:3.0 ~read_deadline_sec:1.0 ~handler:immediate_handler
    client_logic
  |> fun (name, outcome) ->
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      let stream1_ok = List.exists (fun (ty, f, sid) -> ty = 0x01 && f land 0x04 <> 0 && sid = 1) frames in
      let stream3_error =
        List.exists
          (fun (ty, _, sid) -> (ty = 0x03 || ty = 0x07) && sid = 3)
          frames
      in
      if stream1_ok && stream3_error then
        print_probe name PASS (Some "stream 1 responded, stream 3 rejected")
      else if stream1_ok then
        print_probe name POLICY_GAP
          (Some "stream 1 responded but self-dependency was ignored")
      else
        print_probe name FAIL
          (Some
             (Printf.sprintf "stream 1 did not respond (bytes=%d)"
                (String.length bytes)))

let probe_tiny_data_chunks ~env () =
  let streams = 40 in
  let chunks_per_stream = 4 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ())
    done;
    for chunk = 1 to chunks_per_stream do
      for i = 1 to streams do
        let stream_id = (i * 2) - 1 in
        let end_stream = chunk = chunks_per_stream in
        write_string flow
          (Malicious_h2.data_frame ~end_stream ~stream_id
             (String.make 1 (Char.chr (0x60 + chunk))))
      done
    done;
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_tiny_data_chunks"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0 ~handler:echo_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:streams outcome

let probe_headers_flood_no_data ~env () =
  let streams = 80 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"GET" ~stream_id
           ~end_stream:true ~end_headers:true ())
    done;
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_headers_flood_no_data"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0
    ~config:(h2_config_with_max_streams 128)
    ~handler:immediate_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:streams outcome

let probe_unread_bodies_interleaved ~env () =
  let streams = 30 in
  let rounds = 3 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ())
    done;
    for round = 1 to rounds do
      for i = 1 to streams do
        let stream_id = (i * 2) - 1 in
        let end_stream = round = rounds in
        write_string flow
          (Malicious_h2.data_frame ~end_stream ~stream_id
             (Printf.sprintf "round%d" round))
      done
    done;
    Eio.Flow.shutdown flow `Send
  in
  (* Handler returns a response without reading the request bodies, so the
     server must reset/discard each stream without stalling. *)
  run_h2c_probe ~env ~name:"h2_streams_unread_bodies_interleaved"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0 ~handler:immediate_handler
    client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:streams outcome

let probe_stalled_body_not_blocking ~env () =
  let streams = 10 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    (* Stream 1 starts a POST body but never sends DATA. *)
    write_string flow
      (Adversarial.h2_request_headers ~method_:"POST" ~stream_id:1
         ~end_stream:false ~end_headers:true ());
    (* Other streams complete fully. *)
    for i = 2 to streams do
      let stream_id = (i * 2) - 1 in
      write_string flow
        (Adversarial.h2_request_headers ~method_:"POST" ~stream_id
           ~end_stream:false ~end_headers:true ());
      write_string flow
        (Malicious_h2.data_frame ~end_stream:true ~stream_id "done")
    done;
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_stalled_body_not_blocking"
    ~deadline_sec:5.0 ~read_deadline_sec:2.0 ~handler:echo_handler client_logic
  |> fun (name, outcome) -> assess_responses name ~expected:(streams - 1) outcome

let probe_empty_data_flood_many_streams ~env () =
  let flood_count = 101 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow
      (Adversarial.h2_request_headers ~method_:"POST" ~stream_id:1
         ~end_stream:false ~end_headers:true ());
    (* Spread empty DATA frames across several open/idle streams. The per-
       connection empty-data limit should fire after the 100th frame. *)
    for i = 1 to flood_count do
      let stream_id = 1 + ((i mod 5) * 2) in
      write_string flow (Malicious_h2.data_frame ~end_stream:false ~stream_id "")
    done;
    (* A later valid request should not be processed after the flood. *)
    write_string flow
      (Adversarial.h2_request_headers ~method_:"GET" ~stream_id:11
         ~end_stream:true ~end_headers:true ());
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_empty_data_flood"
    ~deadline_sec:3.0 ~read_deadline_sec:1.0 ~handler:immediate_handler
    client_logic
  |> fun (name, outcome) ->
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      if has_goaway frames || has_rst_stream frames then
        print_probe name PASS (Some "server rejected empty-data flood")
      else
        print_probe name FAIL
          (Some
             (Printf.sprintf "server accepted %d empty DATA frames (bytes=%d)"
                flood_count (String.length bytes)))

let probe_priority_on_stream_zero ~env () =
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow
      (Adversarial.h2_request_headers ~stream_id:1 ~end_stream:true
         ~end_headers:true ());
    (* PRIORITY frames must not be sent on stream 0. *)
    write_string flow
      (Malicious_h2.frame ~ty:0x02 ~flags:0x00 ~stream_id:0
         "\x00\x00\x00\x00\x10");
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_priority_on_stream_zero"
    ~deadline_sec:3.0 ~read_deadline_sec:1.0 ~handler:immediate_handler
    client_logic
  |> fun (name, outcome) ->
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      if has_goaway frames then
        print_probe name PASS (Some "server closed with GOAWAY")
      else
        print_probe name POLICY_GAP
          (Some
             (Printf.sprintf "server ignored PRIORITY on stream 0 (bytes=%d)"
                (String.length bytes)))

let probe_settings_flood_mid_stream ~env () =
  let settings_count = 11 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow
      (Adversarial.h2_request_headers ~method_:"POST" ~stream_id:1
         ~end_stream:false ~end_headers:true ());
    for _i = 1 to settings_count do
      write_string flow (Malicious_h2.settings_frame [ (0x3, 10) ])
    done;
    write_string flow
      (Adversarial.h2_request_headers ~method_:"GET" ~stream_id:3
         ~end_stream:true ~end_headers:true ());
    Eio.Flow.shutdown flow `Send
  in
  run_h2c_probe ~env ~name:"h2_streams_settings_flood_mid_stream"
    ~deadline_sec:3.0 ~read_deadline_sec:1.0 ~handler:immediate_handler
    client_logic
  |> fun (name, outcome) ->
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      if has_goaway frames then
        print_probe name PASS (Some "server closed with GOAWAY")
      else
        print_probe name FAIL
          (Some
             (Printf.sprintf "server accepted %d SETTINGS frames (bytes=%d)"
                settings_count (String.length bytes)))

(* ---------------------------------------------------------------------------
   Main
   --------------------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      probe_data_interleaved;
      probe_rst_stream_during_bodies;
      probe_settings_lower_max_concurrent_streams;
      probe_priority_self_dependency;
      probe_tiny_data_chunks;
      probe_headers_flood_no_data;
      probe_unread_bodies_interleaved;
      probe_stalled_body_not_blocking;
      probe_empty_data_flood_many_streams;
      probe_priority_on_stream_zero;
      probe_settings_flood_mid_stream;
    ]
  in
  List.iter (fun f -> f ~env ()) probes;
  Printf.printf "h2_server_streams done\n%!"
