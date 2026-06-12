(** h2_flow: HTTP/2 flow-control / slow-reader red probes.

    These probes intentionally withhold or pervert WINDOW_UPDATE frames to see
    whether eta_http_eio bounds the resulting server-side stalls. A hang past
    the deadline is recorded as a finding, not a test failure. *)

open Eio.Std
open Eta_http_testsuite

let h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let write_string flow s = Eio.Flow.copy_string s flow

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

let goaway_error_code payload =
  if String.length payload < 8 then 0
  else
    (Char.code (String.get payload 4) lsl 24)
    lor (Char.code (String.get payload 5) lsl 16)
    lor (Char.code (String.get payload 6) lsl 8)
    lor Char.code (String.get payload 7)

let rst_stream_error_code payload =
  if String.length payload < 4 then 0
  else
    (Char.code (String.get payload 0) lsl 24)
    lor (Char.code (String.get payload 1) lsl 16)
    lor (Char.code (String.get payload 2) lsl 8)
    lor Char.code (String.get payload 3)

let settings_ack = Malicious_h2.settings_frame ~ack:true []

let flow_stall_config () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      response_write_timeout = Some (Eta.Duration.ms 250);
    }
  in
  let server = { Eta_http.Server.Config.default with timeouts } in
  { (Adversarial.h2_adversarial_config ()) with server }

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

let rec read_response_headers flow =
  let len, ty, _flags, _sid = read_frame_header flow in
  let payload = read_payload flow len in
  if ty = 0x04 then read_response_headers flow
  else if ty = 0x01 then `Headers
  else if ty = 0x07 then `Goaway (goaway_error_code payload, 9 + len)
  else read_response_headers flow

(** A handler that produces a large streaming response body so that outbound
    flow control actually matters. *)
let large_handler total_bytes _request =
  let remaining = ref total_bytes in
  let chunk_size = 16 * 1024 in
  let read () =
    if !remaining <= 0 then Eta.Effect.pure None
    else
      let n = min !remaining chunk_size in
      remaining := !remaining - n;
      Eta.Effect.pure (Some (Bytes.make n 'x'))
  in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200
       ~body:(Eta_http.Server.Response.Body.stream ~length:total_bytes read)
       ())

(** Drain frames until the server closes the connection or an error occurs. *)
let drain_until_close ?(max_bytes = 1024 * 1024) flow =
  let total = ref 0 in
  let rec loop () =
    if !total >= max_bytes then `Data_limit !total
    else
      let len, ty, _flags, _sid = read_frame_header flow in
      let payload = read_payload flow len in
      total := !total + 9 + len;
      if ty = 0x07 then
        let code = goaway_error_code payload in
        `Goaway (code, !total)
      else if ty = 0x03 then
        let code = rst_stream_error_code payload in
        `Rst_stream (code, !total)
      else loop ()
  in
  try loop () with
  | End_of_file -> `Closed !total
  | exn -> `Error (Printexc.to_string exn)

let rec slow_drain ~clock flow =
  let len, ty, _flags, _sid = read_frame_header flow in
  let payload = read_payload flow len in
  if ty = 0x07 then
    let code = goaway_error_code payload in
    `Goaway (code, 0)
  else if ty = 0x03 then
    let code = rst_stream_error_code payload in
    `Rst_stream (code, 0)
  else (
    Eio.Time.sleep clock 0.5;
    write_string flow (Malicious_h2.window_update_frame ~stream_id:1 1);
    slow_drain ~clock flow)

type outcome =
  [ `Closed of int
  | `Goaway of int * int
  | `Rst_stream of int * int
  | `Data_limit of int
  | `Timeout
  | `Error of string
  ]

let run_probe ~env ~name ?config ~deadline_sec ~handler client_logic =
  let start = Unix.gettimeofday () in
  let outcome =
    try
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port =
        match Eio.Net.listening_addr socket with
        | `Tcp (_, p) -> p
        | `Unix _ -> failwith "expected TCP listener"
      in
      let config =
        Option.value config ~default:(Adversarial.h2_adversarial_config ())
      in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          let flow, peer = Eio.Net.accept ~sw:conn_sw socket in
          let runtime_factory ~sw ~connection:_ () =
            Eta_eio.Runtime.create ~sw ~clock ()
          in
          Eta_http_eio.H2.Server_connection.run_h2c ~sw:conn_sw ~clock
            ~flow:(flow :> Eta_http_eio.H2.Server_connection.flow)
            ~peer ~config ~runtime_factory handler;
          `Stop_daemon);
      let flow =
        Eio.Net.connect ~sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Fun.protect
        ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          try
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                client_logic ~clock flow)
          with
          | Eio.Time.Timeout -> `Timeout
          | exn -> `Error (Printexc.to_string exn))
    with exn -> `Error (Printexc.to_string exn)
  in
  let duration_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  (outcome, duration_ms)

let string_contains needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.starts_with ~prefix:needle (String.sub haystack i (h - i)) then true
    else loop (i + 1)
  in
  loop 0

let status_of_outcome = function
  | `Closed _ -> "PASS"
  | `Goaway (code, _) when code = 3 || code = 1 -> "PASS"
    (* FLOW_CONTROL_ERROR or PROTOCOL_ERROR are acceptable reactions. *)
  | `Goaway (code, _) -> Printf.sprintf "FAIL goaway_code=%d" code
  | `Rst_stream (code, _) when code = 3 || code = 1 || code = 2 -> "PASS"
    (* FLOW_CONTROL_ERROR, PROTOCOL_ERROR, or INTERNAL_ERROR all bound the
       affected stream without poisoning the connection. *)
  | `Rst_stream (code, _) -> Printf.sprintf "FAIL rst_stream_code=%d" code
  | `Data_limit n -> Printf.sprintf "FAIL data_limit=%d" n
  | `Timeout -> "HANG"
  | `Error msg ->
      if string_contains "Timeout" msg then "HANG"
      else "CRASH " ^ msg

let detail_of_outcome = function
  | `Closed n -> Printf.sprintf "closed bytes=%d" n
  | `Goaway (code, n) -> Printf.sprintf "goaway code=%d bytes=%d" code n
  | `Rst_stream (code, n) -> Printf.sprintf "rst_stream code=%d bytes=%d" code n
  | `Data_limit n -> Printf.sprintf "read limit bytes=%d" n
  | `Timeout -> "deadline exceeded"
  | `Error msg -> msg

let print_probe name outcome =
  let status = status_of_outcome outcome in
  let detail = detail_of_outcome outcome in
  Printf.printf "probe %s %s [%s]\n%!" name status detail

(* ---------------------------------------------------------------------------
   Probe 1: tiny initial window
   --------------------------------------------------------------------------- *)
let probe_tiny_initial_window ~env =
  let client_logic ~clock:_ flow =
    ignore (h2_handshake ~settings:[ (4, 1) ] flow : string);
    write_string flow (Adversarial.h2_request_headers ~stream_id:1 ());
    match read_response_headers flow with
    | `Goaway (code, n) -> `Goaway (code, n)
    | `Headers -> drain_until_close flow
  in
  let outcome, duration_ms =
    run_probe ~env ~name:"h2_flow_tiny_initial_window"
      ~config:(flow_stall_config ()) ~deadline_sec:3.0
      ~handler:(large_handler (1024 * 1024)) client_logic
  in
  ("h2_flow_tiny_initial_window", outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Probe 2: withheld WINDOW_UPDATE
   --------------------------------------------------------------------------- *)
