open Eio.Std

type alpn_case =
  { name : string
  ; client_protocols : string list
  ; server_protocols : string list
  ; expected : string option
  }

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let null_auth ?ip:_ ~host:_ _ = Ok None

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let epoch_alpn flow =
  match Tls_eio.epoch flow with
  | Ok epoch -> epoch.Tls.Core.alpn_protocol
  | Error () -> failwith "TLS epoch unavailable"

let certificate_dir env =
  let open Eio.Path in
  Eio.Stdenv.cwd env
  / ".opam-oxcaml"
  / "5.2.0+ox"
  / ".opam-switch"
  / "sources"
  / "tls-eio.0.17.5"
  / "certificates"

let server_config env ~version ~alpn_protocols =
  let open Eio.Path in
  let dir = certificate_dir env in
  let certificate =
    X509_eio.private_of_pems
      ~cert:(dir / "server.pem")
      ~priv_key:(dir / "server.key")
  in
  Tls.Config.server
    ~version
    ~certificates:(`Single certificate)
    ~alpn_protocols
    ~ciphers:Tls.Config.Ciphers.supported
    ()

let client_config ~version ~alpn_protocols =
  Tls.Config.client
    ~version
    ~authenticator:null_auth
    ~alpn_protocols
    ~ciphers:Tls.Config.Ciphers.supported
    ()

let run_row env ~mode_name ~version case =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_alpn_p, server_alpn_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    let raw_flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
    let tls_flow =
      Tls_eio.server_of_flow
        (server_config env ~version ~alpn_protocols:case.server_protocols)
        raw_flow
    in
    let selected = epoch_alpn tls_flow in
    ignore (Eio.Promise.try_resolve server_alpn_u selected);
    Eio.Flow.copy_string "ok" tls_flow;
    Eio.Resource.close tls_flow);
  let client_alpn, payload =
    Eio.Switch.run @@ fun conn_sw ->
    let raw_flow =
      Eio.Net.connect
        ~sw:conn_sw
        net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let tls_flow =
      Tls_eio.client_of_flow
        (client_config ~version ~alpn_protocols:case.client_protocols)
        ~host:(host_exn "localhost")
        raw_flow
    in
    let selected = epoch_alpn tls_flow in
    let buf = Cstruct.create 2 in
    let n = Eio.Flow.single_read tls_flow buf in
    let payload = Cstruct.to_string (Cstruct.sub buf 0 n) in
    Eio.Resource.close tls_flow;
    selected, payload
  in
  let server_alpn = Eio.Promise.await server_alpn_p in
  if client_alpn <> case.expected then
    failwith
      (Printf.sprintf
         "%s/%s client ALPN expected %s got %s"
         mode_name
         case.name
         (Option.value ~default:"<none>" case.expected)
         (Option.value ~default:"<none>" client_alpn));
  if server_alpn <> case.expected then
    failwith
      (Printf.sprintf
         "%s/%s server ALPN expected %s got %s"
         mode_name
         case.name
         (Option.value ~default:"<none>" case.expected)
         (Option.value ~default:"<none>" server_alpn));
  if payload <> "ok" then failwith ("unexpected TLS payload: " ^ payload);
  Printf.printf
    "h_s2_alpn mode=%s min=%s max=%s config=%s selected=%s payload=%S\n%!"
    mode_name
    (string_of_tls_version (fst version))
    (string_of_tls_version (snd version))
    case.name
    (Option.value ~default:"<none>" client_alpn)
    payload

let modes =
  [ "tls12", (`TLS_1_2, `TLS_1_2)
  ; "tls13", (`TLS_1_3, `TLS_1_3)
  ; "tls12_to_tls13", (`TLS_1_2, `TLS_1_3)
  ]

let cases =
  [ { name = "server_prefers_h2"
    ; client_protocols = [ "http/1.1"; "h2" ]
    ; server_protocols = [ "h2"; "http/1.1" ]
    ; expected = Some "h2"
    }
  ; { name = "server_prefers_h1"
    ; client_protocols = [ "h2"; "http/1.1" ]
    ; server_protocols = [ "http/1.1"; "h2" ]
    ; expected = Some "http/1.1"
    }
  ]

let () =
  Eio_main.run @@ fun env ->
  List.iter
    (fun (mode_name, version) ->
      List.iter (run_row env ~mode_name ~version) cases)
    modes

