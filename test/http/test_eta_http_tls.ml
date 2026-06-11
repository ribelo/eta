open Test_eta_http_support

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let contains haystack needle =
  match find_sub haystack ~needle with
  | Some _ -> true
  | None -> false

let tls_cert =
  {|-----BEGIN CERTIFICATE-----
MIIDITCCAgmgAwIBAgIUWxU09v58bOJEdBMtBjtQHC0VdVwwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDYxMTE0NTczOFoYDzIxMjYw
NTE4MTQ1NzM4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQC6YoCjrrYAmpWlnZ/GQ9BZqg7P5fVgZoxGn+e/OVP+
J7OheQXad8rsW58cFHa0je+awg3KyImCrvIW1ZDeeiiGducnerkJB+5AcHdMD+Do
+ftYUL2wh+Q4CHvSKf3ahOrWPpXbItp8nekOprXYb0MMWSJ32rMO8/sSEcfzEiQT
89nNDC83eH7Ey622q+Vel63cn5qKcWNc0R9c3/k+7gz39vjIMF3cCJt/WTZasi/q
tyLNwavN1mV8qhM04TMYl0xYGFNV3hNVutGufMhtRabApkLlkx9OgQZUCCNt/2EX
jmxpaMH11mxnXmgp/16TE32qfHWRu9tCEPY/S8Hpf0iHAgMBAAGjaTBnMB0GA1Ud
DgQWBBQVosW39l8YvdPuhLDgWG+ZSXP6+zAfBgNVHSMEGDAWgBQVosW39l8YvdPu
hLDgWG+ZSXP6+zAUBgNVHREEDTALgglsb2NhbGhvc3QwDwYDVR0TAQH/BAUwAwEB
/zANBgkqhkiG9w0BAQsFAAOCAQEAoG/5dz3wosYf0xKi3rTZw2O1ZJKw+7Xbhbfe
aicDH9yKfH+5FMgHzMWZtkWMyJk89qT/ZOjC8EF/gAsx+c6nmudUps+3SiqMScIp
pmNhtviZONOIvThtJvWuy+EU8DohSAF0oTP/Hk6FiXgqk+pfQ0vsL+CuYyTA5xIA
k/PzvyeEeYkASYcZLOsYRbfXc/ec4l0hsKBXhC8GLaUXik/KS00t26zrsXZH+Wqd
R3TZ4mQgLBDPVxXR9ZbhUOgzkLylhMLfbVKvMrQOUfP6o48nrPfRmmTs8oGz68Z8
7vFC9UrLy5fhJhYWRbcmvN4u4WNyYpYeJzf9A49TTSSsN9Jf3g==
-----END CERTIFICATE-----
|}

