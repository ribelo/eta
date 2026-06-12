(* TLS/H2 fragmentation red probes for eta_http / eta_http_eio.
   These probes intentionally fragment TLS records and HTTP/2 frames to look
   for hangs, crashes, or resource leaks in the Eta TLS and H2 paths. *)

open Eta_http_testsuite
open Eio.Std

let backend_name () =
  match Sys.getenv_opt "EIO_BACKEND" with
  | Some "posix" -> "posix"
  | Some other -> "forced_" ^ other
  | None -> "default"

let status_to_string = function
  | `Pass -> "PASS"
  | `Fail -> "FAIL"
  | `Hang -> "HANG"
  | `Crash -> "CRASH"
  | `Policy_gap -> "POLICY_GAP"

let emit_probe name status detail =
  Printf.printf "probe %s_%s %s %s\n%!"
    (backend_name ())
    name
    (status_to_string status)
    detail

type 'a probe_result =
  | Ok of 'a
  | Hang
  | Crash of string

let run_with_deadline ~clock ~deadline_sec f =
  try
    Eio.Time.with_timeout_exn clock deadline_sec (fun () -> Ok (f ()))
  with
  | Eio.Time.Timeout -> Hang
  | exn -> Crash (Printexc.to_string exn)

let close_flow flow =
  try Eio.Flow.shutdown flow `All with _ -> ()

let close_server server =
  try Eta_http_eio.Server.shutdown server Immediate with _ -> ()

let start_https_server ~sw ~env ~protocol () =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let temp_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      ("eta_tls_frag_" ^ backend_name ())
  in
  Util.mkdir_p temp_dir;
  let cert_dir =
    match Certs.prepare ~temp_dir with
    | Ok d -> d
    | Error e -> failwith e
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = Adversarial.tcp_port (Eio.Net.listening_addr socket) in
  let tls_config = Eta_server.tls_config cert_dir protocol in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock
      ~config:Eta_server.config ~tls_config ~socket
      (Eta_server.handler ~temp_dir)
  in
  (server, port, cert_dir)

