open Test_eta_http_support

module Dispatch = Eta_http_eio.Transport.Dispatch

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

let h2_request = Test_eta_http_h2_server.h2_request

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
  let pending = Eta_http_tls_openssl.bio_write_pending src in
  if pending = 0 then 0
  else
    let scratch = Cstruct.create pending in
    let buffer = Cstruct.to_bigarray scratch in
    let read = Eta_http_tls_openssl.bio_read src buffer 0 pending in
    if read = 0 then 0
    else
      let written = Eta_http_tls_openssl.bio_write dst buffer 0 read in
      Alcotest.(check int) "pumped TLS bytes" read written;
      written

let tls_handshake_state label ssl =
  match Eta_http_tls_openssl.handshake ssl with
  | Eta_http_tls_openssl.Handshake_ok -> `Done
  | Eta_http_tls_openssl.Handshake_error (2 | 3) -> `Pending
  | Eta_http_tls_openssl.Handshake_error code ->
      Alcotest.failf "%s handshake failed with SSL_get_error=%d" label code

let tls_handshake_step ssl =
  match Eta_http_tls_openssl.handshake ssl with
  | Eta_http_tls_openssl.Handshake_ok -> `Done
  | Eta_http_tls_openssl.Handshake_error (2 | 3) -> `Pending
  | Eta_http_tls_openssl.Handshake_error code -> `Failed code

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

let drain_tls_post_handshake client server =
  let scratch = Cstruct.to_bigarray (Cstruct.create 1) in
  let rec loop remaining =
    if remaining = 0 then ()
    else (
      ignore (pump_tls server client + pump_tls client server : int);
      ignore (Eta_http_tls_openssl.read client scratch 0 1 : int);
      loop (remaining - 1))
  in
  loop 20

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

let single_write_source source =
  match find_sub source ~needle:"let single_write t bufs =" with
  | None -> Alcotest.fail "missing single_write definition"
  | Some start -> (
      match find_sub_from source ~needle:"  let copy t ~src =" start with
      | None -> Alcotest.fail "missing single_write end marker"
      | Some finish -> String.sub source start (finish - start))

let single_read_source source =
  match find_sub source ~needle:"  let single_read t buf =" with
  | None -> Alcotest.fail "missing single_read definition"
  | Some start -> (
      match find_sub_from source ~needle:"  let single_write t bufs =" start with
      | None -> Alcotest.fail "missing single_read end marker"
      | Some finish -> String.sub source start (finish - start))

let counting_host_eio read_count =
  let module Eio_ops = struct
    module Time = struct
      let now = Eio.Time.now
      let sleep = Eio.Time.sleep
    end

    module Net = struct
      let getaddrinfo_stream = Eio.Net.getaddrinfo_stream
      let connect = Eio.Net.connect
    end

    module Flow = struct
      let single_read flow buf =
        incr read_count;
        Eio.Flow.single_read flow buf

      let write = Eio.Flow.write
    end

    module Switch = struct
      let run = Eio.Switch.run
      let fail = Eio.Switch.fail
    end

    module Fiber = struct
      let get = Eio.Fiber.get
      let with_binding = Eio.Fiber.with_binding
      let first = Eio.Fiber.first
      let await_cancel = Eio.Fiber.await_cancel
      let fork = Eio.Fiber.fork
      let fork_daemon = Eio.Fiber.fork_daemon
      let yield = Eio.Fiber.yield
      let check = Eio.Fiber.check
    end

    module Stream = struct
      type 'a t = 'a Eio.Stream.t

      let create = Eio.Stream.create
      let add = Eio.Stream.add
      let take = Eio.Stream.take
      let take_nonblocking = Eio.Stream.take_nonblocking
    end

    module Cancel = struct
      let sub = Eio.Cancel.sub
      let cancel = Eio.Cancel.cancel
    end
  end in
  Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio_ops) ()

let https_h2_server_config cert key =
  Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
    ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ] ()

let https_h2_client_config cert =
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
    ~alpn_protocols:[ "h2" ] ()

let https_no_alpn_client_config cert =
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
    ~alpn_protocols:[] ()

let start_https_h2_test_server ?config ~sw ~clock ~net ~cert ~key handler =
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:8 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let tls_config = https_h2_server_config cert key in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ?config ~tls_config
      ~socket handler
  in
  (server, port)

let connect_https_h2_tls_flow ~sw ~net ~cert port =
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  Eta_http_eio.Tls.Eio.client_of_flow (https_h2_client_config cert) raw_flow

let h2_settings_ack =
  Eta_http_h2.Frame.header ~length:0 ~frame_type:Settings ~flags:1
    ~stream_id:0

let h2_ping payload =
  Eta_http_h2.Frame.header ~length:(String.length payload) ~frame_type:Ping
    ~flags:0 ~stream_id:0
  ^ payload

let openssl_want_read = 2
let openssl_want_write = 3
let openssl_zero_return = 6

let drain_openssl_client_to_flow ssl flow =
  let rec loop () =
    let pending = Eta_http_tls_openssl.bio_write_pending ssl in
    if pending > 0 then (
      let encrypted = Cstruct.create pending in
      let len =
        Eta_http_tls_openssl.bio_read ssl (Cstruct.to_bigarray encrypted) 0
          pending
      in
      if len > 0 then (
        Eio.Flow.write flow [ Cstruct.sub encrypted 0 len ];
        loop ()))
  in
  loop ()

let feed_openssl_client_from_flow ~clock ssl flow =
  let encrypted = Cstruct.create 4096 in
  match
    Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        Eio.Flow.single_read flow encrypted)
  with
  | 0 -> `Eof
  | len ->
      let written =
        Eta_http_tls_openssl.bio_write ssl (Cstruct.to_bigarray encrypted) 0 len
      in
      Alcotest.(check int) "fed encrypted TLS bytes" len written;
      `Fed
  | exception End_of_file -> `Eof

let h2_openssl_client cert =
  let ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca ctx cert;
  Eta_http_tls_openssl.create_ssl ctx ~hostname:(Some "localhost") ~ip:None
    ~alpn_protocols:[ "h2" ]

let drive_openssl_client_handshake ~clock ssl flow =
  let rec loop remaining =
    if remaining = 0 then Alcotest.fail "OpenSSL client handshake timed out"
    else
      match Eta_http_tls_openssl.handshake ssl with
      | Eta_http_tls_openssl.Handshake_ok ->
          drain_openssl_client_to_flow ssl flow;
          Alcotest.(check int) "client certificate verified" 0
            (Eta_http_tls_openssl.get_verify_result ssl);
          Alcotest.(check (option string)) "client selected h2" (Some "h2")
            (Eta_http_tls_openssl.get_alpn_selected ssl)
      | Eta_http_tls_openssl.Handshake_error code
        when code = openssl_want_read ->
          drain_openssl_client_to_flow ssl flow;
          (match feed_openssl_client_from_flow ~clock ssl flow with
          | `Fed -> loop (remaining - 1)
          | `Eof -> Alcotest.fail "raw EOF during OpenSSL client handshake")
      | Eta_http_tls_openssl.Handshake_error code
        when code = openssl_want_write ->
          drain_openssl_client_to_flow ssl flow;
          Eio.Fiber.yield ();
          loop (remaining - 1)
      | Eta_http_tls_openssl.Handshake_error code ->
          Alcotest.failf "OpenSSL client handshake failed with SSL_get_error=%d"
            code
  in
  loop 100

