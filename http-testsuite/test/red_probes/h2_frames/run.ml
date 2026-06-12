(* HTTP/2 frame / state-machine red probes.
   Each probe starts an Eta H2C server and drives it with pathological frames.
   The runner exits 0 even when probes find bugs. *)

open Eta_http_testsuite

let h2_client_preface = Adversarial.h2_client_preface
let h2_request_headers = Adversarial.h2_request_headers
let h2_adversarial_config = Adversarial.h2_adversarial_config
let h2_basic_handler = Adversarial.h2_basic_handler
let tcp_port = Adversarial.tcp_port

type status = PASS | FAIL | HANG | CRASH | POLICY_GAP

let string_of_status = function
  | PASS -> "PASS"
  | FAIL -> "FAIL"
  | HANG -> "HANG"
  | CRASH -> "CRASH"
  | POLICY_GAP -> "POLICY_GAP"

let print_probe name status detail =
  Printf.printf "probe %s %s%s\n%!" name (string_of_status status)
    (match detail with None -> "" | Some d -> " " ^ d)

type outcome =
  | Closed of string
  | Read_timeout of string
  | Probe_timeout
  | Errored of string

(** Parse a raw byte sequence into a list of (type, flags, stream_id). *)
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

let has_frame_type ty frames = List.exists (fun (t, _, _) -> t = ty) frames
let has_headers = has_frame_type 0x01
let has_data = has_frame_type 0x00
let has_rst_stream = has_frame_type 0x03
let has_settings = has_frame_type 0x04
let has_ping = has_frame_type 0x06
let has_goaway = has_frame_type 0x07

(** Read from [flow] until it closes, but cap total bytes. *)
let read_until_close ?(max_bytes = 64 * 1024) flow =
  let buffer = Buffer.create 256 in
  let scratch = Cstruct.create 1024 in
  let rec loop total =
    if total >= max_bytes then Buffer.contents buffer
    else
      let len = min (Cstruct.length scratch) (max_bytes - total) in
      match Eio.Flow.single_read flow (Cstruct.sub scratch 0 len) with
      | 0 -> Buffer.contents buffer
      | n ->
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub scratch 0 n));
          loop (total + n)
      | exception End_of_file -> Buffer.contents buffer
  in
  loop 0

(** Drain whatever is currently available with a short timeout. *)
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

(** Start an Eta H2C server on a random port, connect, run [client_fn], and
    record what happens. *)
let run_h2c_probe ~env ~name ~deadline_sec ~read_deadline_sec client_fn =
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
      let config = h2_adversarial_config () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          let flow, peer = Eio.Net.accept ~sw:conn_sw socket in
          let runtime_factory ~sw ~connection:_ () =
            Eta_eio.Runtime.create ~sw ~clock ()
          in
          Eta_http_eio.H2.Server_connection.run_h2c ~sw:conn_sw ~clock
            ~flow:(flow :> Eta_http_eio.H2.Server_connection.flow)
            ~peer ~config ~runtime_factory h2_basic_handler;
          `Stop_daemon);
      let flow =
        Eio.Net.connect ~sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Fun.protect
        ~finally:(fun () ->
          try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          try
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                client_fn ~clock flow;
                match drain_available ~clock ~seconds:read_deadline_sec flow with
                | `Drained bytes -> Closed bytes
                | `Timeout bytes -> Read_timeout bytes
                | `Error (msg, bytes) -> Errored (msg ^ "; drained=" ^ string_of_int (String.length bytes)))
          with
          | Eio.Time.Timeout -> Probe_timeout
          | exn -> Errored (Printexc.to_string exn))
    with exn -> Errored (Printexc.to_string exn)
  in
  name, outcome

(** Assess an outcome for probes that expect the server to reject the input
    and close the connection. *)
let assess_expect_close name outcome =
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes ->
      let frames = parse_frames bytes in
      if has_goaway frames || has_rst_stream frames then
        print_probe name PASS (Some "server closed with error frame")
      else
        print_probe name POLICY_GAP
          (Some
             (Printf.sprintf "server kept connection open (drained %d bytes)"
                (String.length bytes)))
  | Closed bytes ->
      let frames = parse_frames bytes in
      if has_goaway frames || has_rst_stream frames then
        print_probe name PASS (Some "connection closed after error frame")
      else
        print_probe name PASS
          (Some
             (Printf.sprintf "connection closed (%d bytes, no error frame)"
                (String.length bytes)))