let host_peer_name s =
  match Domain_name.of_string s with
  | Ok dn -> Domain_name.host_exn dn
  | Error (`Msg e) -> failwith ("invalid peer name: " ^ e)

let client_tls_config ~cert_dir ~alpn_protocols =
  Eta_http.Tls.Config.default_client
    ~peer_name:(host_peer_name "localhost")
    ~alpn_protocols
    ~ca_file:(Certs.ca_path cert_dir)
    ()

let connect_tls ~sw ~env ~port ~cert_dir ~alpn_protocols () =
  let net = Eio.Stdenv.net env in
  let tcp =
    Eio.Net.connect ~sw net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let flow =
    (tcp :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let config = client_tls_config ~cert_dir ~alpn_protocols in
  Eta_http_eio.Tls.Eio.client_of_flow config flow

let write_byte_by_byte ?(delay_sec = 0.0) ~clock flow s =
  for i = 0 to String.length s - 1 do
    Eio.Flow.copy_string (String.make 1 s.[i]) flow;
    if delay_sec > 0.0 then Eio.Time.sleep clock delay_sec
  done

let read_h1_status ~clock flow =
  Eio.Time.with_timeout_exn clock 2.0 (fun () ->
      let response = Adversarial.read_h1_response flow in
      match Adversarial.h1_status response with
      | Some status -> Printf.sprintf "status=%d" status
      | None -> "malformed_response")

let read_h2_response ~clock flow =
  Eio.Time.with_timeout_exn clock 2.0 (fun () ->
      match Adversarial.read_h2_until_close flow with
      | `Closed s -> Printf.sprintf "closed bytes=%d" (String.length s)
      | `Data_limit s -> Printf.sprintf "limit bytes=%d" (String.length s))

let run_tls_client_probe ~env ~protocol ~alpn_protocols ~name ~deadline_sec
    client_fn =
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  match
    run_with_deadline ~clock ~deadline_sec (fun () ->
        let server, port, cert_dir =
          start_https_server ~sw ~env ~protocol ()
        in
        Fun.protect
          ~finally:(fun () -> close_server server)
          (fun () ->
            let flow =
              connect_tls ~sw ~env ~port ~cert_dir ~alpn_protocols ()
            in
            Fun.protect
              ~finally:(fun () -> close_flow flow)
              (fun () -> client_fn ~clock flow)))
  with
  | Ok msg -> emit_probe name `Pass msg
  | Hang -> emit_probe name `Hang "deadline_exceeded"
  | Crash msg -> emit_probe name `Crash msg

(* Raw-TCP probes: speak plaintext to the TLS port. *)
let run_raw_tcp_probe ~env ~protocol ~name ~deadline_sec client_fn =
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server, port, _cert_dir =
    start_https_server ~sw ~env ~protocol ()
  in
  let result =
    run_with_deadline ~clock ~deadline_sec (fun () ->
        let net = Eio.Stdenv.net env in
        let flow =
          Eio.Net.connect ~sw net
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
        in
        Fun.protect
          ~finally:(fun () -> close_flow flow)
          (fun () -> client_fn ~clock flow))
  in
  close_server server;
  match result with
  | Ok msg -> emit_probe name `Pass msg
  | Hang -> emit_probe name `Hang "deadline_exceeded"
  | Crash msg -> emit_probe name `Crash msg

(* ---------------------------------------------------------------------------
   Individual probes
   --------------------------------------------------------------------------- *)

let h1_byte_records ~env =
  run_tls_client_probe ~env ~protocol:H1 ~alpn_protocols:[ "http/1.1" ]
    ~name:"h1_byte_records" ~deadline_sec:5.0 (fun ~clock flow ->
      let request =
        "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      in
      write_byte_by_byte ~clock flow request;
      read_h1_status ~clock flow)

let h2_byte_frames ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"h2_byte_frames" ~deadline_sec:5.0 (fun ~clock flow ->
      let request =
        Adversarial.h2_client_preface
        ^ Malicious_h2.settings_frame []
        ^ Malicious_h2.settings_frame ~ack:true []
        ^ Adversarial.h2_request_headers ~stream_id:1 ()
      in
      write_byte_by_byte ~clock flow request;
      read_h2_response ~clock flow)

let h2_tiny_writes ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"h2_tiny_writes" ~deadline_sec:5.0 (fun ~clock flow ->
      (* Valid H2 POST with DATA, but every TLS write is one byte. *)
      let request =
        Adversarial.h2_client_preface
        ^ Malicious_h2.settings_frame []
        ^ Malicious_h2.settings_frame ~ack:true []
        ^ Adversarial.h2_request_headers ~method_:"POST" ~end_stream:false
            ~stream_id:1 ()
        ^ Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "hello"
        ^ Malicious_h2.data_frame ~end_stream:true ~stream_id:1 ""
      in
      write_byte_by_byte ~clock flow request;
      read_h2_response ~clock flow)

let h2_slow_preface ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"h2_slow_preface" ~deadline_sec:5.0 (fun ~clock flow ->
      (* Send the 24-byte preface one byte every 100ms, then finish quickly. *)
      write_byte_by_byte ~delay_sec:0.1 ~clock flow Adversarial.h2_client_preface;
      let rest =
        Malicious_h2.settings_frame []
        ^ Malicious_h2.settings_frame ~ack:true []
        ^ Adversarial.h2_request_headers ~stream_id:1 ()
      in
      Eio.Flow.copy_string rest flow;
      read_h2_response ~clock flow)

let h2_data_payload_byte ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"h2_data_payload_byte" ~deadline_sec:5.0 (fun ~clock flow ->
      (* All H2 frame headers sent normally; only the DATA payload bytes are
         delivered as one byte per TLS record. *)
      Eio.Flow.copy_string Adversarial.h2_client_preface flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame ~ack:true []) flow;
      Eio.Flow.copy_string
        (Adversarial.h2_request_headers ~method_:"POST" ~end_stream:false
           ~stream_id:1 ())
        flow;
      Eio.Flow.copy_string
        (Adversarial.h2_frame_header ~length:5 ~ty:0x00 ~flags:0x00
           ~stream_id:1)
        flow;
      write_byte_by_byte ~clock flow "hello";
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:true ~stream_id:1 "")
        flow;
      read_h2_response ~clock flow)

let h2_data_frame_byte ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"h2_data_frame_byte" ~deadline_sec:5.0 (fun ~clock flow ->
      (* Preface/SETTINGS/HEADERS sent normally; the DATA frame (header+payload)
         is sent one byte per TLS record. *)
      Eio.Flow.copy_string Adversarial.h2_client_preface flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame ~ack:true []) flow;
      Eio.Flow.copy_string
        (Adversarial.h2_request_headers ~method_:"POST" ~end_stream:false
           ~stream_id:1 ())
        flow;
      let data_frame =
        Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "hello"
      in
      write_byte_by_byte ~clock flow data_frame;
      Eio.Flow.copy_string
        (Malicious_h2.data_frame ~end_stream:true ~stream_id:1 "")
        flow;
      read_h2_response ~clock flow)

let h1_body_byte_records ~env =
  run_tls_client_probe ~env ~protocol:H1 ~alpn_protocols:[ "http/1.1" ]
    ~name:"h1_body_byte_records" ~deadline_sec:5.0 (fun ~clock flow ->
      Eio.Flow.copy_string
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n"
        flow;
      write_byte_by_byte ~clock flow "hello";
      read_h1_status ~clock flow)

let h1_body_ignored_byte_records ~env =
  run_tls_client_probe ~env ~protocol:H1 ~alpn_protocols:[ "http/1.1" ]
    ~name:"h1_body_ignored_byte_records" ~deadline_sec:5.0 (fun ~clock flow ->
      Eio.Flow.copy_string
        "POST /healthz HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n"
        flow;
      write_byte_by_byte ~clock flow "hello";
      read_h1_status ~clock flow)

let h2c_data_payload_byte ~env =
  (* Isolation probe: same fragmented DATA payload over cleartext H2C to show
     the hang is not specific to TLS framing. *)
  let result =
    Adversarial.run_eta_h2c_adversarial_client ~env
      ~name:"h2c_data_payload_byte"
      ~deadline_sec:5.0 (fun flow ->
        Eio.Flow.copy_string
          (Adversarial.h2_request_headers ~method_:"POST" ~end_stream:false
             ~stream_id:1 ())
          flow;
        Eio.Flow.copy_string
          (Adversarial.h2_frame_header ~length:5 ~ty:0x00 ~flags:0x00
             ~stream_id:1)
          flow;
        let clock = Eio.Stdenv.clock env in
        write_byte_by_byte ~clock flow "hello";
        Eio.Flow.copy_string
          (Malicious_h2.data_frame ~end_stream:true ~stream_id:1 "")
          flow)
  in
  emit_probe "h2c_data_payload_byte"
    (if result.deadline_respected then `Pass else `Hang)
    (Option.value result.error_variant ~default:"ok")

let shutdown_during_handshake ~env =
  run_raw_tcp_probe ~env ~protocol:H2 ~name:"shutdown_during_handshake"
    ~deadline_sec:5.0 (fun ~clock:_ flow ->
      (* Send plaintext HTTP bytes to the TLS port and half-close. *)
      Eio.Flow.copy_string "GET / HTTP/1.1\r\nHost: localhost\r\n" flow;
      Eio.Flow.shutdown flow `Send;
      (* Drain any alert/response bytes until EOF. *)
      let buf = Cstruct.create 4096 in
      (try
         while true do
           let n = Eio.Flow.single_read flow buf in
           if n = 0 then raise Exit
         done
       with End_of_file | Exit -> ());
      "connection_closed")