let write_openssl_client_plaintext ~clock ssl flow bytes =
  let plaintext = Cstruct.of_string bytes in
  let storage = Cstruct.to_bigarray plaintext in
  let rec loop off len =
    if len > 0 then (
      let rc = Eta_http_tls_openssl.write ssl storage off len in
      drain_openssl_client_to_flow ssl flow;
      if rc > 0 then loop (off + rc) (len - rc)
      else
        let code = -rc in
        if code = openssl_want_read then (
          (match feed_openssl_client_from_flow ~clock ssl flow with
          | `Fed -> ()
          | `Eof -> Alcotest.fail "raw EOF while TLS write wanted read");
          loop off len)
        else if code = openssl_want_write then (
          Eio.Fiber.yield ();
          loop off len)
        else Alcotest.failf "OpenSSL client write failed with SSL_get_error=%d"
          code)
  in
  loop 0 (String.length bytes)

let read_openssl_client_plaintext ~clock ssl flow =
  let plaintext = Cstruct.create 16384 in
  let storage = Cstruct.to_bigarray plaintext in
  let rec loop () =
    let rc =
      Eta_http_tls_openssl.read ssl storage 0 (Cstruct.length plaintext)
    in
    if rc > 0 then
      `Data (Cstruct.to_string (Cstruct.sub plaintext 0 rc))
    else
      let code = -rc in
      if code = openssl_zero_return then `Close_notify
      else if code = openssl_want_read then (
        drain_openssl_client_to_flow ssl flow;
        match feed_openssl_client_from_flow ~clock ssl flow with
        | `Fed -> loop ()
        | `Eof -> `Raw_eof)
      else if code = openssl_want_write then (
        drain_openssl_client_to_flow ssl flow;
        Eio.Fiber.yield ();
        loop ())
      else
        Alcotest.failf "OpenSSL client read failed with SSL_get_error=%d" code
  in
  loop ()

let read_openssl_h2_until_frame ~clock ssl flow ?stream_id frame_type =
  let buffer = Buffer.create 256 in
  let rec loop () =
    match read_openssl_client_plaintext ~clock ssl flow with
    | `Data chunk ->
        Buffer.add_string buffer chunk;
        let bytes = Buffer.contents buffer in
        if Test_eta_http_h2_server.raw_h2_has_frame ?stream_id frame_type bytes
        then bytes
        else loop ()
    | `Close_notify ->
        Alcotest.fail "TLS close_notify before expected HTTP/2 frame"
    | `Raw_eof -> Alcotest.fail "raw EOF before expected HTTP/2 frame"
  in
  Eio.Time.with_timeout_exn clock 2.0 loop

let expect_openssl_client_close_notify ~clock ssl flow =
  let rec loop () =
    match read_openssl_client_plaintext ~clock ssl flow with
    | `Close_notify -> ()
    | `Raw_eof -> Alcotest.fail "raw EOF before TLS close_notify"
    | `Data _ -> loop ()
  in
  Eio.Time.with_timeout_exn clock 2.0 loop

let write_byte_by_byte flow bytes =
  for index = 0 to String.length bytes - 1 do
    Eio.Flow.copy_string (String.make 1 bytes.[index]) flow
  done

let assert_fresh_https_h2_request ~sw ~net ~clock ~cert port =
  let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        h2_request ~scheme:"https"
          ~headers:( [ ":authority", "localhost" ])
          `GET "/fresh"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            Test_eta_http_h2_server.await_h2_response connection request)
      in
      Alcotest.(check int) "fresh status" 200 status;
      Alcotest.(check string) "fresh body" "ok:/fresh" body)

let with_https_h2_connection ?config ~cert ~key ~env ~sw handler f =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let server, port =
    start_https_h2_test_server ?config ~sw ~clock ~net ~cert ~key handler
  in
  let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () -> f ~clock ~server ~connection)

let test_openssl_ssl_finalizer_keeps_ctx_ownership_separate () =
  let exercise_shared_ctx () =
    let ctx = Eta_http_tls_openssl.create_ctx () in
    let ssl_a =
      Eta_http_tls_openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    let ssl_b =
      Eta_http_tls_openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    Gc.full_major ();
    Alcotest.(check int)
      "pending bytes before handshake" 0
      (Eta_http_tls_openssl.bio_write_pending ssl_a);
    ignore (Eta_http_tls_openssl.bio_write_pending ssl_b : int)
  in
  exercise_shared_ctx ();
  Gc.full_major ();
  Gc.full_major ()

let test_openssl_server_ctx_loads_cert_key_and_creates_ssl () =
  with_temp_tls_files @@ fun cert key ->
  let ctx =
    Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ]
      ()
  in
  let ssl = Eta_http_tls_openssl.create_server_ssl ctx in
  Alcotest.(check int)
    "pending bytes before handshake" 0
    (Eta_http_tls_openssl.bio_write_pending ssl)

let test_openssl_server_alpn_selects_client_protocol () =
  with_temp_tls_files @@ fun cert key ->
  let server_ctx =
    Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "h2"; "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca client_ctx cert;
  let server = Eta_http_tls_openssl.create_server_ssl server_ctx in
  let client =
    Eta_http_tls_openssl.create_ssl client_ctx ~hostname:(Some "localhost")
      ~ip:None ~alpn_protocols:[ "h2"; "http/1.1" ]
  in
  drive_tls_handshake client server;
  Alcotest.(check (option string))
    "client ALPN" (Some "h2") (Eta_http_tls_openssl.get_alpn_selected client);
  Alcotest.(check (option string))
    "server ALPN" (Some "h2") (Eta_http_tls_openssl.get_alpn_selected server)

let test_openssl_negotiates_tls13_by_default () =
  with_temp_tls_files @@ fun cert key ->
  let server_ctx =
    Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca client_ctx cert;
  let server = Eta_http_tls_openssl.create_server_ssl server_ctx in
  let client =
    Eta_http_tls_openssl.create_ssl client_ctx ~hostname:(Some "localhost")
      ~ip:None ~alpn_protocols:[ "http/1.1" ]
  in
  drive_tls_handshake client server;
  Alcotest.(check string) "client TLS version" "TLSv1.3"
    (Eta_http_tls_openssl.get_version client);
  Alcotest.(check string) "server TLS version" "TLSv1.3"
    (Eta_http_tls_openssl.get_version server)

