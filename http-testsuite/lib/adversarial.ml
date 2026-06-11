(** Adversarial / CVE replay fixtures.
   Each fixture is an in-process malicious server.
   Acceptance: eta-http returns a typed error within a deadline, and resource
   bounds are respected. *)

open Types
open Eio.Std

let rss_kb = Util.rss_kb
let fd_count = Util.fd_count
let minor_words (x, _, _, _) = x
let major_words (_, x, _, _) = x

let timeout_error ~url ~deadline_sec =
  let timeout_ms = max 1 (int_of_float (deadline_sec *. 1000.0)) in
  Eta_http.Error.make ~method_:"GET" ~uri:url
    (Total_request_timeout { timeout_ms = Some timeout_ms })

let cve_scenario_filter =
  lazy
    (match Sys.getenv_opt "ETA_HTTP_TESTSUITE_CVE_SCENARIOS" with
    | None | Some "" -> None
    | Some raw ->
        Some
          (raw |> String.split_on_char ','
          |> List.map String.trim
          |> List.filter (fun item -> not (String.equal item ""))))

let cve_scenario_selected name =
  match Lazy.force cve_scenario_filter with
  | None -> true
  | Some names -> List.exists (String.equal name) names

let add_cve_result name run results =
  if cve_scenario_selected name then run () :: results else results

(** Generic runner: spawns a malicious server, makes one eta-http request,
    and records metrics. *)