let tls_key =
  {|-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC6YoCjrrYAmpWl
nZ/GQ9BZqg7P5fVgZoxGn+e/OVP+J7OheQXad8rsW58cFHa0je+awg3KyImCrvIW
1ZDeeiiGducnerkJB+5AcHdMD+Do+ftYUL2wh+Q4CHvSKf3ahOrWPpXbItp8nekO
prXYb0MMWSJ32rMO8/sSEcfzEiQT89nNDC83eH7Ey622q+Vel63cn5qKcWNc0R9c
3/k+7gz39vjIMF3cCJt/WTZasi/qtyLNwavN1mV8qhM04TMYl0xYGFNV3hNVutGu
fMhtRabApkLlkx9OgQZUCCNt/2EXjmxpaMH11mxnXmgp/16TE32qfHWRu9tCEPY/
S8Hpf0iHAgMBAAECggEAHyJgMbd4EJ7B+7HaZDCkx62YHtNfi1Rl/1Ar0q4dYTm5
kHIab7WOELB3YiXq9Fs3WKcszaB1E/7sUrMnKXrHdTq8f0RJT4BjJKGE1BBc9h34
Bfcq0KfKkC+em2tHS+7jGZnHx5zJWYK5USi4/KgNT60+DD5cpdVMreaJe4mevDQ4
zzILJdn0G4z2ZzQU13ENU5D7J8nb3UyJIcyGOKjlJSGQVMnyXcOUvg+4FsyoCmMy
7/3cb166KyN5bcLCD3bx4B6Y6A+KTH9bLKcAblYuhnxdhMuzHUz/g8jEHEKpMtQZ
QiRh/+zXf3NfxOjBcHhkHKxNRVWoDthLREUEYQe8xQKBgQD0fmaMX2+OpBw+tt2/
wtcmWhbB24H4382+5HU6zlU/hufLFVa9sGhNcOmgYEmsm2e6yPACRWIWIyg+jart
okDJCcZ9pBom7tb8k754DeUaT9tfgt4A9sjzresgRE0N2iJWIrSfZGsrPakohYpZ
WOCOuLSlIlWcI3SA+arsvyusPQKBgQDDKAUAR0iUVRaDSAE3nSJc9ZcJGCQY6Ixj
I9sF99xgSG+R0nWPexNhCogW0E+Kza9qMGl/mXluI2R4Vogb5zDMN39IFjzD6TsK
ULjXDvSuDTl++y4QfMfTlh+iRO7YQxAFVx28QR7xCpYhb1bJu3i11qIhtEeXmxnj
mQiV4t+AEwKBgQCbejYkVhxPDTWY/BkP9Qt0rB2Esd55MXlZR1b1SnkTqOqGTs+W
WTQ66u7mudSgG0NfmKBoEU9K3JifDt//tgqUzc6X319yGrhEbn/VQKDMlrPejQ44
drdbnuHC5yxI/sqPFArgwa8VFGUaC7HrF4XVvMfDq43deP6BdkOnwfo30QKBgFJf
/xRqAmHSNKl/aDwgUJPqejE1hm8ZIcDrLpUrVVMy4B0uN78zlS998YmnrhuJzIRH
IRDiKFZsDAmbhOI6SOe6eThlYorTVL966TqlrnQVUvKddYkyEmrmUD3/WM3iKM4I
Qp3m4vedn1dHltuaDU675T3SyfFdX6UpQG18ERkPAoGBALgA9HwmdbNln/bmZEzX
XDLp6/6Djkq3GeU5L3r/86qRm884FQpkNL714Gt9j6UO0uH2SJRQVTloagkHlCb9
5VTlcp9DipKkX4Kel26jB/CD6g4zu1fQb4BN+x5pHXG5jDVhVhwJpONS51nIuIG9
hwMSF/Svo8L7E5Iw+/BBhFx6
-----END PRIVATE KEY-----
|}

let remove_noerr path =
  try Sys.remove path with
  | Sys_error _ -> ()

let write_temp_file prefix contents =
  let path = Filename.temp_file prefix ".pem" in
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents);
  path

let with_temp_file prefix contents f =
  let path = write_temp_file prefix contents in
  Fun.protect ~finally:(fun () -> remove_noerr path) (fun () -> f path)

let with_temp_tls_files f =
  with_temp_file "eta-http-cert" tls_cert @@ fun cert ->
  with_temp_file "eta-http-key" tls_key @@ fun key -> f cert key

let with_generated_tls_files host f =
  let cert = Filename.temp_file "eta-http-generated-cert" ".pem" in
  let key = Filename.temp_file "eta-http-generated-key" ".pem" in
  let cmd =
    String.concat " "
      [
        "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1";
        "-subj";
        Filename.quote ("/CN=" ^ host);
        "-addext";
        Filename.quote ("subjectAltName=DNS:" ^ host);
        "-keyout";
        Filename.quote key;
        "-out";
        Filename.quote cert;
        ">/dev/null 2>&1";
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      remove_noerr cert;
      remove_noerr key)
    (fun () ->
      if Sys.command cmd <> 0 then
        Alcotest.failf "failed to generate TLS certificate for %s" host;
      f cert key)

let with_temp_ca_bundle certs f =
  let contents = certs |> List.map read_file |> String.concat "" in
  with_temp_file "eta-http-ca-bundle" contents f