let probe_withheld_window_update ~env =
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow (Adversarial.h2_request_headers ~stream_id:1 ());
    match read_response_headers flow with
    | `Goaway (code, n) -> `Goaway (code, n)
    | `Headers -> drain_until_close flow
  in
  let outcome, duration_ms =
    run_probe ~env ~name:"h2_flow_withheld_window_update"
      ~config:(flow_stall_config ()) ~deadline_sec:3.0
      ~handler:(large_handler (1024 * 1024)) client_logic
  in
  ("h2_flow_withheld_window_update", outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Probe 3: WINDOW_UPDATE overflow
   --------------------------------------------------------------------------- *)
let probe_window_update_overflow ~env =
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    write_string flow (Adversarial.h2_request_headers ~stream_id:1 ());
    match read_response_headers flow with
    | `Goaway (code, n) -> `Goaway (code, n)
    | `Headers ->
        write_string flow
          (Malicious_h2.window_update_frame ~stream_id:1 0x7FFFFFFF);
        drain_until_close flow
  in
  let outcome, duration_ms =
    run_probe ~env ~name:"h2_flow_window_update_overflow"
      ~config:(flow_stall_config ()) ~deadline_sec:3.0
      ~handler:(large_handler (1024 * 1024)) client_logic
  in
  ("h2_flow_window_update_overflow", outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Probe 4: slow reader
   The client grants one byte of window at a time with a delay between each.
   --------------------------------------------------------------------------- *)
let probe_slow_client_read ~env =
  let client_logic ~clock flow =
    ignore (h2_handshake ~settings:[ (4, 1) ] flow : string);
    write_string flow (Adversarial.h2_request_headers ~stream_id:1 ());
    match read_response_headers flow with
    | `Goaway (code, n) -> `Goaway (code, n)
    | `Headers -> slow_drain ~clock flow
  in
  let outcome, duration_ms =
    run_probe ~env ~name:"h2_flow_slow_client_read"
      ~config:(flow_stall_config ()) ~deadline_sec:3.0
      ~handler:(large_handler (1024 * 1024)) client_logic
  in
  ("h2_flow_slow_client_read", outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Probe 5: concurrent stalled streams near max_concurrent_streams
   --------------------------------------------------------------------------- *)
let probe_concurrent_stalled_streams ~env =
  let stream_count = 120 in
  let client_logic ~clock:_ flow =
    ignore (h2_handshake flow : string);
    for i = 1 to stream_count do
      let stream_id = (i * 2) - 1 in
      write_string flow (Adversarial.h2_request_headers ~stream_id ())
    done;
    match read_response_headers flow with
    | `Goaway (code, n) -> `Goaway (code, n)
    | `Headers -> drain_until_close flow
  in
  let outcome, duration_ms =
    run_probe ~env ~name:"h2_flow_concurrent_stalled_streams"
      ~config:(flow_stall_config ()) ~deadline_sec:5.0
      ~handler:(large_handler (1024 * 1024)) client_logic
  in
  ("h2_flow_concurrent_stalled_streams", outcome, duration_ms)

(* ---------------------------------------------------------------------------
   Main
   --------------------------------------------------------------------------- *)
let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      probe_tiny_initial_window ~env;
      probe_withheld_window_update ~env;
      probe_window_update_overflow ~env;
      probe_slow_client_read ~env;
      probe_concurrent_stalled_streams ~env;
    ]
  in
  List.iter (fun (name, outcome, _duration_ms) -> print_probe name outcome) probes
