(* Red probe: handler failure phases.
   Each probe installs a misbehaving Eta handler and drives the server with a
   minimal raw client. The goal is to surface hangs, crashes, or protocol-level
   divergence, not to assert correctness. *)

open Eta_http_testsuite

type probe_status = Pass | Fail | Hang | Crash | Policy_gap

let string_of_status = function
  | Pass -> "PASS"
  | Fail -> "FAIL"
  | Hang -> "HANG"
  | Crash -> "CRASH"
  | Policy_gap -> "POLICY_GAP"

let print_probe name status detail =
  match detail with
  | None -> Printf.printf "probe %s %s\n%!" name (string_of_status status)
  | Some d ->
      Printf.printf "probe %s %s %s\n%!" name (string_of_status status) d

let header_list entries =
  match Eta_http.Core.Header.of_list entries with
  | Ok headers -> headers
  | Error _ -> invalid_arg "handler_fail: invalid header list"

let h1_get_request =
  "GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"

let h2_request =
  Adversarial.h2_client_preface
  ^ Malicious_h2.settings_frame []
  ^ Adversarial.h2_request_headers ~stream_id:1 ()

(* ---------------------------------------------------------------------------
   H1 driver
   --------------------------------------------------------------------------- *)

let run_h1_probe ~env ~handler ~deadline_sec ~judge () =
  try
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let socket =
      Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port = Adversarial.tcp_port (Eio.Net.listening_addr socket) in
    let config = Adversarial.h1_adversarial_config () in
    let server =
      Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket handler
    in
    let flow =
      Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    Fun.protect
      ~finally:(fun () ->
        (try Eio.Flow.shutdown flow `All with _ -> ());
        Eta_http_eio.Server.shutdown server Immediate)
      (fun () ->
        try
          let response =
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                Eio.Flow.copy_string h1_get_request flow;
                Adversarial.read_h1_response flow)
          in
          judge response
        with
        | Eio.Time.Timeout -> (Hang, Some "deadline exceeded")
        | exn -> (Crash, Some (Printexc.to_string exn)))
  with exn -> (Crash, Some (Printexc.to_string exn))

let h1_body_after_headers response =
  let len = String.length response in
  let rec find off =
    if off + 4 > len then ""
    else if String.sub response off 4 = "\r\n\r\n" then
      String.sub response (off + 4) (len - off - 4)
    else find (off + 1)
  in
  find 0

let judge_h1_handler_raise response =
  match Adversarial.h1_status response with
  | Some 500 -> (Pass, Some "status 500")
  | Some s -> (Fail, Some (Printf.sprintf "status %d" s))
  | None -> (Crash, Some "no status line")

let judge_h1_body_thunk response =
  match Adversarial.h1_status response with
  | Some 500 -> (Pass, Some "recovered with 500")
  | Some s ->
      ( Policy_gap,
        Some (Printf.sprintf "status %d before connection closed" s) )
  | None -> (Crash, Some "no response")

let judge_h1_stream_partial response =
  match Adversarial.h1_status response with
  | Some 500 -> (Pass, Some "recovered with 500")
  | Some 200 ->
      let body = h1_body_after_headers response in
      let body_len = String.length body in
      if body_len < 10 then
        ( Policy_gap,
          Some
            (Printf.sprintf "200 with truncated body len=%d (declared 10)"
               body_len) )
      else (Pass, Some "200 with full body")
  | Some s -> (Policy_gap, Some (Printf.sprintf "status %d" s))
  | None -> (Crash, Some "no response")

let judge_h1_trailers response =
  match Adversarial.h1_status response with
  | Some 500 -> (Pass, Some "recovered with 500")
  | Some 200 when String.ends_with ~suffix:"0\r\n\r\n" response ->
      (Pass, Some "chunked response completed")
  | Some 200 ->
      (Policy_gap, Some "200 without terminal chunk after trailer failure")
  | Some s -> (Policy_gap, Some (Printf.sprintf "status %d" s))
  | None -> (Crash, Some "no response")

let judge_h1_cancel response =
  match Adversarial.h1_status response with
  | Some 500 -> (Pass, Some "status 500")
  | Some s -> (Policy_gap, Some (Printf.sprintf "status %d" s))
  | None -> (Policy_gap, Some "connection closed without response")

(* ---------------------------------------------------------------------------
   H2C driver
   --------------------------------------------------------------------------- *)

let h2_has_frame bytes ty =
  let len = String.length bytes in
  let rec scan off =
    if off + 9 > len then false
    else
      let frame_type = Char.code (String.get bytes (off + 3)) in
      if frame_type = ty then true
      else
        let length =
          (Char.code (String.get bytes off) lsl 16)
          lor (Char.code (String.get bytes (off + 1)) lsl 8)
          lor Char.code (String.get bytes (off + 2))
        in
        scan (off + 9 + length)
  in
  scan 0

let h2_summary bytes =
  Printf.sprintf "len=%d headers=%b rst=%b" (String.length bytes)
    (h2_has_frame bytes 0x01) (h2_has_frame bytes 0x03)

let h2_judge_with_rst detail bytes =
  let has_headers = h2_has_frame bytes 0x01 in
  let has_rst = h2_has_frame bytes 0x03 in
  let summary = h2_summary bytes in
  match (has_headers, has_rst) with
  | true, true -> (Pass, Some ("headers + rst_stream: " ^ detail ^ " (" ^ summary ^ ")"))
  | true, false ->
      ( Fail,
        Some ("headers without rst_stream: " ^ detail ^ " (" ^ summary ^ ")") )
  | false, true -> (Fail, Some ("rst_stream without headers (" ^ summary ^ ")"))
  | false, false -> (Crash, Some ("no h2 frames received (" ^ summary ^ ")"))

let h2_judge_response detail bytes =
  let has_headers = h2_has_frame bytes 0x01 in
  let has_rst = h2_has_frame bytes 0x03 in
  let summary = h2_summary bytes in
  if has_headers && not has_rst then
    (Pass, Some ("headers response: " ^ detail ^ " (" ^ summary ^ ")"))
  else if has_rst then
    (Policy_gap, Some ("unexpected rst_stream: " ^ detail ^ " (" ^ summary ^ ")"))
  else (Crash, Some ("no h2 frames received (" ^ summary ^ ")"))

let run_h2c_probe ~env ~handler ~deadline_sec ~judge () =
  try
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let socket =
      Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port = Adversarial.tcp_port (Eio.Net.listening_addr socket) in
    let config =
      Adversarial.h2_adversarial_config
        ~idle_timeout:(Some (Eta.Duration.ms 300))
        ()
    in
    let server =
      Eta_http_eio.Server.start_h2c_on_socket ~sw ~clock ~config ~socket handler
    in
    let flow =
      Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    Fun.protect
      ~finally:(fun () ->
        (try Eio.Flow.shutdown flow `All with _ -> ());
        Eta_http_eio.Server.shutdown server Immediate)
      (fun () ->
        try
          let result =
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                Eio.Flow.copy_string h2_request flow;
                Eio.Flow.shutdown flow `Send;
                Adversarial.read_h2_until_close flow)
          in
          match result with
          | `Closed bytes | `Data_limit bytes -> judge bytes
        with
        | Eio.Time.Timeout -> (Hang, Some "deadline exceeded")
        | exn -> (Crash, Some (Printexc.to_string exn)))
  with exn -> (Crash, Some (Printexc.to_string exn))

(* ---------------------------------------------------------------------------
   Misbehaving handlers
   --------------------------------------------------------------------------- *)

let handler_raise _request = failwith "handler raised before returning effect"

let read_raises () = failwith "response body thunk raised"

let handler_body_thunk_h1 _request =
  let body = Eta_http.Server.Response.Body.stream ~length:10 read_raises in
  let headers = header_list [ ("Content-Length", "10") ] in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200 ~headers ~body ())

let handler_body_thunk_h2 _request =
  let body = Eta_http.Server.Response.Body.stream ~length:10 read_raises in
  Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())

let handler_stream_partial_h1 _request =
  let counter = ref 0 in
  let read () =
    incr counter;
    if !counter = 1 then Eta.Effect.pure (Some (Bytes.of_string "abc"))
    else failwith "stream read raised after partial body"
  in
  let body = Eta_http.Server.Response.Body.stream ~length:10 read in
  let headers = header_list [ ("Content-Length", "10") ] in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200 ~headers ~body ())

let handler_stream_partial_h2 _request =
  let counter = ref 0 in
  let read () =
    incr counter;
    if !counter = 1 then Eta.Effect.pure (Some (Bytes.of_string "abc"))
    else failwith "stream read raised after partial body"
  in
  let body = Eta_http.Server.Response.Body.stream ~length:10 read in
  Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())

let handler_trailers_h1 _request =
  let counter = ref 0 in
  let read () =
    incr counter;
    if !counter = 1 then Eta.Effect.pure (Some (Bytes.of_string "hello"))
    else Eta.Effect.pure None
  in
  let trailers () = failwith "trailers construction raised" in
  let body = Eta_http.Server.Response.Body.stream read in
  let headers =
    header_list
      [ ("Transfer-Encoding", "chunked"); ("Trailer", "X-Trailer") ]
  in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200 ~headers ~body ~trailers ())

let handler_trailers_h2 _request =
  let counter = ref 0 in
  let read () =
    incr counter;
    if !counter = 1 then Eta.Effect.pure (Some (Bytes.of_string "hello"))
    else Eta.Effect.pure None
  in
  let trailers () = failwith "trailers construction raised" in
  let body = Eta_http.Server.Response.Body.stream read in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200 ~body ~trailers ())

let handler_cancel_h1 _request =
  let read () =
    Eta.Effect.sync (fun () ->
        Eio.Cancel.sub (fun ctx ->
            Eio.Cancel.cancel ctx (Failure "probe cancellation during response");
            Eio.Cancel.check ctx;
            assert false))
  in
  let body = Eta_http.Server.Response.Body.stream ~length:10 read in
  let headers = header_list [ ("Content-Length", "10") ] in
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200 ~headers ~body ())

let handler_cancel_h2 _request =
  let read () =
    Eta.Effect.sync (fun () ->
        Eio.Cancel.sub (fun ctx ->
            Eio.Cancel.cancel ctx (Failure "probe cancellation during response");
            Eio.Cancel.check ctx;
            assert false))
  in
  let body = Eta_http.Server.Response.Body.stream ~length:10 read in
  Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let () =
  Eio_main.run @@ fun env ->
  let probes =
    [
      ( "h1_handler_raise_before_effect",
        run_h1_probe ~env ~handler:handler_raise ~deadline_sec:2.0
          ~judge:judge_h1_handler_raise );
      ( "h1_response_body_thunk_raise",
        run_h1_probe ~env ~handler:handler_body_thunk_h1 ~deadline_sec:2.0
          ~judge:judge_h1_body_thunk );
      ( "h1_stream_read_raise_after_partial",
        run_h1_probe ~env ~handler:handler_stream_partial_h1 ~deadline_sec:2.0
          ~judge:judge_h1_stream_partial );
      ( "h1_trailers_construction_raise",
        run_h1_probe ~env ~handler:handler_trailers_h1 ~deadline_sec:2.0
          ~judge:judge_h1_trailers );
      ( "h1_cancellation_during_response",
        run_h1_probe ~env ~handler:handler_cancel_h1 ~deadline_sec:2.0
          ~judge:judge_h1_cancel );
      ( "h2_handler_raise_before_effect",
        run_h2c_probe ~env ~handler:handler_raise ~deadline_sec:2.0
          ~judge:(h2_judge_response "expected 500 headers") );
      ( "h2_response_body_thunk_raise",
        run_h2c_probe ~env ~handler:handler_body_thunk_h2 ~deadline_sec:2.0
          ~judge:(h2_judge_with_rst "body thunk raise") );
      ( "h2_stream_read_raise_after_partial",
        run_h2c_probe ~env ~handler:handler_stream_partial_h2 ~deadline_sec:2.0
          ~judge:(h2_judge_with_rst "partial body then raise") );
      ( "h2_trailers_construction_raise",
        run_h2c_probe ~env ~handler:handler_trailers_h2 ~deadline_sec:2.0
          ~judge:(h2_judge_with_rst "trailers raise") );
      ( "h2_cancellation_during_response",
        run_h2c_probe ~env ~handler:handler_cancel_h2 ~deadline_sec:2.0
          ~judge:(h2_judge_with_rst "cancellation") );
    ]
  in
  List.iter
    (fun (name, run) ->
      let status, detail = run () in
      print_probe name status detail)
    probes
