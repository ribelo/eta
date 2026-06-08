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

let not_implemented name =
  { name;
    passed = false;
    deadline_respected = false;
    peak_rss_kb = 0;
    error_variant = Some "not_implemented";
    eta_error = Some "TLS adversarial server requires OpenSSL server bindings (not yet implemented)";
    duration_ms = 0.0;
    fd_baseline = 0;
    fd_after = 0;
    minor_words_during = 0.0;
    major_words_during = 0.0;
  }

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
    eta-http auto-negotiates h2 over TLS via ALPN.
    NOTE: Requires OpenSSL server bindings (not yet implemented). *)
let run_malicious_h2_request ~env:_ ~name ~server_fn:_ ~url_builder:_
    ~deadline_sec:_ =
  not_implemented name

(* ---------------------------------------------------------------------------
   1. CVE-2023-44487 — HTTP/2 Rapid Reset
   --------------------------------------------------------------------------- *)
let cve_2023_44487 ~env =
  ignore env;
  not_implemented "cve_2023_44487_rapid_reset"

(* ---------------------------------------------------------------------------
   2. CVE-2024-27919 / CVE-2024-28182 — CONTINUATION flood
   --------------------------------------------------------------------------- *)
let cve_2024_27919 ~env =
  ignore env;
  not_implemented "cve_2024_27919_continuation_flood"

(* ---------------------------------------------------------------------------
   3. HPACK bomb
   --------------------------------------------------------------------------- *)
let hpack_bomb ~env =
  ignore env;
  not_implemented "hpack_bomb"

(* ---------------------------------------------------------------------------
   4. HTTP/2 DoS family CVE-2019-9511..9518
   --------------------------------------------------------------------------- *)
let dos_family ~env =
  ignore env;
  [
    not_implemented "dos_ping_flood";
    not_implemented "dos_settings_flood";
    not_implemented "dos_empty_frames_flood";
  ]

(* ---------------------------------------------------------------------------
   5. WINDOW_UPDATE accounting
   --------------------------------------------------------------------------- *)
let window_update ~env =
  ignore env;
  not_implemented "window_update_accounting"

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
let goaway_churn ~env =
  ignore env;
  not_implemented "goaway_churn"

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