let test_openssl_server_resumes_client_session () =
  with_temp_tls_files @@ fun cert key ->
  let server_ctx =
    Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca client_ctx cert;
  let handshake ?session () =
    let server = Eta_http_tls_openssl.create_server_ssl server_ctx in
    let client =
      Eta_http_tls_openssl.create_ssl client_ctx ~hostname:(Some "localhost")
        ~ip:None ~alpn_protocols:[ "http/1.1" ]
    in
    Option.iter (Eta_http_tls_openssl.set_session client) session;
    drive_tls_handshake client server;
    drain_tls_post_handshake client server;
    Alcotest.(check int) "client verify result" 0
      (Eta_http_tls_openssl.get_verify_result client);
    (client, server)
  in
  let client1, server1 = handshake () in
  Alcotest.(check bool) "first client reused" false
    (Eta_http_tls_openssl.session_reused client1);
  Alcotest.(check bool) "first server reused" false
    (Eta_http_tls_openssl.session_reused server1);
  let session =
    require_some "client session" (Eta_http_tls_openssl.get_session client1)
  in
  let client2, server2 = handshake ~session () in
  Alcotest.(check bool) "second client reused" true
    (Eta_http_tls_openssl.session_reused client2);
  Alcotest.(check bool) "second server reused" true
    (Eta_http_tls_openssl.session_reused server2)

let test_openssl_server_sni_selects_named_certificate () =
  with_temp_tls_files @@ fun default_cert default_key ->
  with_generated_tls_files "alt.localhost" @@ fun alt_cert alt_key ->
  with_temp_ca_bundle [ default_cert; alt_cert ] @@ fun ca_bundle ->
  let certificate =
    Eta_http_tls_openssl.server_certificate ~server_name:"alt.localhost"
      ~certificate_chain_file:alt_cert ~private_key_file:alt_key
  in
  let server_ctx =
    Eta_http_tls_openssl.create_server_ctx
      ~certificate_chain_file:default_cert ~private_key_file:default_key
      ~certificates:[ certificate ] ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca client_ctx ca_bundle;
  let server = Eta_http_tls_openssl.create_server_ssl server_ctx in
  let client =
    Eta_http_tls_openssl.create_ssl client_ctx ~hostname:(Some "alt.localhost")
      ~ip:None ~alpn_protocols:[ "http/1.1" ]
  in
  drive_tls_handshake client server;
  Alcotest.(check int) "client verified selected cert" 0
    (Eta_http_tls_openssl.get_verify_result client);
  Alcotest.(check (option string))
    "server SNI" (Some "alt.localhost")
    (Eta_http_tls_openssl.get_servername server);
  Alcotest.(check (option string))
    "server ALPN" (Some "http/1.1")
    (Eta_http_tls_openssl.get_alpn_selected server)

let test_openssl_server_sni_strict_rejects_unknown_name () =
  with_temp_tls_files @@ fun default_cert default_key ->
  let server_ctx =
    Eta_http_tls_openssl.create_server_ctx
      ~certificate_chain_file:default_cert ~private_key_file:default_key
      ~require_sni_match:true ~alpn_protocols:[ "http/1.1" ]
      ()
  in
  let client_ctx = Eta_http_tls_openssl.create_ctx () in
  Eta_http_tls_openssl.ctx_load_ca client_ctx default_cert;
  let server = Eta_http_tls_openssl.create_server_ssl server_ctx in
  let client =
    Eta_http_tls_openssl.create_ssl client_ctx ~hostname:(Some "unknown.localhost")
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

let with_tls_flow_pair ~sw ~cert ~key f =
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let server_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
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
  let server_flow, _server_epoch =
    require_some "server TLS result" !server_result
  in
  let client_flow = require_some "client TLS result" !client_result in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Flow.close client_flow with _ -> ();
      try Eio.Flow.close server_flow with _ -> ())
    (fun () -> f ~server_flow ~client_flow)

let test_tls_eio_single_read_respects_cstruct_offset () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_tls_flow_pair ~sw ~cert ~key @@ fun ~server_flow ~client_flow ->
  Eio.Flow.write client_flow [ Cstruct.of_string "hello" ];
  let storage = Cstruct.of_string "xxxxx.....yyyyy" in
  let dst = Cstruct.sub storage 5 5 in
  let read = Eio.Flow.single_read server_flow dst in
  Alcotest.(check int) "read" 5 read;
  Alcotest.(check string)
    "subrange filled" "xxxxxhelloyyyyy" (Cstruct.to_string storage)

let test_tls_eio_single_write_respects_cstruct_offset () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_tls_flow_pair ~sw ~cert ~key @@ fun ~server_flow ~client_flow ->
  let storage = Cstruct.of_string "xxxxxhelloyyyyy" in
  Eio.Flow.write client_flow [ Cstruct.sub storage 5 5 ];
  let dst = Cstruct.create 5 in
  let read = Eio.Flow.single_read server_flow dst in
  Alcotest.(check int) "read" 5 read;
  Alcotest.(check string) "peer received subrange" "hello"
    (Cstruct.to_string dst)

let test_tls_eio_single_read_drains_pending_plaintext_before_raw_read () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let read_count = ref 0 in
  let host_eio = counting_host_eio read_count in
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let server_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  let server_result = ref None in
  let client_result = ref None in
  Eio.Fiber.both
    (fun () ->
      server_result :=
        Some
          (Eta_http_eio.Tls.Eio.server_of_flow ~host_eio server_config
             server_raw))
    (fun () ->
      client_result :=
        Some (Eta_http_eio.Tls.Eio.client_of_flow client_config client_raw));
  let server_flow, _server_epoch =
    require_some "server TLS result" !server_result
  in
  let client_flow = require_some "client TLS result" !client_result in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Flow.close client_flow with _ -> ();
      try Eio.Flow.close server_flow with _ -> ())
    (fun () ->
      let handshake_reads = !read_count in
      Eio.Flow.write client_flow [ Cstruct.of_string "helloworld" ];
      let first = Cstruct.create 5 in
      let first_read = Eio.Flow.single_read server_flow first in
      Alcotest.(check int) "first read" 5 first_read;
      Alcotest.(check string) "first bytes" "hello" (Cstruct.to_string first);
      let reads_after_first = !read_count in
      Alcotest.(check bool)
        "first application read used raw input" true
        (reads_after_first > handshake_reads);
      let second = Cstruct.create 5 in
      let second_read = Eio.Flow.single_read server_flow second in
      Alcotest.(check int) "second read" 5 second_read;
      Alcotest.(check string) "second bytes" "world" (Cstruct.to_string second);
      Alcotest.(check int)
        "pending plaintext read did not touch raw flow" reads_after_first
        !read_count)