(** Assess an outcome for probes that expect the server to tolerate the input
    and respond to a subsequent valid request. *)
let assess_expect_response name outcome =
  match outcome with
  | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
  | Errored msg ->
      if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
        print_probe name HANG (Some "deadline exceeded")
      else print_probe name CRASH (Some msg)
  | Read_timeout bytes | Closed bytes ->
      let frames = parse_frames bytes in
      if has_headers frames then
        print_probe name PASS
          (Some
             (Printf.sprintf "server responded (%d bytes)" (String.length bytes)))
      else if has_goaway frames then
        print_probe name POLICY_GAP
          (Some "server sent GOAWAY instead of tolerating frame")
      else
        print_probe name FAIL
          (Some
             (Printf.sprintf "server closed without response (%d bytes)"
                (String.length bytes)))

(* -------------------------------------------------------------------------- *)
(* Probe implementations                                                      *)
(* -------------------------------------------------------------------------- *)

let probe_data_before_headers ~env () =
  run_h2c_probe ~env ~name:"data_before_headers" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "x")
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_headers_after_end_stream ~env () =
  run_h2c_probe ~env ~name:"headers_after_end_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_stream:true ~end_headers:true ())
        flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_stream:true ~end_headers:true ())
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_continuation_without_headers ~env () =
  run_h2c_probe ~env ~name:"continuation_without_headers" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.continuation_frame ~end_headers:true ~stream_id:1
           (Malicious_h2.hpack_literal ~name:":status" ~value:"200"))
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_headers_on_stream_zero ~env () =
  run_h2c_probe ~env ~name:"headers_on_stream_zero" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:0 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_headers_on_even_stream ~env () =
  run_h2c_probe ~env ~name:"headers_on_even_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:2 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_client_push_promise ~env () =
  run_h2c_probe ~env ~name:"client_push_promise" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      let promised_stream_id = 2 in
      let hpack_block =
        String.concat ""
          [
            Malicious_h2.hpack_literal ~name:":method" ~value:"GET";
            Malicious_h2.hpack_literal ~name:":path" ~value:"/push";
            Malicious_h2.hpack_literal ~name:":scheme" ~value:"http";
            Malicious_h2.hpack_literal ~name:":authority" ~value:"example.test";
          ]
      in
      let payload =
        let buf = Bytes.create 4 in
        Bytes.set_int32_be buf 0
          (Int32.logand (Int32.of_int promised_stream_id) 0x7FFFFFFFl);
        Bytes.to_string buf ^ hpack_block
      in
      Eio.Flow.copy_string
        (Malicious_h2.frame ~ty:0x05 ~flags:0x04 ~stream_id:1 payload)
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_priority_ignored ~env () =
  run_h2c_probe ~env ~name:"priority_ignored" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      (* PRIORITY frame: 5-byte payload exclusive + dependency + weight *)
      Eio.Flow.copy_string
        (Malicious_h2.frame ~ty:0x02 ~flags:0x00 ~stream_id:1
           "\x00\x00\x00\x00\x10")
        flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:1 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_unknown_frame_ignored ~env () =
  run_h2c_probe ~env ~name:"unknown_frame_ignored" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.frame ~ty:0xFF ~flags:0x00 ~stream_id:0 "hello")
        flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:1 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_rst_stream_mid_response ~env () =
  run_h2c_probe ~env ~name:"rst_stream_mid_response" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_stream:false ())
        flow;
      (* Give the server a moment to start the response, then cancel. *)
      Eio.Time.sleep clock 0.1;
      Eio.Flow.copy_string
        (Malicious_h2.rst_stream_frame ~stream_id:1 8)
        flow;
      (* A new request on a fresh stream should still succeed. *)
      Eio.Flow.copy_string (h2_request_headers ~stream_id:3 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_goaway_mid_stream ~env () =
  run_h2c_probe ~env ~name:"goaway_mid_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_stream:false ())
        flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:3 ~end_stream:false ())
        flow;
      Eio.Flow.copy_string
        (Malicious_h2.goaway_frame ~last_stream_id:3 ~error_code:0 ())
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) ->
    (* After GOAWAY the server may close. We mainly care that it does not hang. *)
    match outcome with
    | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
    | Errored msg ->
        if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
          print_probe name HANG (Some "deadline exceeded")
        else print_probe name CRASH (Some msg)
    | Read_timeout bytes | Closed bytes ->
        let frames = parse_frames bytes in
        if has_goaway frames then
          print_probe name PASS (Some "server sent GOAWAY")
        else if has_headers frames then
          print_probe name PASS (Some "active streams completed")
        else
          print_probe name POLICY_GAP
            (Some
               (Printf.sprintf "server closed without GOAWAY (%d bytes)"
                  (String.length bytes)))