let run_malicious_request ?consume_response ~env ~name ~server_fn ~url_builder
    ~deadline_sec () =
  let fd_base = fd_count () in
  let start = Util.now_ms () in
  let gc_before = Util.gc_stat () in
  let port = Util.random_port () in
  let server_done, resolve_server = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
      let net = Eio.Stdenv.net env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
              Fun.protect
                ~finally:(fun () ->
                    try Eio.Flow.shutdown flow `All with _ -> ();
                    ignore (Eio.Promise.try_resolve resolve_server ()))
                (fun () -> try server_fn ~env flow with _ -> ()));
          `Stop_daemon);
      let url = url_builder port in
      let client = Eta_http_eio.Client.make ~sw ~net:(Eio.Stdenv.net env) () in
      let request = Eta_http.Request.make "GET" url in
      let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
      let consume_response =
        match consume_response with
        | Some consume -> consume
        | None ->
            fun (response : Eta_http.Response.t) ->
              Util.body_to_string response.body |> Eta.Effect.map (fun _ -> `Ok)
      in
      let result =
        Eta_http.request client request
        |> Eta.Effect.bind consume_response
        |> Eta.Effect.timeout_as
             (Eta.Duration.ms (max 1 (int_of_float (deadline_sec *. 1000.0))))
             ~on_timeout:(timeout_error ~url ~deadline_sec)
        |> Eta.Runtime.run rt
        |> function
        | Eta.Exit.Ok `Ok -> `Completed
        | Eta.Exit.Error cause ->
            let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
            `Error msg
      in
      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
      let duration_ms = Util.now_ms () -. start in
      let peak_rss = rss_kb () in
      let fd_after = fd_count () in
      let gc_after = Util.gc_stat () in
      ignore (Eio.Promise.try_resolve resolve_server ());
      let error_variant, eta_error =
        match result with
        | `Timeout -> Some "total_request_timeout", Some "deadline exceeded"
        | `Error e -> Some "connection_closed", Some e
        | `Completed -> None, None
      in
      { name;
        passed = (result <> `Completed);
        skipped = None;
        deadline_respected = (result <> `Completed);
        peak_rss_kb = peak_rss;
        error_variant;
        eta_error;
        duration_ms;
        fd_baseline = fd_base;
        fd_after;
        minor_words_during = minor_words gc_after -. minor_words gc_before;
        major_words_during = major_words gc_after -. major_words gc_before;
      })

(** Server-side runner: starts an Eta H1 server and drives it with a raw
    malicious client. *)
let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected TCP listener"

let read_h1_response ?(max_bytes = 64 * 1024) flow =
  let buffer = Buffer.create 256 in
  let scratch = Cstruct.create 1024 in
  let rec loop total =
    if total >= max_bytes then Buffer.contents buffer
    else
      let len = min (Cstruct.length scratch) (max_bytes - total) in
      match Eio.Flow.single_read flow (Cstruct.sub scratch 0 len) with
      | 0 -> Buffer.contents buffer
      | read ->
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub scratch 0 read));
          loop (total + read)
      | exception End_of_file -> Buffer.contents buffer
  in
  loop 0

let h1_status response =
  if
    String.length response >= 12
    && String.starts_with ~prefix:"HTTP/1.1 " response
  then
    try Some (int_of_string (String.sub response 9 3)) with
    | Failure _ -> None
  else None

let h1_status_line response =
  match String.index_opt response '\r' with
  | Some index -> String.sub response 0 index
  | None -> response

let h1_adversarial_config ?request_header_timeout ?request_body_timeout
    ?max_request_header_bytes ?max_trailer_bytes () =
  let limits =
    {
      Eta_http.Server.Config.default.limits with
      max_request_header_bytes =
        Option.value max_request_header_bytes
          ~default:
            Eta_http.Server.Config.default.limits.max_request_header_bytes;
      max_trailer_bytes =
        Option.value max_trailer_bytes
          ~default:Eta_http.Server.Config.default.limits.max_trailer_bytes;
    }
  in
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_header_timeout =
        Option.value request_header_timeout
          ~default:
            Eta_http.Server.Config.default.timeouts.request_header_timeout;
      request_body_timeout =
        Option.value request_body_timeout
          ~default:Eta_http.Server.Config.default.timeouts.request_body_timeout;
    }
  in
  let server = { Eta_http.Server.Config.default with limits; timeouts } in
  {
    Eta_http_eio.Server.Config.default with
    backlog = 1;
    max_connections = 8;
    server;
  }

let h1_body_draining_handler request =
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun body ->
         Eta_http.Server.Response.make ~status:200
           ~body:(Eta_http.Server.Response.Body.fixed [ body ])
           ())

let run_eta_h1_adversarial_client ~env ~name ?config ~expected_status
    ~deadline_sec client_fn =
  let fd_base = fd_count () in
  let start = Util.now_ms () in
  let gc_before = Util.gc_stat () in
  let result =
    try
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port = tcp_port (Eio.Net.listening_addr socket) in
      let config =
        Option.value config ~default:(h1_adversarial_config ())
      in
      let server =
        Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket
          h1_body_draining_handler
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
                  client_fn ~clock flow)
            in
            `Response response
          with
          | Eio.Time.Timeout -> `Timeout
          | exn -> `Error (Printexc.to_string exn))
    with exn -> `Error (Printexc.to_string exn)
  in
  let duration_ms = Util.now_ms () -. start in
  let peak_rss = rss_kb () in
  let fd_after = fd_count () in
  let gc_after = Util.gc_stat () in
  let passed, deadline_respected, error_variant, eta_error =
    match result with
    | `Response response -> (
        match h1_status response with
        | Some status ->
            ( status = expected_status,
              true,
              Some (Printf.sprintf "h1_status_%d" status),
              Some (h1_status_line response) )
        | None ->
            ( false,
              true,
              Some "h1_malformed_response",
              Some (h1_status_line response) ))
    | `Timeout -> (false, false, Some "deadline_exceeded", Some "timeout")
    | `Error message -> (false, true, Some "exception", Some message)
  in
  {
    name;
    passed;
    skipped = None;
    deadline_respected;
    peak_rss_kb = peak_rss;
    error_variant;
    eta_error;
    duration_ms;
    fd_baseline = fd_base;
    fd_after;
    minor_words_during = minor_words gc_after -. minor_words gc_before;
    major_words_during = major_words gc_after -. major_words gc_before;
  }