let test_tls_eio_shutdown_all_sends_close_notify () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let server_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:cert
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
  let server_flow, _server_epoch =
    require_some "server TLS result" !server_result
  in
  let client_flow = require_some "client TLS result" !client_result in
  Fun.protect
    ~finally:(fun () ->
      try Eio.Flow.close client_flow with _ -> ();
      try Eio.Flow.close server_flow with _ -> ())
    (fun () ->
      Eio.Flow.shutdown server_flow `All;
      let observed_eof =
        Eio.Time.with_timeout_exn clock 0.2 (fun () ->
            match Eio.Flow.single_read client_flow (Cstruct.create 1) with
            | 0 -> true
            | _ -> false
            | exception End_of_file -> true)
      in
      Alcotest.(check bool) "peer observed TLS close_notify" true observed_eof)

let test_tls_eio_server_context_reuses_loaded_certificates () =
  with_temp_tls_files @@ fun cert key ->
  with_temp_ca_bundle [ cert ] @@ fun ca_bundle ->
  let server_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  let server_context = Eta_http_eio.Tls.Eio.server_context server_config in
  remove_noerr cert;
  remove_noerr key;
  run_eio @@ fun _stdenv ->
  Eio.Switch.run @@ fun sw ->
  let server_raw, client_raw = Eio_unix.Net.socketpair_stream ~sw () in
  let localhost = Domain_name.(host_exn (of_string_exn "localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:localhost ~ca_file:ca_bundle
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  let server_result = ref None in
  let client_result = ref None in
  Eio.Fiber.both
    (fun () ->
      server_result :=
        Some
          (Eta_http_eio.Tls.Eio.server_of_flow_with_context server_context
             server_raw))
    (fun () ->
      client_result :=
        Some (Eta_http_eio.Tls.Eio.client_of_flow client_config client_raw));
  let server_flow, server_epoch = require_some "server TLS result" !server_result in
  let client_flow = require_some "client TLS result" !client_result in
  Alcotest.(check (option string))
    "server epoch ALPN" (Some "http/1.1") server_epoch.alpn_protocol;
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
  let mixed = Dispatch.mixed_protocols in
  let h2_only =
    Dispatch.enabled_protocols ~h1:false ~h2:true
  in
  let run ?(enabled_protocols = mixed) alpn =
    Eta_http_eio.Transport.Alpn_server.dispatch ~enabled_protocols ~close
      ~use_h1 ~use_h2 alpn
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
  (match run ~enabled_protocols:h2_only None with
  | Error { Eta_http_eio.Transport.Alpn_server.protocol } ->
      Alcotest.(check string)
        "missing protocol" "missing ALPN protocol" protocol
  | Ok () -> Alcotest.fail "missing ALPN was accepted for H2-only");
  Alcotest.(check int) "closed unsupported" 2 !closed;
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

let test_https_server_mixed_accepts_missing_alpn_as_h1 () =
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
  let handler (request : Eta_http.Server.Request.t) =
    ignore
      (Eio.Promise.try_resolve resolve_seen_request
         (request.path, request.alpn_protocol, request.connection_id));
    Eta.Effect.pure (Eta_http.Server.Response.text "legacy-h1\n")
  in
  let server =
    Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~tls_config ~socket
      handler
  in
  let raw =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow =
    Eta_http_eio.Tls.Eio.client_of_flow
      (https_no_alpn_client_config cert)
      raw_flow
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
    (fun () ->
      Alcotest.(check (option string))
        "client ALPN" None
        (Eta_http_eio.Tls.Eio.alpn_protocol tls_flow);
      Eio.Flow.copy_string
        ("GET /legacy HTTP/1.1\r\nHost: localhost\r\n"
       ^ "Connection: close\r\n\r\n")
        tls_flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            read_all_response tls_flow)
      in
      Alcotest.(check string) "response"
        ("HTTP/1.1 200 OK\r\nConnection: close\r\n"
       ^ "Content-Length: 10\r\n\r\nlegacy-h1\n")
        response;
      let path, alpn_protocol, connection_id =
        Eio.Promise.await seen_request
      in
      Alcotest.(check string) "path" "/legacy" path;
      Alcotest.(check (option string)) "request ALPN" None alpn_protocol;
      Alcotest.(check bool) "connection id prefix" true
        (String.starts_with ~prefix:"h1-" connection_id);
      let stats =
        wait_for_server_stats clock server (fun stats -> stats.alpn_h1 = 1)
      in
      Alcotest.(check int) "alpn h1" 1 stats.alpn_h1;
      Alcotest.(check int) "alpn h2" 0 stats.alpn_h2;
      Alcotest.(check int) "alpn rejected" 0 stats.alpn_rejected;
      Eta_http_eio.Server.shutdown server Immediate)

let test_https_server_h2_only_rejects_http1_without_alpn () =
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
      ~private_key_file:key ~alpn_protocols:[ "h2" ] ()
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
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow =
    Eta_http_eio.Tls.Eio.client_of_flow
      (https_no_alpn_client_config cert)
      raw_flow
  in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
    (fun () ->
      Alcotest.(check (option string))
        "client ALPN" None
        (Eta_http_eio.Tls.Eio.alpn_protocol tls_flow);
      (try
         Eio.Flow.copy_string
           ("GET /wrong HTTP/1.1\r\nHost: localhost\r\n"
          ^ "Connection: close\r\n\r\n")
           tls_flow
       with _ -> ());
      let response =
        try
          Eio.Time.with_timeout_exn clock 1.0 (fun () ->
              read_all_response tls_flow)
        with Eio.Io _ -> ""
      in
      Alcotest.(check string) "no H1 response" "" response;
      let stats =
        wait_for_server_stats clock server (fun stats ->
            stats.alpn_rejected = 1)
      in
      Alcotest.(check int) "alpn h1" 0 stats.alpn_h1;
      Alcotest.(check int) "alpn h2" 0 stats.alpn_h2;
      Alcotest.(check int) "alpn rejected" 1 stats.alpn_rejected;
      Alcotest.(check bool) "handler not called" false !handler_called;
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
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
    (fun () ->
      let request =
        h2_request ~scheme:"https"
          ~headers:( [ ":authority", "localhost" ])
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

let test_https_server_h2_streams_large_body_past_window () =
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
  let total = 512 * 1024 in
  let chunk_size = 16 * 1024 in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/large" ->
        let remaining = ref total in
        let body =
          Eta_http.Server.Response.Body.stream ~length:total (fun () ->
              if !remaining = 0 then Eta.Effect.pure None
              else
                let n = min chunk_size !remaining in
                remaining := !remaining - n;
                Eta.Effect.pure (Some (Bytes.make n 'z')))
        in
        Eta.Effect.pure (Eta_http.Server.Response.make ~status:200 ~body ())
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
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
      ~alpn_protocols:[ "h2" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let request =
        h2_request ~scheme:"https"
          ~headers:( [ ":authority", "localhost" ])
          `GET "/large"
      in
      let status, body =
        Eio.Time.with_timeout_exn clock 10.0 (fun () ->
            Test_eta_http_h2_server.await_h2_response connection request)
      in
      Alcotest.(check int) "large tls stream status" 200 status;
      Alcotest.(check int) "large tls stream body length" total
        (String.length body))