let pump_tls src dst =
  let pending = Eta_http__Openssl.bio_write_pending src in
  if pending = 0 then 0
  else
    let scratch = Cstruct.create pending in
    let buffer = Cstruct.to_bigarray scratch in
    let read = Eta_http__Openssl.bio_read src buffer 0 pending in
    if read = 0 then 0
    else
      let written = Eta_http__Openssl.bio_write dst buffer 0 read in
      Alcotest.(check int) "pumped TLS bytes" read written;
      written

let tls_handshake_state label ssl =
  match Eta_http__Openssl.handshake ssl with
  | Eta_http__Openssl.Handshake_ok -> `Done
  | Eta_http__Openssl.Handshake_error (2 | 3) -> `Pending
  | Eta_http__Openssl.Handshake_error code ->
      Alcotest.failf "%s handshake failed with SSL_get_error=%d" label code

let tls_handshake_step ssl =
  match Eta_http__Openssl.handshake ssl with
  | Eta_http__Openssl.Handshake_ok -> `Done
  | Eta_http__Openssl.Handshake_error (2 | 3) -> `Pending
  | Eta_http__Openssl.Handshake_error code -> `Failed code

let drive_tls_handshake client server =
  let rec loop remaining client_done server_done =
    if client_done && server_done then ()
    else if remaining = 0 then Alcotest.fail "TLS handshake did not converge"
    else
      let client_done =
        client_done || tls_handshake_state "client" client = `Done
      in
      let server_done =
        server_done || tls_handshake_state "server" server = `Done
      in
      ignore (pump_tls client server + pump_tls server client : int);
      loop (remaining - 1) client_done server_done
  in
  loop 100 false false

let drive_tls_handshake_failure client server =
  let rec loop remaining client_done server_done =
    if remaining = 0 then Alcotest.fail "TLS handshake unexpectedly converged"
    else
      match (tls_handshake_step client, tls_handshake_step server) with
      | `Failed _, _ | _, `Failed _ -> ()
      | client_state, server_state ->
          let client_done = client_done || client_state = `Done in
          let server_done = server_done || server_state = `Done in
          ignore (pump_tls client server + pump_tls server client : int);
          if client_done && server_done then
            Alcotest.fail "TLS handshake unexpectedly succeeded";
          loop (remaining - 1) client_done server_done
  in
  loop 100 false false

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s missing" label

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let read_all_response flow =
  let buffer = Buffer.create 128 in
  let scratch = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Buffer.contents buffer
    | len ->
        Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 len));
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let wait_for_server_stats clock server predicate =
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
      let rec loop () =
        let stats = Eta_http_eio.Server.stats server in
        if predicate stats then stats
        else (
          Eio.Time.sleep clock 0.01;
          loop ())
      in
      loop ())

let find_tls_eio_source () =
  let candidates =
    [
      "lib/http_eio/tls/tls_eio.ml";
      "lib/http/tls/tls_eio.ml";
      "../lib/http_eio/tls/tls_eio.ml";
      "../lib/http/tls/tls_eio.ml";
      "../../lib/http_eio/tls/tls_eio.ml";
      "../../lib/http/tls/tls_eio.ml";
      "../../../lib/http_eio/tls/tls_eio.ml";
      "../../../lib/http/tls/tls_eio.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate tls_eio.ml from %s" (Sys.getcwd ())

let do_handshake_source source =
  let start_markers = [ "let do_handshake t ="; "let rec do_handshake t =" ] in
  let end_marker = "let close t =" in
  match
    List.find_map
      (fun marker -> find_sub source ~needle:marker)
      start_markers
  with
  | None -> Alcotest.fail "missing do_handshake definition"
  | Some start -> (
      match find_sub_from source ~needle:end_marker start with
      | None -> Alcotest.fail "missing do_handshake end marker"
      | Some finish -> String.sub source start (finish - start))

let client_of_flow_source source =
  match find_sub source ~needle:"let client_of_flow" with
  | None -> Alcotest.fail "missing client_of_flow definition"
  | Some start -> (
      match find_sub_from source ~needle:"let epoch flow =" start with
      | None -> Alcotest.fail "missing client_of_flow end marker"
      | Some finish -> String.sub source start (finish - start))

let test_openssl_ssl_finalizer_keeps_ctx_ownership_separate () =
  let exercise_shared_ctx () =
    let ctx = Eta_http__Openssl.create_ctx () in
    let ssl_a =
      Eta_http__Openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    let ssl_b =
      Eta_http__Openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    Gc.full_major ();
    Alcotest.(check int)
      "pending bytes before handshake" 0
      (Eta_http__Openssl.bio_write_pending ssl_a);
    ignore (Eta_http__Openssl.bio_write_pending ssl_b : int)
  in
  exercise_shared_ctx ();
  Gc.full_major ();
  Gc.full_major ()

let test_openssl_server_ctx_loads_cert_key_and_creates_ssl () =
  with_temp_tls_files @@ fun cert key ->
  let ctx =
    Eta_http__Openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ]
      ()
  in
  let ssl = Eta_http__Openssl.create_server_ssl ctx in
  Alcotest.(check int)
    "pending bytes before handshake" 0
    (Eta_http__Openssl.bio_write_pending ssl)

let test_openssl_server_alpn_selects_client_protocol () =
  with_temp_tls_files @@ fun cert key ->
  let server_ctx =
    Eta_http__Openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http__Openssl.create_ctx () in
  Eta_http__Openssl.ctx_load_ca client_ctx cert;
  let server = Eta_http__Openssl.create_server_ssl server_ctx in
  let client =
    Eta_http__Openssl.create_ssl client_ctx ~hostname:(Some "localhost")
      ~ip:None ~alpn_protocols:[ "h2"; "http/1.1" ]
  in
  drive_tls_handshake client server;
  Alcotest.(check (option string))
    "client ALPN" (Some "h2") (Eta_http__Openssl.get_alpn_selected client);
  Alcotest.(check (option string))
    "server ALPN" (Some "h2") (Eta_http__Openssl.get_alpn_selected server)

let test_openssl_server_resumes_client_session () =
  with_temp_tls_files @@ fun cert key ->
  let server_ctx =
    Eta_http__Openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http__Openssl.create_ctx () in
  Eta_http__Openssl.ctx_load_ca client_ctx cert;
  let handshake ?session () =
    let server = Eta_http__Openssl.create_server_ssl server_ctx in
    let client =
      Eta_http__Openssl.create_ssl client_ctx ~hostname:(Some "localhost")
        ~ip:None ~alpn_protocols:[ "http/1.1" ]
    in
    Option.iter (Eta_http__Openssl.set_session client) session;
    drive_tls_handshake client server;
    Alcotest.(check int) "client verify result" 0
      (Eta_http__Openssl.get_verify_result client);
    (client, server)
  in
  let client1, server1 = handshake () in
  Alcotest.(check bool) "first client reused" false
    (Eta_http__Openssl.session_reused client1);
  Alcotest.(check bool) "first server reused" false
    (Eta_http__Openssl.session_reused server1);
  let session =
    require_some "client session" (Eta_http__Openssl.get_session client1)
  in
  let client2, server2 = handshake ~session () in
  Alcotest.(check bool) "second client reused" true
    (Eta_http__Openssl.session_reused client2);
  Alcotest.(check bool) "second server reused" true
    (Eta_http__Openssl.session_reused server2)

let test_openssl_server_sni_selects_named_certificate () =
  with_temp_tls_files @@ fun default_cert default_key ->
  with_generated_tls_files "alt.localhost" @@ fun alt_cert alt_key ->
  with_temp_ca_bundle [ default_cert; alt_cert ] @@ fun ca_bundle ->
  let certificate =
    Eta_http__Openssl.server_certificate ~server_name:"alt.localhost"
      ~certificate_chain_file:alt_cert ~private_key_file:alt_key
  in
  let server_ctx =
    Eta_http__Openssl.create_server_ctx
      ~certificate_chain_file:default_cert ~private_key_file:default_key
      ~certificates:[ certificate ] ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http__Openssl.create_ctx () in
  Eta_http__Openssl.ctx_load_ca client_ctx ca_bundle;
  let server = Eta_http__Openssl.create_server_ssl server_ctx in
  let client =
    Eta_http__Openssl.create_ssl client_ctx ~hostname:(Some "alt.localhost")
      ~ip:None ~alpn_protocols:[ "http/1.1" ]
  in
  drive_tls_handshake client server;
  Alcotest.(check int) "client verified selected cert" 0
    (Eta_http__Openssl.get_verify_result client);
  Alcotest.(check (option string))
    "server SNI" (Some "alt.localhost")
    (Eta_http__Openssl.get_servername server);
  Alcotest.(check (option string))
    "server ALPN" (Some "http/1.1")
    (Eta_http__Openssl.get_alpn_selected server)

let test_openssl_server_sni_strict_rejects_unknown_name () =
  with_temp_tls_files @@ fun default_cert default_key ->
  let server_ctx =
    Eta_http__Openssl.create_server_ctx
      ~certificate_chain_file:default_cert ~private_key_file:default_key
      ~require_sni_match:true ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http__Openssl.create_ctx () in
  Eta_http__Openssl.ctx_load_ca client_ctx default_cert;
  let server = Eta_http__Openssl.create_server_ssl server_ctx in
  let client =
    Eta_http__Openssl.create_ssl client_ctx ~hostname:(Some "unknown.localhost")
      ~ip:None ~alpn_protocols:[ "http/1.1" ]
  in
  drive_tls_handshake_failure client server

let test_tls_eio_server_of_flow_handshake_epoch () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun _stdenv ->
  Eio.Switch.run @@ fun sw ->
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let server_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ] ()
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
      ~alpn_protocols:[ "h2"; "http/1.1" ] ()
  in
  let server_result = ref None in
  let client_result = ref None in
  Eio.Fiber.both
    (fun () ->
      server_result :=
        Some
          (Eta_http_eio.Tls.Eio.server_of_flow server_config server_raw))
    (fun () ->
      client_result :=
        Some (Eta_http_eio.Tls.Eio.client_of_flow client_config client_raw));
  let server_flow, server_epoch = require_some "server TLS result" !server_result in
  let client_flow = require_some "client TLS result" !client_result in
  Alcotest.(check (option string))
    "server epoch ALPN" (Some "h2") server_epoch.alpn_protocol;
  Alcotest.(check (option string))
    "server SNI" (Some "localhost") server_epoch.sni;
  Alcotest.(check bool)
    "server peer certificate verification" false
    server_epoch.peer_certificate_verified;
  Alcotest.(check (option string))
    "server flow ALPN" (Some "h2")
    (Eta_http_eio.Tls.Eio.alpn_protocol server_flow);
  (match Eta_http_eio.Tls.Eio.epoch client_flow with
   | Ok client_epoch ->
       Alcotest.(check (option string))
         "client epoch ALPN" (Some "h2") client_epoch.alpn_protocol;
       Alcotest.(check (option string))
         "client SNI" (Some "localhost") client_epoch.sni;
	       Alcotest.(check bool)
	         "client peer certificate verification" true
	         client_epoch.peer_certificate_verified
	   | Error () -> Alcotest.fail "missing client TLS epoch");
  Eio.Flow.close client_flow;
  Eio.Flow.close server_flow

let test_tls_eio_server_of_flow_sni_selects_named_certificate () =
  with_temp_tls_files @@ fun default_cert default_key ->
  with_generated_tls_files "alt.localhost" @@ fun alt_cert alt_key ->
  with_temp_ca_bundle [ default_cert; alt_cert ] @@ fun ca_bundle ->
  run_eio @@ fun _stdenv ->
  Eio.Switch.run @@ fun sw ->
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let certificate =
    Eta_http.Tls.Config.server_certificate ~server_name:"alt.localhost"
      ~certificate_chain_file:alt_cert ~private_key_file:alt_key
  in
  let server_config =
    Eta_http.Tls.Config.default_server
      ~certificate_chain_file:default_cert ~private_key_file:default_key
      ~certificates:[ certificate ] ~alpn_protocols:[ "http/1.1" ] ()
  in
  let alt = Domain_name.(host_exn (of_string_exn "alt.localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:alt ~ca_file:ca_bundle
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  let server_result = ref None in
  let client_result = ref None in
  Eio.Fiber.both
    (fun () ->
      server_result :=
        Some
          (Eta_http_eio.Tls.Eio.server_of_flow server_config server_raw))
    (fun () ->
      client_result :=
        Some (Eta_http_eio.Tls.Eio.client_of_flow client_config client_raw));
  let server_flow, server_epoch = require_some "server TLS result" !server_result in
  let client_flow = require_some "client TLS result" !client_result in
  Alcotest.(check (option string))
    "server epoch SNI" (Some "alt.localhost") server_epoch.sni;
  Alcotest.(check (option string))
    "server epoch ALPN" (Some "http/1.1") server_epoch.alpn_protocol;
  Eio.Flow.close client_flow;
  Eio.Flow.close server_flow

let test_alpn_server_dispatch_routes_and_closes_unsupported () =
  let routes = ref [] in
  let closed = ref 0 in
  let close () = incr closed in
  let use_h1 () = routes := "h1" :: !routes in
  let use_h2 () = routes := "h2" :: !routes in
  let run alpn =
    Eta_http_eio.Transport.Alpn_server.dispatch ~close ~use_h1 ~use_h2 alpn
  in
  let expect_ok label = function
    | Ok () -> ()
    | Error { Eta_http_eio.Transport.Alpn_server.protocol } ->
        Alcotest.failf "%s rejected %s" label protocol
  in
  expect_ok "none routes h1" (run None);
  expect_ok "http/1.1 routes h1" (run (Some "http/1.1"));
  expect_ok "h2 routes h2" (run (Some "h2"));
  (match run (Some "spdy/3") with
   | Error { Eta_http_eio.Transport.Alpn_server.protocol } ->
       Alcotest.(check string) "unsupported protocol" "spdy/3" protocol
   | Ok () -> Alcotest.fail "unsupported ALPN was accepted");
  Alcotest.(check int) "closed unsupported" 1 !closed;
  Alcotest.(check (list string))
    "routes" [ "h2"; "h1"; "h1" ] !routes

let test_https_server_h1_alpn_request () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let tls_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ] ()
  in
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close = function
    | Eta_http_eio.Server.Https_h1 stats ->
        ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
    | Eta_http_eio.Server.Https_h2 _ ->
        Alcotest.fail "HTTPS H1 request routed to H2"
  in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.path,
           request.scheme,
           request.tls,
           request.alpn_protocol,
           request.connection_id ));
    Eta.Effect.pure (Eta_http.Server.Response.text "secure-h1\n")
  in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~tls_config
      ~on_connection_close ~socket handler
  in
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
    (fun () ->
      Eio.Flow.copy_string
        ("GET /secure HTTP/1.1\r\nHost: localhost\r\n"
       ^ "Connection: close\r\n\r\n")
        tls_flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            read_all_response tls_flow)
      in
      Alcotest.(check string) "response"
        ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
       ^ "Content-Length: 10\r\n\r\nsecure-h1\n")
        response;
      let path, scheme, tls, alpn_protocol, connection_id =
        Eio.Promise.await seen_request
      in
      Alcotest.(check string) "path" "/secure" path;
      Alcotest.(check string) "scheme" "https" scheme;
      Alcotest.(check bool) "tls" true tls;
      Alcotest.(check (option string)) "alpn" (Some "http/1.1") alpn_protocol;
      Alcotest.(check bool) "connection id prefix" true
        (String.starts_with ~prefix:"h1-" connection_id);
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed requests" 1 stats.completed_requests;
      let server_stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "tls handshakes" 1 server_stats.tls_handshakes;
      Alcotest.(check int)
        "tls handshake failures" 0 server_stats.tls_handshake_failures;
      Alcotest.(check int) "alpn h1" 1 server_stats.alpn_h1;
      Alcotest.(check int) "alpn h2" 0 server_stats.alpn_h2;
      Alcotest.(check int) "alpn rejected" 0 server_stats.alpn_rejected;
      Eta_http_eio.Server.shutdown server Immediate)

let test_https_server_h2_alpn_request () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let tls_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ] ()
  in
  let seen_request, resolve_seen_request = Eio.Promise.create () in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close = function
    | Eta_http_eio.Server.Https_h2 stats ->
        ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
    | Eta_http_eio.Server.Https_h1 _ ->
        Alcotest.fail "HTTPS H2 request routed to H1"
  in
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         ( request.method_,
           request.path,
           request.scheme,
           request.authority,
           request.tls,
           request.alpn_protocol,
           request.connection_id ));
    Eta.Effect.pure (Eta_http.Server.Response.text "secure-h2\n")
  in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~tls_config
      ~on_connection_close ~socket handler
  in
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
      ~alpn_protocols:[ "h2" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
  Alcotest.(check (option string))
    "client ALPN" (Some "h2")
    (Eta_http_eio.Tls.Eio.alpn_protocol tls_flow);
  let connection =
    Eta_http_eio.H2.Connection.create ~sw
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        H2.Request.create ~scheme:"https"
          ~headers:(H2.Headers.of_list [ ":authority", "localhost" ])
          `GET "/secure-h2"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Test_eta_http_h2_server.await_h2_response connection request)
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "secure-h2\n" body;
      let method_, path, scheme, authority, tls, alpn_protocol, connection_id =
        Eio.Promise.await seen_request
      in
      Alcotest.(check string) "method" "GET" method_;
      Alcotest.(check string) "path" "/secure-h2" path;
      Alcotest.(check string) "scheme" "https" scheme;
      Alcotest.(check (option string)) "authority" (Some "localhost") authority;
      Alcotest.(check bool) "tls" true tls;
      Alcotest.(check (option string)) "alpn" (Some "h2") alpn_protocol;
      Alcotest.(check bool) "connection id prefix" true
        (String.starts_with ~prefix:"h2-tls-" connection_id);
      Eta_http_eio.H2.Connection.shutdown connection;
      let stats =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed streams" 1 stats.completed_streams;
      let server_stats = Eta_http_eio.Server.stats server in
      Alcotest.(check int) "tls handshakes" 1 server_stats.tls_handshakes;
      Alcotest.(check int)
        "tls handshake failures" 0 server_stats.tls_handshake_failures;
      Alcotest.(check int) "alpn h1" 0 server_stats.alpn_h1;
      Alcotest.(check int) "alpn h2" 1 server_stats.alpn_h2;
      Alcotest.(check int) "alpn rejected" 0 server_stats.alpn_rejected;
      Eta_http_eio.Server.shutdown server Immediate)

