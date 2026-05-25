(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

type target = {
  url : Eta_http_core.Url.t;
  scheme : Eta_http_core.Url.scheme;
  host : string;
  port : int;
  service : string;
}

type tcp_flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

let target_of_url url =
  let scheme = Eta_http_core.Url.scheme url in
  let port = Eta_http_core.Url.effective_port url in
  {
    url;
    scheme;
    host = Eta_http_core.Url.host url;
    port;
    service = string_of_int port;
  }

let dns_error ~method_ target message =
  Eta_http_error.Error.make ~method_ ~uri:(Eta_http_core.Url.to_string target.url)
    (Dns_error { host = target.host; message })

let connect_error ~method_ target message =
  Eta_http_error.Error.make ~method_ ~uri:(Eta_http_core.Url.to_string target.url)
    (Connect_error { message })

let tls_error ?(stage = Eta_http_error.Error.Tls_handshake) ~method_ target
    message =
  Eta_http_error.Error.make ~method_ ~uri:(Eta_http_core.Url.to_string target.url)
    (Tls_handshake_error { stage; message })

let tls_rng_initialized = Atomic.make false

let ensure_tls_rng_initialized () =
  if Atomic.get tls_rng_initialized then Ok ()
  else
    try
      (try ignore (Mirage_crypto_rng.generate 1)
       with _ ->
         Mirage_crypto_rng_unix.initialize (module Mirage_crypto_rng.Fortuna));
      Atomic.set tls_rng_initialized true;
      Ok ()
    with exn -> Error (Printexc.to_string exn)

let resolve_stream ~net ~method_ target =
  Effect.sync (fun () ->
      try Ok (Eio.Net.getaddrinfo_stream net target.host ~service:target.service)
      with exn -> Error (Printexc.to_string exn))
  |> Effect.bind (function
       | Ok (_ :: _ as addrs) -> Effect.pure addrs
       | Ok [] ->
           Effect.fail
             (dns_error ~method_ target "resolver returned no stream addresses")
       | Error message -> Effect.fail (dns_error ~method_ target message))

let set_nodelay flow =
  match Eio_unix.Resource.fd_opt flow with
  | None -> ()
  | Some fd ->
      Eio_unix.Fd.use fd
        (fun unix_fd -> Unix.setsockopt unix_fd Unix.TCP_NODELAY true)
        ~if_closed:(fun () -> ())

let connect_one ~sw ~net addr =
  try
    let flow = (Eio.Net.connect ~sw net addr :> tcp_flow) in
    set_nodelay flow;
    Ok flow
  with exn -> Error (Printexc.to_string exn)

let rec connect_first ~sw ~net errors = function
  | [] -> Error (String.concat "; " (List.rev errors))
  | addr :: rest -> (
      match connect_one ~sw ~net addr with
      | Ok flow -> Ok flow
      | Error message -> connect_first ~sw ~net (message :: errors) rest)

let connect_tcp ~sw ~net ~method_ target =
  resolve_stream ~net ~method_ target
  |> Effect.bind (fun addrs ->
         Effect.sync (fun () -> connect_first ~sw ~net [] addrs)
         |> Effect.bind (function
              | Ok flow -> Effect.pure flow
              | Error "" ->
                  Effect.fail
                    (connect_error ~method_ target "no stream address connected")
              | Error message ->
                  Effect.fail (connect_error ~method_ target message)))

let peer_identity target =
  match Ipaddr.of_string target.host with
  | Ok ip -> Ok (`Ip ip)
  | Error _ -> (
      match Domain_name.of_string target.host with
      | Error (`Msg message) -> Error message
      | Ok raw -> (
          match Domain_name.host raw with
          | Ok host -> Ok (`Host host)
          | Error (`Msg message) -> Error message))

let connect_tls ?alpn_protocols ~authenticator ~method_ target flow =
  let close_flow () =
    try Eio.Flow.close flow with _ -> ()
  in
  Effect.sync (fun () ->
      try
        match ensure_tls_rng_initialized () with
        | Error message -> Error ("TLS RNG initialization failed: " ^ message)
        | Ok () -> (
            match peer_identity target with
            | Error message -> Error message
            | Ok (`Host host) ->
                let config =
                  Eta_http_tls.Config.default_client ?alpn_protocols
                    ~authenticator ~peer_name:host ()
                in
                Ok (Tls_eio.client_of_flow config ~host flow)
            | Ok (`Ip ip) ->
                let config =
                  Eta_http_tls.Config.default_client ?alpn_protocols
                    ~authenticator ~ip ()
                in
                Ok (Tls_eio.client_of_flow config flow))
      with exn -> Error (Printexc.to_string exn))
  |> Effect.bind (function
       | Ok flow -> Effect.pure flow
       | Error message ->
           Effect.sync close_flow
           |> Effect.bind (fun () ->
                  Effect.fail (tls_error ~method_ target message)))

let negotiated_alpn ~method_ target flow =
  Effect.sync (fun () -> Tls_eio.epoch flow)
  |> Effect.bind (function
       | Ok epoch -> Effect.pure epoch.Tls.Core.alpn_protocol
       | Error () ->
           Effect.fail
             (tls_error ~stage:Alpn_negotiation ~method_ target
                "TLS epoch unavailable after handshake"))