let test_https_server_h2_concurrent_large_echo () =
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
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/echo" ->
        Eta_http.Server.Body.read_all request.body
        |> Eta.Effect.map (fun body ->
               Eta_http.Server.Response.make ~status:200
                 ~body:(Eta_http.Server.Response.Body.fixed [ body ])
                 ())
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
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
      ~alpn_protocols:[ "h2" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  (* Each stream uploads a distinct fill byte so any cross-stream corruption in
     the concurrent TLS encrypt/decrypt path is detected. Payloads exceed the
     flow-control window so the server pumps reads and writes concurrently. *)
  let tags = [ 1; 2; 3 ] in
  let chunk_size = 16 * 1024 in
  let chunks_per_stream = 6 in
  let payload tag = String.make (chunk_size * chunks_per_stream) (Char.chr (Char.code 'A' + tag)) in
  let open_stream tag =
    let body_buf = Buffer.create (chunk_size * chunks_per_stream) in
    let status = ref 0 in
    let eof, resolve_eof = Eio.Promise.create () in
    let rec read_body response_body =
      Eta_http_h2.Body.Reader.schedule_read response_body
        ~on_eof:(fun () -> ignore (Eio.Promise.try_resolve resolve_eof ()))
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string body_buf (Bigstringaf.substring bs ~off ~len);
          read_body response_body)
    in
    let request : Eta_http_h2.Connection.Client.request =
      {
        meth = "POST";
        scheme = Some "https";
        authority = Some "localhost";
        path = "/echo";
        headers = [];
      }
    in
    match
      Eta_http_eio.H2.Connection.request connection ~tag request
        ~error_handler:(fun _stream error ->
          Alcotest.failf "stream %d failed: %a" tag
            Test_eta_http_h2_server.pp_h2_client_error error)
        ~response_handler:(fun _stream response response_body ->
          status := response.status;
          read_body response_body)
    with
    | Ok (opened : Eta_http_eio.H2.Multiplexer.opened_request) ->
        (tag, opened, body_buf, status, eof)
    | Error _ -> Alcotest.failf "stream %d not opened" tag
  in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let streams = List.map open_stream tags in
      for round = 0 to chunks_per_stream - 1 do
        List.iter
          (fun (tag, opened, _, _, _) ->
            let chunk =
              String.sub (payload tag) (round * chunk_size) chunk_size
            in
            ignore
              (Eta_http_h2.Body.Writer.write_string
                 opened.Eta_http_eio.H2.Multiplexer.request_body chunk))
          streams;
        Eio.Time.sleep clock 0.002
      done;
      List.iter
        (fun (_, opened, _, _, _) ->
          Eta_http_h2.Body.Writer.close
            opened.Eta_http_eio.H2.Multiplexer.request_body)
        streams;
      List.iter
        (fun (tag, _, body_buf, status, eof) ->
          Eio.Time.with_timeout_exn clock 10.0 (fun () ->
              Eio.Promise.await eof);
          Alcotest.(check int)
            (Printf.sprintf "stream %d status" tag)
            200 !status;
          Alcotest.(check bool)
            (Printf.sprintf "stream %d echo intact" tag)
            true
            (String.equal (Buffer.contents body_buf) (payload tag)))
        streams)

let test_https_server_h2_split_preface_settings_headers () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.close tls_flow with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Flow.write tls_flow
        [
          Cstruct.of_string
            ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
           ^ Eta_http_h2.Frame.settings);
        ];
      ignore
        (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
             Test_eta_http_h2_server.read_raw_until_h2_frame
               ~frame_type:Settings tls_flow)
          : string);
      let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
      let headers =
        Test_eta_http_h2_server.raw_h2_headers encoder ~end_stream:true
          ~stream_id:1
          [
            Test_eta_http_h2_server.hpack_header ":method" "GET";
            Test_eta_http_h2_server.hpack_header ":scheme" "https";
            Test_eta_http_h2_server.hpack_header ":path" "/split";
            Test_eta_http_h2_server.hpack_header ":authority" "localhost";
          ]
      in
      Eio.Flow.write tls_flow [ Cstruct.of_string headers ];
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
            Test_eta_http_h2_server.read_raw_until_h2_frame
              ~frame_type:Headers ~stream_id:1 tls_flow)
      in
      Alcotest.(check bool)
        "response HEADERS on stream 1" true
        (Test_eta_http_h2_server.raw_h2_has_frame ~stream_id:1 Headers
           response))

let test_https_server_h2_tiny_writes () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta_http.Server.Body.read_all request.body
    |> Eta.Effect.map (fun body ->
           Eta_http.Server.Response.text ("echo:" ^ Bytes.to_string body))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.close tls_flow with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
      let request =
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        ^ Eta_http_h2.Frame.settings
        ^ h2_settings_ack
        ^ Test_eta_http_h2_server.raw_h2_headers encoder ~end_stream:false
            ~stream_id:1
            [
              Test_eta_http_h2_server.hpack_header ":method" "POST";
              Test_eta_http_h2_server.hpack_header ":scheme" "https";
              Test_eta_http_h2_server.hpack_header ":path" "/echo";
              Test_eta_http_h2_server.hpack_header ":authority" "localhost";
            ]
        ^ Test_eta_http_h2_server.raw_h2_data ~end_stream:false ~stream_id:1
            "hello"
        ^ Test_eta_http_h2_server.raw_h2_data ~end_stream:true ~stream_id:1 ""
      in
      write_byte_by_byte tls_flow request;
      let response =
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            Test_eta_http_h2_server.read_raw_until_h2_frame
              ~frame_type:Data ~stream_id:1 tls_flow)
      in
      Alcotest.(check bool)
        "tiny writes response body" true
        (contains response "echo:hello"))

let test_https_server_h2_ping_churn_closes_connection () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let security_config =
    {
      Eta_http_h2.Security.default_config with
      ping_rate =
        {
          Eta_http_h2.Security.burst = 2;
          window_ms = 1_000;
          max_per_connection = None;
        };
    }
  in
  let config =
    {
      Eta_http_eio.Server.Config.default with
      h2_security_config = Some security_config;
    }
  in
  let handler_calls = ref 0 in
  let handler (request : Eta_http.Server.Request.t) =
    incr handler_calls;
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~config ~sw ~clock ~net ~cert ~key handler
  in
  let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.close tls_flow with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Flow.write tls_flow
        [
          Cstruct.of_string
            ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            ^ Eta_http_h2.Frame.settings
            ^ String.concat "" (List.init 3 (fun _ -> h2_ping "pingping")));
        ];
      let response =
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            Test_eta_http_h2_server.read_raw_until_h2_frame
              ~frame_type:Goaway tls_flow)
      in
      Alcotest.(check bool)
        "TLS/H2 ping churn sends GOAWAY" true
        (Test_eta_http_h2_server.raw_h2_has_frame Goaway response);
      Alcotest.(check int) "no request dispatched during churn" 0
        !handler_calls;
      assert_fresh_https_h2_request ~sw ~net ~clock ~cert port)