let h2_client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let h2_request_block ?(method_ = "GET") ?(path = "/") () =
  String.concat ""
    [
      Malicious_h2.hpack_literal ~name:":method" ~value:method_;
      Malicious_h2.hpack_literal ~name:":scheme" ~value:"http";
      Malicious_h2.hpack_literal ~name:":path" ~value:path;
      Malicious_h2.hpack_literal ~name:":authority" ~value:"example.test";
    ]

let h2_request_headers ?(end_headers = true) ?(end_stream = true) ~stream_id
    ?method_ ?path () =
  let flags =
    (if end_headers then 0x04 else 0x00)
    lor (if end_stream then 0x01 else 0x00)
  in
  Malicious_h2.frame ~ty:0x01 ~flags ~stream_id
    (h2_request_block ?method_ ?path ())

let h2_frame_header ~length ~ty ~flags ~stream_id =
  Eta_http.H2.Frame.header ~length ~frame_type:(Other ty) ~flags ~stream_id

let h2_adversarial_config ?request_header_timeout ?request_body_timeout
    ?idle_timeout ?unread_body_policy ?security_config () =
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      request_header_timeout =
        Option.value request_header_timeout
          ~default:
            Eta_http.Server.Config.default.timeouts.request_header_timeout;
      request_body_timeout =
        Option.value request_body_timeout
          ~default:Eta_http.Server.Config.default.timeouts.request_body_timeout;
      idle_timeout =
        Option.value idle_timeout
          ~default:Eta_http.Server.Config.default.timeouts.idle_timeout;
    }
  in
  let server =
    {
      Eta_http.Server.Config.default with
      timeouts;
      unread_body_policy =
        Option.value unread_body_policy
          ~default:Eta_http.Server.Config.default.unread_body_policy;
    }
  in
  {
    Eta_http_eio.Server.Config.default with
    backlog = 1;
    max_connections = 8;
    server;
    h2_security_config = security_config;
  }

let h2_basic_handler _request =
  Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")

let read_h2_until_close ?(max_bytes = 64 * 1024) flow =
  let buffer = Buffer.create 256 in
  let scratch = Cstruct.create 1024 in
  let rec loop total =
    if total >= max_bytes then `Data_limit (Buffer.contents buffer)
    else
      let len = min (Cstruct.length scratch) (max_bytes - total) in
      match Eio.Flow.single_read flow (Cstruct.sub scratch 0 len) with
      | 0 -> `Closed (Buffer.contents buffer)
      | read ->
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub scratch 0 read));
          loop (total + read)
      | exception End_of_file -> `Closed (Buffer.contents buffer)
  in
  loop 0

let run_eta_h2c_adversarial_client ~env ~name ?config ~deadline_sec client_fn =
  let fd_base = fd_count () in
  let start = Util.now_ms () in
  let gc_before = Util.gc_stat () in
  let result =
    try
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port = tcp_port (Eio.Net.listening_addr socket) in
      let config =
        Option.value config ~default:(h2_adversarial_config ())
      in
      Eio.Fiber.fork_daemon ~sw
        (fun () ->
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
        Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Fun.protect
        ~finally:(fun () ->
          try Eio.Flow.shutdown flow `All with _ -> ())
        (fun () ->
          try
            Eio.Time.with_timeout_exn clock deadline_sec (fun () ->
                match (try client_fn flow; Ok () with exn -> Error exn) with
                | Ok () -> read_h2_until_close flow
                | Error _ -> `Closed "")
          with
          | Eio.Time.Timeout -> `Timeout
          | exn -> `Error (Printexc.to_string exn))
    with exn -> `Error (Printexc.to_string exn)
  in
  let duration_ms = Util.now_ms () -. start in
  let peak_rss = rss_kb () in
  let fd_after = fd_count () in
  let gc_after = Util.gc_stat () in
  let passed, deadline_respected, error_variant, eta_error =
    match result with
    | `Closed response ->
        (true, true, Some "h2_connection_closed", Some (string_of_int (String.length response)))
    | `Data_limit response ->
        ( false,
          true,
          Some "h2_data_limit",
          Some (string_of_int (String.length response)) )
    | `Timeout -> (false, false, Some "deadline_exceeded", Some "timeout")
    | `Error message -> (false, true, Some "exception", Some message)
  in
  {
    name;
    passed;
    skipped = None;
    deadline_respected;
    peak_rss_kb = peak_rss;
    error_variant;
    eta_error;
    duration_ms;
    fd_baseline = fd_base;
    fd_after;
    minor_words_during = minor_words gc_after -. minor_words gc_before;
    major_words_during = major_words gc_after -. major_words gc_before;
  }

(* ---------------------------------------------------------------------------
   1. CVE-2023-44487 — HTTP/2 Rapid Reset
   --------------------------------------------------------------------------- *)
let cve_2023_44487 ~env =
  run_eta_h2c_adversarial_client ~env ~name:"cve_2023_44487_rapid_reset"
    ~deadline_sec:2.0
    (fun flow ->
      let frames =
        String.concat ""
          (List.init 101 (fun index ->
               let stream_id = (index * 2) + 1 in
               h2_request_headers ~end_stream:false ~stream_id ()
               ^ Malicious_h2.rst_stream_frame ~stream_id 8))
      in
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame [] ^ frames)
        flow)

(* ---------------------------------------------------------------------------
   2. CVE-2024-27919 / CVE-2024-28182 — CONTINUATION flood
   --------------------------------------------------------------------------- *)
let cve_2024_27919 ~env =
  run_eta_h2c_adversarial_client ~env
    ~name:"cve_2024_27919_continuation_flood" ~deadline_sec:2.0
    (fun flow ->
      let continuations =
        String.concat ""
          (List.init 9 (fun _ ->
               Malicious_h2.continuation_frame ~end_headers:false ~stream_id:1
                 (String.make 8192 'x')))
      in
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ h2_request_headers ~end_headers:false ~stream_id:1 ()
       ^ continuations)
        flow)

