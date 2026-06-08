open Eio.Std

type alpn_case =
  { server_name : string
  ; client_name : string
  ; server_protocols : string list
  ; client_protocols : string list
  ; expected : string option
  ; expect_reject : bool
  }

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let null_auth ?ip:_ ~host:_ _ = Ok None

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

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

let server_config env ~alpn_protocols =
  let open Eio.Path in
  let dir = certificate_dir env in
  let certificate =
    X509_eio.private_of_pems
      ~cert:(dir / "server.pem")
      ~priv_key:(dir / "server.key")
  in
  Tls.Config.server
    ~version:(`TLS_1_2, `TLS_1_3)
    ~certificates:(`Single certificate)
    ~alpn_protocols
    ~ciphers:Tls.Config.Ciphers.supported
    ()

let client_config ~alpn_protocols =
  Tls.Config.client
    ~version:(`TLS_1_2, `TLS_1_3)
    ~authenticator:null_auth
    ~alpn_protocols
    ~ciphers:Tls.Config.Ciphers.supported
    ()

let run_row env case =
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
    let selected =
      try
        Eio.Switch.run @@ fun conn_sw ->
        let raw_flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
        let tls_flow =
          Tls_eio.server_of_flow
            (server_config env ~alpn_protocols:case.server_protocols)
            raw_flow
        in
        let selected = epoch_alpn tls_flow in
        Eio.Flow.copy_string "ok" tls_flow;
        Eio.Resource.close tls_flow;
        selected
      with _exn -> None
    in
    ignore (Eio.Promise.try_resolve server_alpn_u selected));
  let observed =
    try
      Eio.Switch.run @@ fun conn_sw ->
      let raw_flow =
        Eio.Net.connect
          ~sw:conn_sw
          net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      let tls_flow =
        Tls_eio.client_of_flow
          (client_config ~alpn_protocols:case.client_protocols)
          ~host:(host_exn "localhost")
          raw_flow
      in
      let selected = epoch_alpn tls_flow in
      let buf = Cstruct.create 2 in
      let n = Eio.Flow.single_read tls_flow buf in
      let payload = Cstruct.to_string (Cstruct.sub buf 0 n) in
      Eio.Resource.close tls_flow;
      `Selected (selected, payload)
    with exn -> `Rejected (Printexc.to_string exn)
  in
  let server_alpn = Eio.Promise.await server_alpn_p in
  let selected =
    match observed with
    | `Selected (client_alpn, payload) ->
      if case.expect_reject then failwith "expected ALPN rejection";
      if client_alpn <> case.expected || server_alpn <> case.expected then
        failwith "unexpected ALPN selection";
      if payload <> "ok" then failwith ("unexpected TLS payload: " ^ payload);
      Option.value ~default:"<none>" client_alpn
    | `Rejected _error ->
      if not case.expect_reject then failwith "unexpected ALPN rejection";
      "rejected"
  in
  Printf.printf
    "h_s2_required_alpn server=%s client=%s selected=%s payload=%S\n%!"
    case.server_name
    case.client_name
    selected
    (match observed with `Selected (_, payload) -> payload | `Rejected _ -> "<none>")

let cases =
  [ { server_name = "h2_h1"
    ; client_name = "prefer_h2_fallback"
    ; server_protocols = [ "h2"; "http/1.1" ]
    ; client_protocols = [ "h2"; "http/1.1" ]
    ; expected = Some "h2"
    ; expect_reject = false
    }
  ; { server_name = "h2_h1"
    ; client_name = "require_h2"
    ; server_protocols = [ "h2"; "http/1.1" ]
    ; client_protocols = [ "h2" ]
    ; expected = Some "h2"
    ; expect_reject = false
    }
  ; { server_name = "h2_h1"
    ; client_name = "require_h1"
    ; server_protocols = [ "h2"; "http/1.1" ]
    ; client_protocols = [ "http/1.1" ]
    ; expected = Some "http/1.1"
    ; expect_reject = false
    }
  ; { server_name = "h1_only"
    ; client_name = "prefer_h2_fallback"
    ; server_protocols = [ "http/1.1" ]
    ; client_protocols = [ "h2"; "http/1.1" ]
    ; expected = Some "http/1.1"
    ; expect_reject = false
    }
  ; { server_name = "h1_only"
    ; client_name = "require_h2"
    ; server_protocols = [ "http/1.1" ]
    ; client_protocols = [ "h2" ]
    ; expected = None
    ; expect_reject = true
    }
  ; { server_name = "h1_only"
    ; client_name = "require_h1"
    ; server_protocols = [ "http/1.1" ]
    ; client_protocols = [ "http/1.1" ]
    ; expected = Some "http/1.1"
    ; expect_reject = false
    }
  ]

let () = Eio_main.run @@ fun env -> List.iter (run_row env) cases