let test_https_server_h2_idle_timeout_sends_close_notify () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let timeouts =
    {
      Eta_http.Server.Config.default_timeouts with
      idle_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~config ~sw ~clock ~net ~cert ~key handler
  in
  let raw_flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let ssl = h2_openssl_client cert in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.close raw_flow with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      drive_openssl_client_handshake ~clock ssl raw_flow;
      write_openssl_client_plaintext ~clock ssl raw_flow
        ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
       ^ Eta_http_h2.Frame.settings);
      ignore
        (read_openssl_h2_until_frame ~clock ssl raw_flow Settings : string);
      let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
      let request =
        h2_settings_ack
        ^ Test_eta_http_h2_server.raw_h2_headers encoder ~end_stream:true
            ~stream_id:1
            [
              Test_eta_http_h2_server.hpack_header ":method" "GET";
              Test_eta_http_h2_server.hpack_header ":scheme" "https";
              Test_eta_http_h2_server.hpack_header ":path" "/idle-close";
              Test_eta_http_h2_server.hpack_header ":authority" "localhost";
            ]
      in
      write_openssl_client_plaintext ~clock ssl raw_flow request;
      ignore
        (read_openssl_h2_until_frame ~clock ssl raw_flow ~stream_id:1 Data
          : string);
      expect_openssl_client_close_notify ~clock ssl raw_flow)

let test_https_server_shutdown_during_handshake_keeps_listener_healthy () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Time.with_timeout_exn clock 2.0 (fun () ->
          let flow =
            Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
          in
          Fun.protect
            ~finally:(fun () -> try Eio.Flow.close flow with _ -> ())
            (fun () ->
              Eio.Flow.copy_string "GET / HTTP/1.1\r\nHost: localhost\r\n" flow;
              Eio.Flow.shutdown flow `Send;
              let scratch = Cstruct.create 1024 in
              try
                while true do
                  ignore (Eio.Flow.single_read flow scratch)
                done
              with End_of_file -> ()));
      assert_fresh_https_h2_request ~sw ~net ~clock ~cert port)

let test_https_server_shutdown_during_headers_keeps_listener_healthy () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Time.with_timeout_exn clock 2.0 (fun () ->
          let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
          Fun.protect
            ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
            (fun () ->
              Eio.Flow.copy_string
                ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
               ^ Eta_http_h2.Frame.settings
               ^ h2_settings_ack)
                tls_flow;
              let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
              let headers =
                Test_eta_http_h2_server.raw_h2_headers encoder ~stream_id:1
                  [
                    Test_eta_http_h2_server.hpack_header ":method" "GET";
                    Test_eta_http_h2_server.hpack_header ":scheme" "https";
                    Test_eta_http_h2_server.hpack_header ":path" "/partial";
                    Test_eta_http_h2_server.hpack_header ":authority" "localhost";
                  ]
              in
              Eio.Flow.copy_string (String.sub headers 0 5) tls_flow));
      assert_fresh_https_h2_request ~sw ~net ~clock ~cert port)

let test_https_server_shutdown_during_data_keeps_listener_healthy () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/partial" ->
        Eta_http.Server.Body.read_all request.body
        |> Eta.Effect.map (fun _ -> Eta_http.Server.Response.text "unexpected")
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Time.with_timeout_exn clock 2.0 (fun () ->
          let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
          Fun.protect
            ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
            (fun () ->
              let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
              Eio.Flow.copy_string
                ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                ^ Eta_http_h2.Frame.settings
                ^ h2_settings_ack
                ^ Test_eta_http_h2_server.raw_h2_headers encoder
                    ~end_stream:false ~stream_id:1
                    [
                      Test_eta_http_h2_server.hpack_header ":method" "POST";
                      Test_eta_http_h2_server.hpack_header ":scheme" "https";
                      Test_eta_http_h2_server.hpack_header ":path" "/partial";
                      Test_eta_http_h2_server.hpack_header ":authority"
                        "localhost";
                    ]
                ^ Eta_http_h2.Frame.header ~length:100 ~frame_type:Data ~flags:0
                    ~stream_id:1
                ^ "hello")
                tls_flow));
      assert_fresh_https_h2_request ~sw ~net ~clock ~cert port)

let test_https_server_h2_late_trailers_do_not_poison_accept_loop () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (_request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text "early\n")
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  let send_late_trailers () =
    let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
    Fun.protect
      ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
      (fun () ->
        Eio.Flow.write tls_flow
          [
            Cstruct.of_string
              ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
             ^ Eta_http_h2.Frame.settings);
          ];
        ignore
          (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
               Test_eta_http_h2_server.read_raw_until_h2_frame
                 ~frame_type:Settings tls_flow)
            : string);
        let encoder = Eta_http_h2.Hpack.encoder_create 4096 in
        let headers =
          Test_eta_http_h2_server.raw_h2_headers encoder ~end_stream:false
            ~stream_id:1
            [
              Test_eta_http_h2_server.hpack_header ":method" "POST";
              Test_eta_http_h2_server.hpack_header ":scheme" "https";
              Test_eta_http_h2_server.hpack_header ":path" "/early";
              Test_eta_http_h2_server.hpack_header ":authority" "localhost";
              Test_eta_http_h2_server.hpack_header "trailer" "x-check";
            ]
        in
        let data =
          Test_eta_http_h2_server.raw_h2_data ~stream_id:1 "test"
        in
        Eio.Flow.write tls_flow [ Cstruct.of_string (headers ^ data) ];
        ignore
          (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
               Test_eta_http_h2_server.read_raw_until_h2_frame
                 ~frame_type:Data ~stream_id:1 tls_flow)
            : string);
        let trailers =
          Test_eta_http_h2_server.raw_h2_headers encoder ~end_stream:true
            ~stream_id:1
            [ Test_eta_http_h2_server.hpack_header "x-check" "ok" ]
        in
        Eio.Flow.write tls_flow [ Cstruct.of_string trailers ])
  in
  let fresh_request () =
    let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
    let connection =
      Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
        ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
        ()
    in
    Fun.protect
      ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
      (fun () ->
        let request =
          h2_request ~scheme:"https"
            ~headers:( [ ":authority", "localhost" ])
            `GET "/fresh"
        in
        Test_eta_http_h2_server.await_h2_response connection request)
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      send_late_trailers ();
      let status, body =
        Eio.Time.with_timeout_exn clock 2.0 fresh_request
      in
      Alcotest.(check int) "fresh status" 200 status;
      Alcotest.(check string) "fresh body" "early\n" body)