(* ---------------------------------------------------------------------------
   3. HPACK bomb
   --------------------------------------------------------------------------- *)
let hpack_bomb ~env =
  run_eta_h2c_adversarial_client ~env ~name:"hpack_bomb" ~deadline_sec:2.0
    (fun flow ->
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ h2_frame_header ~length:(300 * 1024) ~ty:0x01 ~flags:0x04
           ~stream_id:1)
        flow)

(* ---------------------------------------------------------------------------
   4. HTTP/2 DoS family CVE-2019-9511..9518
   --------------------------------------------------------------------------- *)
let dos_family ~env =
  [
    run_eta_h2c_adversarial_client ~env ~name:"dos_ping_flood"
      ~deadline_sec:2.0
      (fun flow ->
        Eio.Flow.copy_string
          (h2_client_preface ^ Malicious_h2.settings_frame []
         ^ String.concat ""
             (List.init 101 (fun _ ->
                  Malicious_h2.ping_frame ~ack:false "pingflood")))
          flow);
    run_eta_h2c_adversarial_client ~env ~name:"dos_settings_flood"
      ~deadline_sec:2.0
      (fun flow ->
        Eio.Flow.copy_string
          (h2_client_preface ^ Malicious_h2.settings_frame []
         ^ String.concat ""
             (List.init 10 (fun _ ->
                  Malicious_h2.settings_frame [ (0x3, 100); (0x4, 65535) ])))
          flow);
    run_eta_h2c_adversarial_client ~env ~name:"dos_empty_frames_flood"
      ~deadline_sec:2.0
      (fun flow ->
        Eio.Flow.copy_string
          (h2_client_preface ^ Malicious_h2.settings_frame []
         ^ h2_request_headers ~end_stream:false ~stream_id:1 ()
         ^ String.concat ""
             (List.init 101 (fun _ ->
                  Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "")))
          flow);
  ]

(* ---------------------------------------------------------------------------
   5. WINDOW_UPDATE accounting
   --------------------------------------------------------------------------- *)