let test_https_server_handshake_timeout_stats () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let tls_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ] ()
  in
  let config =
    {
      Eta_http_eio.Server.Config.default with
      tls_handshake_timeout = Eta.Duration.ms 20;
    }
  in
  let handler_called = ref false in
  let handler _request =
    handler_called := true;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~config ~tls_config
      ~socket handler
  in
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let stats =
    wait_for_server_stats clock server (fun stats ->
        stats.tls_handshake_failures = 1)
  in
  Alcotest.(check int) "tls handshakes" 0 stats.tls_handshakes;
  Alcotest.(check int) "tls handshake failures" 1 stats.tls_handshake_failures;
  Alcotest.(check int) "alpn h1" 0 stats.alpn_h1;
  Alcotest.(check int) "alpn h2" 0 stats.alpn_h2;
  Alcotest.(check int) "alpn rejected" 0 stats.alpn_rejected;
  Alcotest.(check bool) "handler not called" false !handler_called;
  (try Eio.Flow.close raw with _ -> ());
  Eta_http_eio.Server.shutdown server Immediate

let test_https_server_unsupported_alpn_stats () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let tls_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "spdy/3" ] ()
  in
  let handler_called = ref false in
  let handler _request =
    handler_called := true;
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~tls_config ~socket
      handler
  in
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
      ~alpn_protocols:[ "spdy/3" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
  Alcotest.(check (option string))
    "client ALPN" (Some "spdy/3")
    (Eta_http_eio.Tls.Eio.alpn_protocol tls_flow);
  let stats =
    wait_for_server_stats clock server (fun stats -> stats.alpn_rejected = 1)
  in
  Alcotest.(check int) "tls handshakes" 1 stats.tls_handshakes;
  Alcotest.(check int) "tls handshake failures" 0 stats.tls_handshake_failures;
  Alcotest.(check int) "alpn h1" 0 stats.alpn_h1;
  Alcotest.(check int) "alpn h2" 0 stats.alpn_h2;
  Alcotest.(check int) "alpn rejected" 1 stats.alpn_rejected;
  Alcotest.(check bool) "handler not called" false !handler_called;
  (try Eio.Flow.close tls_flow with _ -> ());
  Eta_http_eio.Server.shutdown server Immediate

let test_openssl_server_ctx_rejects_invalid_cert () =
  with_temp_file "eta-http-bad-cert" "not a certificate" @@ fun bad ->
  Alcotest.check_raises "invalid cert"
    (Failure "SSL_CTX_use_certificate_chain_file failed") (fun () ->
      ignore
        (Eta_http__Openssl.create_server_ctx ~certificate_chain_file:bad
           ~private_key_file:bad ~alpn_protocols:[ "h2"; "http/1.1" ]
           ()
          : Eta_http__Openssl.ctx))

let test_openssl_server_ctx_rejects_invalid_key () =
  with_temp_file "eta-http-bad-key" "not a private key" @@ fun bad ->
  with_temp_file "eta-http-cert" tls_cert @@ fun cert ->
  Alcotest.check_raises "invalid key"
    (Failure "SSL_CTX_use_PrivateKey_file failed") (fun () ->
      ignore
        (Eta_http__Openssl.create_server_ctx ~certificate_chain_file:cert
           ~private_key_file:bad ~alpn_protocols:[ "h2"; "http/1.1" ]
           ()
          : Eta_http__Openssl.ctx))

let test_tls_server_config_records_cert_key_and_alpn () =
  let certificate =
    Eta_http.Tls.Config.server_certificate ~server_name:"alt.localhost"
      ~certificate_chain_file:"alt-cert.pem" ~private_key_file:"alt-key.pem"
  in
  let config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:"cert.pem"
      ~private_key_file:"key.pem" ~certificates:[ certificate ]
      ~require_sni_match:true ~alpn_protocols:[ "http/1.1" ] ()
  in
  Alcotest.(check string)
    "cert" "cert.pem" (Eta_http.Tls.Config.certificate_chain_file config);
  Alcotest.(check string)
    "key" "key.pem" (Eta_http.Tls.Config.private_key_file config);
  Alcotest.(check bool)
    "require sni" true (Eta_http.Tls.Config.require_sni_match config);
  Alcotest.(check (list string))
    "alpn" [ "http/1.1" ] (Eta_http.Tls.Config.server_alpn_protocols config);
  (match Eta_http.Tls.Config.server_certificates config with
  | [ actual ] ->
      Alcotest.(check string)
        "sni name" "alt.localhost"
        (Eta_http.Tls.Config.server_certificate_name actual);
      Alcotest.(check string)
        "sni cert" "alt-cert.pem"
        (Eta_http.Tls.Config.server_certificate_chain_file actual);
      Alcotest.(check string)
        "sni key" "alt-key.pem"
        (Eta_http.Tls.Config.server_certificate_private_key_file actual)
  | _ -> Alcotest.fail "expected one SNI certificate")

let test_tls_handshake_enters_ssl_mutex_before_openssl () =
  let source = read_file (find_tls_eio_source ()) in
  let body = do_handshake_source source in
  let guard = "with_ssl t (fun () ->" in
  let handshake = "Openssl.handshake t.ssl" in
  match (find_sub body ~needle:guard, find_sub body ~needle:handshake) with
  | Some guard_pos, Some handshake_pos ->
      Alcotest.(check bool)
        "mutex guard precedes handshake" true (guard_pos < handshake_pos)
  | None, _ -> Alcotest.fail "do_handshake does not enter ssl_mutex"
  | _, None -> Alcotest.fail "do_handshake does not call OpenSSL handshake"

let test_tls_client_of_flow_uses_ip_identity () =
  let source = read_file (find_tls_eio_source ()) in
  let body = client_of_flow_source source in
  Alcotest.(check bool)
    "TLS IP peer identity is consumed" true
    (contains body "Config.ip config")