let probe_settings_mid_stream ~env () =
  run_h2c_probe ~env ~name:"settings_mid_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~method_:"POST" ~stream_id:1 ~end_stream:false ())
        flow;
      Eio.Flow.copy_string
        (Malicious_h2.settings_frame [ (0x3, 100) ])
        flow;
      (* Wait for SETTINGS ACK before finishing the request body. *)
      let rec wait_ack () =
        let len, ty, flags, _sid = Malicious_h2.read_frame_header flow in
        if ty = 0x04 && flags land 0x01 <> 0 then ()
        else (
          Malicious_h2.skip_frame_payload flow len;
          wait_ack ())
      in
      wait_ack ();
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:true ~stream_id:1 "hello")
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_ping_requires_ack ~env () =
  run_h2c_probe ~env ~name:"ping_requires_ack" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.ping_frame ~ack:false "ping!!!!")
        flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:1 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) ->
    match outcome with
    | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
    | Errored msg ->
        if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
          print_probe name HANG (Some "deadline exceeded")
        else print_probe name CRASH (Some msg)
    | Read_timeout bytes | Closed bytes ->
        let frames = parse_frames bytes in
        let ping_acked =
          List.exists
            (fun (t, f, _) -> t = 0x06 && f land 0x01 <> 0)
            frames
        in
        if ping_acked && has_headers frames then
          print_probe name PASS (Some "PING ACK and response received")
        else if has_headers frames then
          print_probe name PASS (Some "response received (PING ACK not checked)")
        else if ping_acked then
          print_probe name POLICY_GAP (Some "PING ACK but no response")
        else
          print_probe name FAIL (Some "no PING ACK or response")

let probe_window_update_before_headers ~env () =
  run_h2c_probe ~env ~name:"window_update_before_headers" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.window_update_frame ~stream_id:1 1000)
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_data_after_rst_stream ~env () =
  run_h2c_probe ~env ~name:"data_after_rst_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_stream:false ())
        flow;
      Eio.Flow.copy_string
        (Malicious_h2.rst_stream_frame ~stream_id:1 8)
        flow;
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "x")
        flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:3 ()) flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_continuation_fragmentation ~env () =
  run_h2c_probe ~env ~name:"continuation_fragmentation" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_headers:false ~end_stream:true ())
        flow;
      for _i = 1 to 5 do
        Eio.Flow.copy_string
          (Malicious_h2.continuation_frame ~end_headers:false ~stream_id:1
             (Malicious_h2.hpack_literal ~name:"x-fragment" ~value:"a"))
          flow
      done;
      Eio.Flow.copy_string
        (Malicious_h2.continuation_frame ~end_headers:true ~stream_id:1
           (Malicious_h2.hpack_literal ~name:"x-end" ~value:"done"))
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_response name outcome