let test_https_server_h2_parallel_gets_one_tls_connection () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  with_https_h2_connection ~cert ~key ~env ~sw handler
  @@ fun ~clock ~server:_ ~connection ->
  let open_stream tag =
    let status = ref None in
    let body = Buffer.create 16 in
    let eof, resolve_eof = Eio.Promise.create () in
    let rec read_body response_body =
      Eta_http_h2.Body.Reader.schedule_read response_body
        ~on_eof:(fun () -> ignore (Eio.Promise.try_resolve resolve_eof ()))
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring bs ~off ~len);
          read_body response_body)
    in
    let target = Printf.sprintf "/p%d" tag in
    let request : Eta_http_h2.Connection.Client.request =
      {
        meth = "GET";
        scheme = Some "https";
        authority = Some "localhost";
        path = target;
        headers = [];
      }
    in
    match
      Eta_http_eio.H2.Connection.request connection ~tag request
        ~error_handler:(fun _stream error ->
          Alcotest.failf "stream %d failed: %a" tag
            Test_eta_http_h2_server.pp_h2_client_error error)
        ~response_handler:(fun _stream response response_body ->
          status := Some response.status;
          read_body response_body)
    with
    | Ok opened ->
        Eta_http_h2.Body.Writer.close
          opened.Eta_http_eio.H2.Multiplexer.request_body;
        (tag, status, body, eof)
    | Error _ -> Alcotest.failf "stream %d not opened" tag
  in
  let streams = List.init 32 (fun index -> open_stream (index + 1)) in
  List.iter
    (fun (tag, status, body, eof) ->
      Eio.Time.with_timeout_exn clock 5.0 (fun () -> Eio.Promise.await eof);
      Alcotest.(check (option int))
        (Printf.sprintf "stream %d status" tag)
        (Some 200) !status;
      Alcotest.(check string)
        (Printf.sprintf "stream %d body" tag)
        (Printf.sprintf "ok:/p%d" tag)
        (Buffer.contents body))
    streams

let test_https_server_h2_timeout_does_not_poison_later_handshake () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let timeouts =
    {
      Eta_http.Server.Config.default.timeouts with
      handler_timeout = Some (Eta.Duration.ms 20);
    }
  in
  let server_config = { Eta_http.Server.Config.default with timeouts } in
  let config =
    { Eta_http_eio.Server.Config.default with server = server_config }
  in
  let handler (request : Eta_http.Server.Request.t) =
    match request.path with
    | "/slow" ->
        Eta.Effect.sync (fun () ->
            Eio.Time.sleep clock 1.0;
            Eta_http.Server.Response.text "late\n")
    | _ -> Eta.Effect.pure (Eta_http.Server.Response.text "ok\n")
  in
  let server, port =
    start_https_h2_test_server ~config ~sw ~clock ~net ~cert ~key handler
  in
  let one_request target =
    let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
    let connection =
      Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
        ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
        ()
    in
    Fun.protect
      ~finally:(fun () -> Eta_http_eio.H2.Connection.shutdown connection)
      (fun () ->
        let request =
          h2_request ~scheme:"https"
            ~headers:( [ ":authority", "localhost" ])
            `GET target
        in
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            Test_eta_http_h2_server.await_h2_response connection request))
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      let slow_status, slow_body = one_request "/slow" in
      Alcotest.(check int) "slow status" 503 slow_status;
      Alcotest.(check string) "slow body" "service unavailable\n" slow_body;
      let ok_status, ok_body = one_request "/ok" in
      Alcotest.(check int) "later status" 200 ok_status;
      Alcotest.(check string) "later body" "ok\n" ok_body)

let test_https_server_h2_repeated_connect_request_close () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Time.with_timeout_exn clock 15.0 (fun () ->
          for index = 1 to 50 do
            let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
            let connection =
              Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
                ~flow:(tls_flow :> Eta_http_eio.H2.Connection.flow)
                ()
            in
            Fun.protect
              ~finally:(fun () ->
                Eta_http_eio.H2.Connection.shutdown connection)
              (fun () ->
                let target = Printf.sprintf "/round-%d" index in
                let request =
                  h2_request ~scheme:"https"
                    ~headers:( [ ":authority", "localhost" ])
                    `GET target
                in
                let status, body =
                  Test_eta_http_h2_server.await_h2_response connection request
                in
                Alcotest.(check int) "status" 200 status;
                Alcotest.(check string) "body" ("ok:" ^ target) body)
          done))

let test_https_server_h2_goaway_ping_close_does_not_poison_accept_loop () =
  with_temp_tls_files @@ fun cert key ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
  in
  let server, port =
    start_https_h2_test_server ~sw ~clock ~net ~cert ~key handler
  in
  let send_goaway_ping_then_close () =
    let tls_flow = connect_https_h2_tls_flow ~sw ~net ~cert port in
    Fun.protect
      ~finally:(fun () -> try Eio.Flow.close tls_flow with _ -> ())
      (fun () ->
        Eio.Flow.write tls_flow
          [
            Cstruct.of_string
              ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
             ^ Eta_http_h2.Frame.settings);
          ];
        ignore
          (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
               Test_eta_http_h2_server.read_raw_until_h2_frame
                 ~frame_type:Settings tls_flow)
            : string);
        Eio.Flow.write tls_flow
          [
            Cstruct.of_string
              (h2_settings_ack
              ^ Eta_http_h2.Frame.goaway_no_error ~last_stream_id:0
              ^ h2_ping "h2spec\000\000");
          ])
  in
  Fun.protect
    ~finally:(fun () -> Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      Eio.Time.with_timeout_exn clock 2.0 send_goaway_ping_then_close;
      assert_fresh_https_h2_request ~sw ~net ~clock ~cert port)

let test_https_server_h1_keep_alive_sequential_requests () =
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
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  let closed_stats, resolve_closed_stats = Eio.Promise.create () in
  let on_connection_close = function
    | Eta_http_eio.Server.Https_h1 stats ->
        ignore (Eio.Promise.try_resolve resolve_closed_stats stats)
    | Eta_http_eio.Server.Https_h2 _ -> Alcotest.fail "H1 routed to H2"
  in
  let handler (request : Eta_http.Server.Request.t) =
    Eta.Effect.pure (Eta_http.Server.Response.text ("ok:" ^ request.path))
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
  let br = Eio.Buf_read.of_flow ~max_size:65536 tls_flow in
  let read_one_response () =
    let status_line = Eio.Buf_read.line br in
    let rec headers content_length =
      match Eio.Buf_read.line br with
      | "" -> content_length
      | line -> (
          match String.split_on_char ':' line with
          | name :: rest
            when String.lowercase_ascii (String.trim name) = "content-length"
            ->
              headers (int_of_string (String.trim (String.concat ":" rest)))
          | _ -> headers content_length)
    in
    let content_length = headers 0 in
    let body = Eio.Buf_read.take content_length br in
    (status_line, body)
  in
  Fun.protect
    ~finally:(fun () ->
      (try Eio.Flow.close tls_flow with _ -> ());
      Eta_http_eio.Server.shutdown server Immediate)
    (fun () ->
      (* Three keep-alive requests on a single TLS connection: this drives
         repeated read->write->read cycles over the TLS flow. *)
      List.iter
        (fun i ->
          let path = Printf.sprintf "/r%d" i in
          Eio.Flow.copy_string
            (Printf.sprintf "GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n" path)
            tls_flow;
          let status_line, body =
            Eio.Time.with_timeout_exn clock 2.0 (fun () -> read_one_response ())
          in
          Alcotest.(check bool)
            (Printf.sprintf "request %d status 200" i)
            true
            (String.length status_line >= 12
            && String.sub status_line 9 3 = "200");
          Alcotest.(check string)
            (Printf.sprintf "request %d body" i)
            (Printf.sprintf "ok:/r%d" i)
            body)
        [ 1; 2; 3 ];
      (try Eio.Flow.close tls_flow with _ -> ());
      let stats =
        Eio.Time.with_timeout_exn clock 2.0 (fun () ->
            Eio.Promise.await closed_stats)
      in
      Alcotest.(check int) "completed requests on one TLS connection" 3
        stats.completed_requests)

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