let window_update ~env =
  let security_config =
    {
      Eta_http.H2.Security.default_config with
      max_window_update_per_connection = 2;
    }
  in
  run_eta_h2c_adversarial_client ~env ~name:"window_update_accounting"
    ~config:(h2_adversarial_config ~security_config ()) ~deadline_sec:2.0
    (fun flow ->
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ String.concat ""
           (List.init 3 (fun _ ->
                Malicious_h2.window_update_frame ~stream_id:0 1)))
        flow)

(* ---------------------------------------------------------------------------
   6. DATA slowloris (h1)
   Server sends 1 byte every few seconds indefinitely.
   --------------------------------------------------------------------------- *)
let slowloris_h1_server ~env ~delay_sec flow =
  let buf = Cstruct.create 4096 in
  (try
     let n = Eio.Flow.single_read flow buf in
     ignore (Cstruct.to_string (Cstruct.sub buf 0 n))
   with _ -> ());
  let header = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n" in
  Eio.Flow.copy_string header flow;
  for _i = 1 to 100 do
    try
      Eio.Flow.copy_string "x" flow;
      Eio.Time.sleep (Eio.Stdenv.clock env) delay_sec
    with _ -> ()
  done

let data_slowloris ~env =
  run_malicious_request ~env ~name:"data_slowloris_h1"
    ~server_fn:(fun ~env flow -> slowloris_h1_server ~env ~delay_sec:5.0 flow)
    ~url_builder:(fun port -> Printf.sprintf "http://127.0.0.1:%d/" port)
    ~deadline_sec:3.0 ()

(* ---------------------------------------------------------------------------
   7. Decompression bomb
   Server serves a gzip-encoded body that expands to many MB.
   --------------------------------------------------------------------------- *)
let decompression_bomb_server ~env flow =
  let temp_dir = Filename.concat (Filename.get_temp_dir_name ()) "decomp_bomb" in
  Util.mkdir_p temp_dir;
  let bomb_path = Filename.concat temp_dir "bomb.gz" in
  Malicious_h2.generate_gzip_bomb ~path:bomb_path ~expanded_bytes:(50 * 1024 * 1024);
  let buf = Cstruct.create 4096 in
  (try
     let n = Eio.Flow.single_read flow buf in
     ignore (Cstruct.to_string (Cstruct.sub buf 0 n))
   with _ -> ());
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\n\r\n"
  in
  Eio.Flow.copy_string header flow;
  let ic = open_in_bin bomb_path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let chunk = Bytes.create 65536 in
       let rec loop () =
         match input ic chunk 0 (Bytes.length chunk) with
         | 0 -> ()
         | n ->
             Eio.Flow.copy_string (Bytes.sub_string chunk 0 n) flow;
             loop ()
       in
       loop ())