let probe_rst_stream_on_idle ~env () =
  run_h2c_probe ~env ~name:"rst_stream_on_idle" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.rst_stream_frame ~stream_id:1 8)
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_data_on_stream_zero ~env () =
  run_h2c_probe ~env ~name:"data_on_stream_zero" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:false ~stream_id:0 "x")
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_settings_on_nonzero_stream ~env () =
  run_h2c_probe ~env ~name:"settings_on_nonzero_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.frame ~ty:0x04 ~flags:0x00 ~stream_id:1 "")
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_ping_on_nonzero_stream ~env () =
  run_h2c_probe ~env ~name:"ping_on_nonzero_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (Malicious_h2.frame ~ty:0x06 ~flags:0x00 ~stream_id:1
           (String.make 8 '\x00'))
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_continuation_wrong_stream ~env () =
  run_h2c_probe ~env ~name:"continuation_wrong_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_headers:false ())
        flow;
      Eio.Flow.copy_string
        (Malicious_h2.continuation_frame ~end_headers:true ~stream_id:3
           (Malicious_h2.hpack_literal ~name:"x-end" ~value:"done"))
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) -> assess_expect_close name outcome

let probe_goaway_lower_last_stream ~env () =
  run_h2c_probe ~env ~name:"goaway_lower_last_stream" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:1 ()) flow;
      Eio.Flow.copy_string (h2_request_headers ~stream_id:3 ()) flow;
      (* GOAWAY says the last processed stream was 1, so stream 3 should be
         rejected/ignored. The server should still respond on stream 1. *)
      Eio.Flow.copy_string
        (Malicious_h2.goaway_frame ~last_stream_id:1 ~error_code:0 ())
        flow;
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) ->
    match outcome with
    | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
    | Errored msg ->
        if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
          print_probe name HANG (Some "deadline exceeded")
        else print_probe name CRASH (Some msg)
    | Read_timeout bytes | Closed bytes ->
        let frames = parse_frames bytes in
        if has_goaway frames && has_headers frames then
          print_probe name PASS (Some "GOAWAY and response for stream 1")
        else if has_headers frames then
          print_probe name PASS (Some "response for stream 1")
        else if has_goaway frames then
          print_probe name POLICY_GAP (Some "GOAWAY but no response")
        else
          print_probe name POLICY_GAP
            (Some
               (Printf.sprintf "server closed without response (%d bytes)"
                  (String.length bytes)))

let probe_headers_without_end_headers ~env () =
  run_h2c_probe ~env ~name:"headers_without_end_headers" ~deadline_sec:3.0
    ~read_deadline_sec:1.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string (h2_client_preface ^ Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string
        (h2_request_headers ~stream_id:1 ~end_headers:false ())
        flow;
      (* Do not send CONTINUATION; the server must eventually timeout or error. *)
      Eio.Flow.shutdown flow `Send)
  |> fun (name, outcome) ->
    (* The server may close, send GOAWAY, or hang waiting for CONTINUATION. *)
    match outcome with
    | Probe_timeout -> print_probe name HANG (Some "probe deadline exceeded")
    | Errored msg ->
        if String.starts_with ~prefix:"Eio.Time.Timeout" msg then
          print_probe name HANG (Some "deadline exceeded")
        else print_probe name CRASH (Some msg)
    | Read_timeout bytes | Closed bytes ->
        let frames = parse_frames bytes in
        if has_goaway frames || has_rst_stream frames then
          print_probe name PASS (Some "server rejected incomplete headers")
        else
          print_probe name POLICY_GAP
            (Some
               (Printf.sprintf "server closed without error frame (%d bytes)"
                  (String.length bytes)))

(* -------------------------------------------------------------------------- *)
(* Main                                                                       *)
(* -------------------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      probe_data_before_headers;
      probe_headers_after_end_stream;
      probe_continuation_without_headers;
      probe_headers_on_stream_zero;
      probe_headers_on_even_stream;
      probe_client_push_promise;
      probe_priority_ignored;
      probe_unknown_frame_ignored;
      probe_rst_stream_mid_response;
      probe_goaway_mid_stream;
      probe_settings_mid_stream;
      probe_ping_requires_ack;
      probe_window_update_before_headers;
      probe_data_after_rst_stream;
      probe_continuation_fragmentation;
      probe_rst_stream_on_idle;
      probe_data_on_stream_zero;
      probe_settings_on_nonzero_stream;
      probe_ping_on_nonzero_stream;
      probe_continuation_wrong_stream;
      probe_goaway_lower_last_stream;
      probe_headers_without_end_headers;
    ]
  in
  List.iter (fun f -> f ~env ()) probes;
  Printf.printf "h2_frames done\n%!"
