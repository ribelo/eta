(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

type target = {
  url : Url.t;
  scheme : Url.scheme;
  host : string;
  port : int;
  service : string;
}

type tcp_flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

module type EIO_NET = Eta_eio.Host.NET

module Default_eio_net : EIO_NET = Eio.Net

let target_of_url url =
  let scheme = Url.scheme url in
  let port = Url.effective_port url in
  {
    url;
    scheme;
    host = Url.host url;
    port;
    service = string_of_int port;
  }

let dns_error ~method_ target message =
  Error.make ~method_ ~uri:(Url.to_string target.url)
    (Dns_error { host = target.host; message })

let connect_error ~method_ target message =
  Error.make ~method_ ~uri:(Url.to_string target.url)
    (Connect_error { message })

let tls_error ?(stage = Error.Tls_handshake) ~method_ target
    message =
  Error.make ~method_ ~uri:(Url.to_string target.url)
    (Tls_handshake_error { stage; message })

let protect_eio_cancel f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let net_module = function
  | None -> (module Default_eio_net : EIO_NET)
  | Some host_eio ->
      let module Net = (val Eta_eio.Host.net host_eio : Eta_eio.Host.NET) in
      (module Net : EIO_NET)

let resolve_stream ?host_eio ~net ~method_ target =
  let module Net = (val net_module host_eio : EIO_NET) in
  Effect.sync (fun () ->
      protect_eio_cancel (fun () ->
          Net.getaddrinfo_stream net target.host ~service:target.service))
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

let connect_one (module Net : EIO_NET) ~sw ~net addr =
  protect_eio_cancel (fun () ->
    let flow = (Net.connect ~sw net addr :> tcp_flow) in
    set_nodelay flow;
    flow)

let rec connect_first eio_net ~sw ~net errors = function
  | [] -> Error (String.concat "; " (List.rev errors))
  | addr :: rest -> (
      match connect_one eio_net ~sw ~net addr with
      | Ok flow -> Ok flow
      | Error message -> connect_first eio_net ~sw ~net (message :: errors) rest)

let connect_tcp ?host_eio ~sw ~net ~method_ target =
  let eio_net = net_module host_eio in
  resolve_stream ?host_eio ~net ~method_ target
  |> Effect.bind (fun addrs ->
         Effect.sync (fun () -> connect_first eio_net ~sw ~net [] addrs)
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

let connect_tls ?host_eio ?alpn_protocols ?ca_file ~method_ target flow =
  let close_flow () =
    try Eio.Flow.close flow with _ -> ()
  in
  Effect.sync (fun () ->
      try
        match peer_identity target with
        | Error message -> Error message
        | Ok (`Host host) ->
            let config =
              Config.default_client ?alpn_protocols ?ca_file
                ~peer_name:host ()
            in
            let tls = Tls_eio.client_of_flow ?host_eio config ~host flow in
            let alpn = Tls_eio.alpn_protocol tls in
            Ok (tls, alpn)
        | Ok (`Ip ip) ->
            let config =
              Config.default_client ?alpn_protocols ?ca_file ~ip ()
            in
            let tls = Tls_eio.client_of_flow ?host_eio config flow in
            let alpn = Tls_eio.alpn_protocol tls in
            Ok (tls, alpn)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn))
  |> Effect.bind (function
       | Ok (flow, alpn) -> Effect.pure ((flow :> tcp_flow), alpn)
       | Error message ->
           Effect.sync close_flow
           |> Effect.bind (fun () ->
                  Effect.fail (tls_error ~method_ target message)))