let decompression_bomb ~env =
  run_malicious_request ~env ~name:"decompression_bomb"
    ~server_fn:decompression_bomb_server
    ~url_builder:(fun port -> Printf.sprintf "http://127.0.0.1:%d/" port)
    ~consume_response:(fun (response : Eta_http.Response.t) ->
      let decoded =
        Eta_http.Body.Transducer.gzip_decode ~max_decoded_bytes:(1024 * 1024)
          response.body
      in
      Eta_http.Body.Stream.read_all decoded |> Eta.Effect.map (fun _ -> `Ok))
    ~deadline_sec:10.0 ()

(* ---------------------------------------------------------------------------
   8. H1 server adversarial clients
   --------------------------------------------------------------------------- *)
let h1_slowloris_headers ~env =
  let config =
    h1_adversarial_config
      ~request_header_timeout:(Some (Eta.Duration.ms 50))
      ()
  in
  run_eta_h1_adversarial_client ~env ~name:"h1_slowloris_headers" ~config
    ~expected_status:408 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        "GET / HTTP/1.1\r\nHost: example.test\r\nX-Slow: " flow;
      read_h1_response flow)

let h1_slow_body ~env =
  let config =
    h1_adversarial_config
      ~request_body_timeout:(Some (Eta.Duration.ms 50))
      ()
  in
  run_eta_h1_adversarial_client ~env ~name:"h1_slow_body" ~config
    ~expected_status:408 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Connection: close\r\nContent-Length: 5\r\n\r\nhe")
        flow;
      read_h1_response flow)

let h1_invalid_chunk ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_invalid_chunk"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
       ^ "z\r\nboom\r\n")
        flow;
      read_h1_response flow)

let h1_cl_te_smuggling ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_cl_te_smuggling"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Connection: keep-alive\r\nContent-Length: 4\r\n"
       ^ "Transfer-Encoding: chunked\r\n\r\n"
       ^ "0\r\n\r\nGET /healthz HTTP/1.1\r\nHost: example.test\r\n\r\n")
        flow;
      read_h1_response flow)

let h1_missing_host ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_missing_host"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string "GET / HTTP/1.1\r\nConnection: close\r\n\r\n" flow;
      read_h1_response flow)

let h1_duplicate_host ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_duplicate_host"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("GET / HTTP/1.1\r\nHost: example.test\r\nHost: shadow.test\r\n"
       ^ "Connection: close\r\n\r\n")
        flow;
      read_h1_response flow)

let h1_invalid_host ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_invalid_host"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        "GET / HTTP/1.1\r\nHost: bad/name\r\nConnection: close\r\n\r\n"
        flow;
      read_h1_response flow)

let h1_invalid_request_target ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_invalid_request_target"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        "GET noslash HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
        flow;
      read_h1_response flow)

let h1_absolute_form_host_conflict ~env =
  run_eta_h1_adversarial_client ~env ~name:"h1_absolute_form_host_conflict"
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("GET http://example.test/conflict HTTP/1.1\r\n"
       ^ "Host: shadow.test\r\nConnection: close\r\n\r\n")
        flow;
      read_h1_response flow)

let h1_header_flood ~env =
  let config = h1_adversarial_config ~max_request_header_bytes:64 () in
  let flood = String.make 256 'x' in
  run_eta_h1_adversarial_client ~env ~name:"h1_header_flood" ~config
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("GET / HTTP/1.1\r\nHost: example.test\r\nX-Flood: " ^ flood
       ^ "\r\n\r\n")
        flow;
      read_h1_response flow)

let h1_oversized_trailers ~env =
  let config = h1_adversarial_config ~max_trailer_bytes:8 () in
  run_eta_h1_adversarial_client ~env ~name:"h1_oversized_trailers" ~config
    ~expected_status:400 ~deadline_sec:1.0
    (fun ~clock:_ flow ->
      Eio.Flow.copy_string
        ("POST /echo HTTP/1.1\r\nHost: example.test\r\n"
       ^ "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
       ^ "0\r\nX-Too-Large: value\r\n\r\n")
        flow;
      read_h1_response flow)

let h2_slow_preface_timeout ~env =
  let config =
    h2_adversarial_config
      ~request_header_timeout:(Some (Eta.Duration.ms 50))
      ()
  in
  run_eta_h2c_adversarial_client ~env ~name:"h2_slow_preface_timeout"
    ~config ~deadline_sec:1.0
    (fun flow -> Eio.Flow.copy_string "PRI * " flow)

let h2_slow_headers_timeout ~env =
  let config =
    h2_adversarial_config
      ~request_header_timeout:(Some (Eta.Duration.ms 50))
      ()
  in
  run_eta_h2c_adversarial_client ~env ~name:"h2_slow_headers_timeout"
    ~config ~deadline_sec:1.0
    (fun flow ->
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ h2_frame_header ~length:64 ~ty:0x01 ~flags:0x04 ~stream_id:1)
        flow)

let h2_slow_body_timeout ~env =
  let config =
    h2_adversarial_config
      ~request_body_timeout:(Some (Eta.Duration.ms 50))
      ~idle_timeout:(Some (Eta.Duration.ms 50))
      ~unread_body_policy:(Eta_http.Server.Config.Drain_up_to 64)
      ()
  in
  run_eta_h2c_adversarial_client ~env ~name:"h2_slow_body_timeout" ~config
    ~deadline_sec:1.0
    (fun flow ->
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ h2_request_headers ~method_:"POST" ~end_stream:false ~stream_id:1 ()
       ^ Malicious_h2.data_frame ~end_stream:false ~stream_id:1 "he")
        flow)

(* ---------------------------------------------------------------------------
   8. GOAWAY churn
   Server sends GOAWAY repeatedly while continuing to accept streams.
   --------------------------------------------------------------------------- *)
let goaway_churn ~env =
  run_eta_h2c_adversarial_client ~env ~name:"goaway_churn" ~deadline_sec:2.0
    (fun flow ->
      Eio.Flow.copy_string
        (h2_client_preface ^ Malicious_h2.settings_frame []
       ^ Malicious_h2.goaway_frame ~last_stream_id:0 ~error_code:0 ()
       ^ Malicious_h2.goaway_frame ~last_stream_id:0 ~error_code:0 ())
        flow)

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let run_all ~env =
  let results = [] in
  let results =
    add_cve_result "cve_2023_44487_rapid_reset"
      (fun () -> cve_2023_44487 ~env)
      results
  in
  let results =
    add_cve_result "cve_2024_27919_continuation_flood"
      (fun () -> cve_2024_27919 ~env)
      results
  in
  let results =
    add_cve_result "hpack_bomb" (fun () -> hpack_bomb ~env) results
  in
  let dos_names =
    [ "dos_ping_flood"; "dos_settings_flood"; "dos_empty_frames_flood" ]
  in
  let dos_results =
    if List.exists cve_scenario_selected dos_names then
      dos_family ~env
      |> List.filter (fun (result : adversarial_result) ->
             cve_scenario_selected result.name)
    else []
  in
  let results = dos_results @ results in
  let results =
    add_cve_result "window_update_accounting"
      (fun () -> window_update ~env)
      results
  in
  let results =
    add_cve_result "data_slowloris_h1"
      (fun () -> data_slowloris ~env)
      results
  in
  let results =
    add_cve_result "decompression_bomb"
      (fun () -> decompression_bomb ~env)
      results
  in
  let results =
    add_cve_result "h1_slowloris_headers"
      (fun () -> h1_slowloris_headers ~env)
      results
  in
  let results =
    add_cve_result "h1_slow_body" (fun () -> h1_slow_body ~env) results
  in
  let results =
    add_cve_result "h1_invalid_chunk"
      (fun () -> h1_invalid_chunk ~env)
      results
  in
  let results =
    add_cve_result "h1_cl_te_smuggling"
      (fun () -> h1_cl_te_smuggling ~env)
      results
  in
  let results =
    add_cve_result "h1_missing_host" (fun () -> h1_missing_host ~env) results
  in
  let results =
    add_cve_result "h1_duplicate_host"
      (fun () -> h1_duplicate_host ~env)
      results
  in
  let results =
    add_cve_result "h1_invalid_host" (fun () -> h1_invalid_host ~env) results
  in
  let results =
    add_cve_result "h1_invalid_request_target"
      (fun () -> h1_invalid_request_target ~env)
      results
  in
  let results =
    add_cve_result "h1_absolute_form_host_conflict"
      (fun () -> h1_absolute_form_host_conflict ~env)
      results
  in
  let results =
    add_cve_result "h1_header_flood" (fun () -> h1_header_flood ~env) results
  in
  let results =
    add_cve_result "h1_oversized_trailers"
      (fun () -> h1_oversized_trailers ~env)
      results
  in
  let results =
    add_cve_result "h2_slow_preface_timeout"
      (fun () -> h2_slow_preface_timeout ~env)
      results
  in
  let results =
    add_cve_result "h2_slow_headers_timeout"
      (fun () -> h2_slow_headers_timeout ~env)
      results
  in
  let results =
    add_cve_result "h2_slow_body_timeout"
      (fun () -> h2_slow_body_timeout ~env)
      results
  in
  let results =
    add_cve_result "goaway_churn" (fun () -> goaway_churn ~env) results
  in
  List.rev results