let shutdown_during_headers ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"shutdown_during_headers" ~deadline_sec:5.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string Adversarial.h2_client_preface flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame ~ack:true []) flow;
      (* Only the first five bytes of a HEADERS frame, then close TLS. *)
      let partial_headers =
        String.sub (Adversarial.h2_request_headers ~stream_id:1 ()) 0 5
      in
      Eio.Flow.copy_string partial_headers flow;
      close_flow flow;
      "connection_closed")

let shutdown_during_data ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"shutdown_during_data" ~deadline_sec:5.0 (fun ~clock:_ flow ->
      Eio.Flow.copy_string Adversarial.h2_client_preface flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame []) flow;
      Eio.Flow.copy_string (Malicious_h2.settings_frame ~ack:true []) flow;
      Eio.Flow.copy_string
        (Adversarial.h2_request_headers ~method_:"POST" ~end_stream:false
           ~stream_id:1 ())
        flow;
      (* DATA header declares 100 bytes but only send five, then close TLS. *)
      let partial_data =
        Adversarial.h2_frame_header ~length:100 ~ty:0x00 ~flags:0x00
          ~stream_id:1
        ^ "hello"
      in
      Eio.Flow.copy_string partial_data flow;
      close_flow flow;
      "connection_closed")

let shutdown_during_trailers ~env =
  run_tls_client_probe ~env ~protocol:H1 ~alpn_protocols:[ "http/1.1" ]
    ~name:"shutdown_during_trailers" ~deadline_sec:5.0 (fun ~clock:_ flow ->
      let request =
        "POST /echo HTTP/1.1\r\nHost: localhost\r\n"
        ^ "Transfer-Encoding: chunked\r\n\r\n"
        ^ "5\r\nhello\r\n0\r\nX-Trailer:"
      in
      Eio.Flow.copy_string request flow;
      close_flow flow;
      "connection_closed")

let alpn_h2_only ~env =
  run_tls_client_probe ~env ~protocol:H2 ~alpn_protocols:[ "h2" ]
    ~name:"alpn_h2_only" ~deadline_sec:5.0 (fun ~clock flow ->
      let request =
        Adversarial.h2_client_preface
        ^ Malicious_h2.settings_frame []
        ^ Malicious_h2.settings_frame ~ack:true []
        ^ Adversarial.h2_request_headers ~stream_id:1 ()
      in
      Eio.Flow.copy_string request flow;
      read_h2_response ~clock flow)

(* ---------------------------------------------------------------------------
   Runner
   --------------------------------------------------------------------------- *)

let () =
  Printf.printf "tls_frag backend=%s\n%!" (backend_name ());
  Eio_main.run @@ fun env ->
  let probes =
    [
      h1_byte_records;
      h1_body_byte_records;
      h1_body_ignored_byte_records;
      h2_byte_frames;
      h2_data_payload_byte;
      h2_data_frame_byte;
      h2_tiny_writes;
      h2_slow_preface;
      h2c_data_payload_byte;
      shutdown_during_handshake;
      shutdown_during_headers;
      shutdown_during_data;
      shutdown_during_trailers;
      alpn_h2_only;
    ]
  in
  List.iter (fun probe -> probe ~env) probes;
  Printf.printf "tls_frag done\n%!"
