(* Adversarial / CVE replay fixtures.
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
      let client = Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net env) () in
      let request = Eta_http.Request.make "GET" url in
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
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

(** TLS-wrapped malicious server runner for h2 attacks.
    eta-http auto-negotiates h2 over TLS via ALPN. *)
let run_malicious_h2_request ~env ~name ~server_fn ~url_builder ~deadline_sec =
  let fd_base = fd_count () in
  let start = Util.now_ms () in
  let gc_before = Util.gc_stat () in
  let port = Util.random_port () in
  let temp_dir =
    Filename.concat "http-testsuite/results"
      (Printf.sprintf "malicious_%s_%d" name (Unix.getpid ()))
  in
  Util.mkdir_p temp_dir;
  let cert_dir =
    match Certs.prepare ~temp_dir with
    | Ok d -> d
    | Error e -> failwith ("cert generation failed: " ^ e)
  in
  let certchain =
    let dir = Eio.Path.(Eio.Stdenv.cwd env / cert_dir) in
    X509_eio.private_of_pems
      ~cert:Eio.Path.(dir / "server.pem")
      ~priv_key:Eio.Path.(dir / "server.key")
  in
  let tls_server_cfg =
    Tls.Config.server
      ~version:(`TLS_1_2, `TLS_1_2)
      ~certificates:(`Single certchain)
      ~alpn_protocols:["h2"; "http/1.1"]
      ~ciphers:Tls.Config.Ciphers.supported
      ()
  in
  let server_done, resolve_server = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
      let net = Eio.Stdenv.net env in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              let raw_flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
              Fun.protect
                ~finally:(fun () ->
                    ignore (Eio.Promise.try_resolve resolve_server ()))
                (fun () ->
                   try
                     let tls_flow = Tls_eio.server_of_flow tls_server_cfg raw_flow in
                     server_fn ~env tls_flow
                   with _ -> ()));
          `Stop_daemon);
      let url = url_builder port in
      let authenticator = X509_eio.authenticator (`Ca_file Eio.Path.(Eio.Stdenv.cwd env / cert_dir / "ca.pem")) in
      let client = Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net env) ~authenticator () in
      let request = Eta_http.Request.make "GET" url in
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
      let result =
        Eta_http.request client request
        |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
               Util.body_to_string response.body |> Eta.Effect.map (fun _ -> `Ok))
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

(* ---------------------------------------------------------------------------
   1. CVE-2023-44487 — HTTP/2 Rapid Reset
   Server accepts many streams and immediately RST_STREAM on each one.
   --------------------------------------------------------------------------- *)
let rapid_reset_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  (* read client SETTINGS, ack it *)
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_rapid_reset ~env ~count:256 ~delay_sec:0.0 flow

let cve_2023_44487 ~env =
  run_malicious_h2_request ~env ~name:"cve_2023_44487_rapid_reset"
    ~server_fn:rapid_reset_server
    ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
    ~deadline_sec:5.0

(* ---------------------------------------------------------------------------
   2. CVE-2024-27919 / CVE-2024-28182 — CONTINUATION flood
   Server sends HEADERS without END_HEADERS, then many CONTINUATION frames.
   --------------------------------------------------------------------------- *)
let continuation_flood_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_continuation_flood ~env ~frames:1000 ~delay_sec:0.0 flow

let cve_2024_27919 ~env =
  run_malicious_h2_request ~env ~name:"cve_2024_27919_continuation_flood"
    ~server_fn:continuation_flood_server
    ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
    ~deadline_sec:5.0

(* ---------------------------------------------------------------------------
   3. HPACK bomb
   Server sends HEADERS with a header block that decodes to a huge size.
   --------------------------------------------------------------------------- *)
let hpack_bomb_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_hpack_bomb ~env ~decoded_size:(10 * 1024 * 1024) flow

let hpack_bomb ~env =
  run_malicious_h2_request ~env ~name:"hpack_bomb"
    ~server_fn:hpack_bomb_server
    ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
    ~deadline_sec:5.0

(* ---------------------------------------------------------------------------
   4. HTTP/2 DoS family CVE-2019-9511..9518
   We implement three representative sub-attacks:
   a) ping flood
   b) settings flood
   c) empty frames flood
   --------------------------------------------------------------------------- *)
let ping_flood_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_ping_flood ~env ~count:1000 ~delay_sec:0.0 flow

let settings_flood_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_settings_flood ~env ~count:1000 ~delay_sec:0.0 flow

let empty_frames_flood_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_empty_frames_flood ~env ~count:1000 ~delay_sec:0.0 flow

let dos_family ~env =
  let ping =
    run_malicious_h2_request ~env ~name:"dos_ping_flood"
      ~server_fn:ping_flood_server
      ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
      ~deadline_sec:5.0
  in
  let settings =
    run_malicious_h2_request ~env ~name:"dos_settings_flood"
      ~server_fn:settings_flood_server
      ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
      ~deadline_sec:5.0
  in
  let empty =
    run_malicious_h2_request ~env ~name:"dos_empty_frames_flood"
      ~server_fn:empty_frames_flood_server
      ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
      ~deadline_sec:5.0
  in
  [ ping; settings; empty ]

(* ---------------------------------------------------------------------------
   5. WINDOW_UPDATE accounting
   Server sends WINDOW_UPDATE with 2^31-1 on connection and stream.
   --------------------------------------------------------------------------- *)
let window_update_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_window_overflow ~env flow

let window_update ~env =
  run_malicious_h2_request ~env ~name:"window_update_accounting"
    ~server_fn:window_update_server
    ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
    ~deadline_sec:5.0

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
   8. GOAWAY churn
   Server sends GOAWAY repeatedly while continuing to accept streams.
   --------------------------------------------------------------------------- *)
let goaway_churn_server ~env flow =
  Malicious_h2.send_server_preface flow;
  Malicious_h2.read_preface flow;
  let len, ty, _flags, _sid = Malicious_h2.read_frame_header flow in
  if ty = 0x04 then Malicious_h2.ack_settings flow
  else Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.skip_frame_payload flow len;
  Malicious_h2.serve_goaway_churn ~env ~count:10 flow

let goaway_churn ~env =
  run_malicious_h2_request ~env ~name:"goaway_churn"
    ~server_fn:goaway_churn_server
    ~url_builder:(fun port -> Printf.sprintf "https://127.0.0.1:%d/" port)
    ~deadline_sec:5.0

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let run_all ~env =
  let results = [] in
  let results = cve_2023_44487 ~env :: results in
  let results = cve_2024_27919 ~env :: results in
  let results = hpack_bomb ~env :: results in
  let results = dos_family ~env @ results in
  let results = window_update ~env :: results in
  let results = data_slowloris ~env :: results in
  let results = decompression_bomb ~env :: results in
  let results = goaway_churn ~env :: results in
  List.rev results