let test_https_server_shutdown_closes_pending_handshake () =
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
      tls_handshake_timeout = Eta.Duration.seconds 5;
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
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.close raw with _ -> ())
    (fun () ->
      let active_stats =
        wait_for_server_stats clock server (fun stats ->
            stats.active_connections = 1 && stats.opened_connections = 1)
      in
      Alcotest.(check int)
        "pending active connections" 1 active_stats.active_connections;
      Alcotest.(check int)
        "pending opened connections" 1 active_stats.opened_connections;
      Alcotest.(check int)
        "pending closed connections" 0 active_stats.closed_connections;
      Alcotest.(check int) "pending tls handshakes" 0 active_stats.tls_handshakes;
      Alcotest.(check int)
        "pending tls failures" 0 active_stats.tls_handshake_failures;
      Eta_http_eio.Server.shutdown server Immediate;
      let closed_stats =
        wait_for_server_stats clock server (fun stats ->
            stats.active_connections = 0 && stats.closed_connections = 1)
      in
      Alcotest.(check int)
        "closed active connections" 0 closed_stats.active_connections;
      Alcotest.(check int)
        "closed opened connections" 1 closed_stats.opened_connections;
      Alcotest.(check int)
        "closed closed connections" 1 closed_stats.closed_connections;
      Alcotest.(check bool) "handler not called" false !handler_called)

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

let test_https_server_strict_sni_rejects_unknown_name () =
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
      ~private_key_file:key ~require_sni_match:true
      ~alpn_protocols:[ "http/1.1" ] ()
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
  let unknown = Domain_name.(host_exn (of_string_exn "unknown.localhost")) in
  let client_config =
    Eta_http.Tls.Config.default_client ~peer_name:unknown ~ca_file:cert
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  let raw_flow =
    (raw :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let handshake_succeeded =
    try
      let tls_flow = Eta_http_eio.Tls.Eio.client_of_flow client_config raw_flow in
      Eio.Flow.close tls_flow;
      true
    with _ -> false
  in
  Alcotest.(check bool) "client handshake failed" false handshake_succeeded;
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
  (try Eio.Flow.close raw_flow with _ -> ());
  Eta_http_eio.Server.shutdown server Immediate

let test_https_server_start_rejects_invalid_tls_material () =
  with_temp_file "eta-http-bad-cert" "not a certificate" @@ fun bad ->
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let tls_config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:bad
      ~private_key_file:bad ~alpn_protocols:[ "http/1.1" ] ()
  in
  let handler _request =
    Eta.Effect.pure (Eta_http.Server.Response.text "unexpected\n")
  in
  Alcotest.check_raises "invalid TLS material fails before server handle"
    (Failure "SSL_CTX_use_certificate_chain_file failed")
    (fun () ->
      ignore
        (Eta_http_eio.Server.start_https_on_socket ~sw ~clock ~tls_config
           ~socket handler
          : Eta_http_eio.Server.t))

let test_openssl_server_ctx_rejects_invalid_cert () =
  with_temp_file "eta-http-bad-cert" "not a certificate" @@ fun bad ->
  Alcotest.check_raises "invalid cert"
    (Failure "SSL_CTX_use_certificate_chain_file failed") (fun () ->
      ignore
        (Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:bad
           ~private_key_file:bad ~alpn_protocols:[ "h2"; "http/1.1" ]
           ()
          : Eta_http_tls_openssl.ctx))

let test_openssl_server_ctx_rejects_invalid_key () =
  with_temp_file "eta-http-bad-key" "not a private key" @@ fun bad ->
  with_temp_file "eta-http-cert" tls_cert @@ fun cert ->
  Alcotest.check_raises "invalid key"
    (Failure "SSL_CTX_use_PrivateKey_file failed") (fun () ->
      ignore
        (Eta_http_tls_openssl.create_server_ctx ~certificate_chain_file:cert
           ~private_key_file:bad ~alpn_protocols:[ "h2"; "http/1.1" ]
           ()
          : Eta_http_tls_openssl.ctx))

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

let test_tls_eio_single_write_feeds_rbio_on_want_read () =
  let source = read_file (find_tls_eio_source ()) in
  let body = single_write_source source in
  match
    ( find_sub body ~needle:"if code = 2 (* SSL_ERROR_WANT_READ *)",
      find_sub body ~needle:"drive_want_read t epoch" )
  with
  | Some want_read_index, Some drive_index ->
      Alcotest.(check bool)
        "WANT_READ drives TLS input/progress" true
        (want_read_index < drive_index);
      (match find_sub_from body ~needle:"write_buf offset length" drive_index with
      | Some _ -> ()
      | None ->
          Alcotest.fail "WANT_READ does not retry the write after progress")
  | _ -> Alcotest.fail "single_write missing WANT_READ/drive/retry invariant"

let test_tls_eio_single_write_closed_flow_raises () =
  let source = read_file (find_tls_eio_source ()) in
  let body = single_write_source source in
  Alcotest.(check bool)
    "closed single_write raises" true
    (contains body "if t.closed then raise End_of_file");
  Alcotest.(check bool)
    "closed single_write does not report zero bytes" false
    (contains body "if t.closed then 0")

let test_tls_eio_single_write_races_raw_feed_with_tls_progress () =
  let source = read_file (find_tls_eio_source ()) in
  Alcotest.(check bool)
    "single_write still has no old rbio-only waiter" false
    (contains source "wait_for_rbio_progress");
  Alcotest.(check bool)
    "WANT_READ races raw feed with TLS progress" true
    (contains source "Eio.Fiber.first"
    && contains source "feed_bio_if_needed t epoch"
    && contains source "wait_for_tls_progress t epoch");
  Alcotest.(check bool)
    "successful SSL_read wakes TLS progress waiters" true
    (contains source "notify_tls_progress t")

let test_tls_eio_single_read_checks_pending_before_raw_read () =
  let source = read_file (find_tls_eio_source ()) in
  let body = single_read_source source in
  Alcotest.(check bool)
    "single_read must not spin on ssl_pending" false
    (contains body "Openssl.ssl_pending");
  match
    ( find_sub body ~needle:"if code = 2 (* SSL_ERROR_WANT_READ *)",
      find_sub body ~needle:"feed_bio t" )
  with
  | Some want_read_index, Some feed_index ->
      Alcotest.(check bool)
        "WANT_READ feeds the read BIO" true
        (want_read_index < feed_index)
  | _ -> Alcotest.fail "single_read missing WANT_READ/feed_bio invariant"
