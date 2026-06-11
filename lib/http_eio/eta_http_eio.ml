(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Client = Client
module Server = Server

let runtime_service ~sw ~net () =
  let clients = Hashtbl.create 4 in
  let mutex = Eio.Mutex.create () in
  let with_lock f =
    Eio.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) f
  in
  let selected_protocol options = options.Eta_http.Client.selected_protocol in
  let max_response_body_bytes options =
    options.Eta_http.Client.max_response_body_bytes
  in
  let ca_file options = options.Eta_http.Client.ca_file in
  let key options =
    (selected_protocol options, max_response_body_bytes options, ca_file options)
  in
  let protocol_unsupported request =
    Eta_http.Error.make ~method_:request.Eta_http.Request.method_
      ~uri:request.uri
      (Connection_protocol_violation
         {
           kind = "eio_http_service";
           message =
             "eta_http_eio runtime service does not implement forced HTTP/2; use Auto for ALPN dispatch";
         })
  in
  let make_client options =
    let max_response_body_bytes = max_response_body_bytes options in
    let ca_file = ca_file options in
    match selected_protocol options with
    | H1 ->
        Some
          (Client.make_h1 ~sw ~net ~max_response_body_bytes ?ca_file ())
    | Auto ->
        Some (Client.make ~sw ~net ~max_response_body_bytes ?ca_file ())
    | H2 -> None
  in
  let client_for options request =
    Eta.Effect.sync (fun () ->
        let key = key options in
        with_lock (fun () ->
            match Hashtbl.find_opt clients key with
            | Some client -> Ok client
            | None -> (
                match make_client options with
                | Some client ->
                    Hashtbl.add clients key client;
                    Ok client
                | None -> Error (protocol_unsupported request))))
    |> Eta.Effect.bind (function
         | Ok client -> Eta.Effect.pure client
         | Error error -> Eta.Effect.fail error)
  in
  let stats_for options =
    Eta.Effect.sync (fun () ->
        match Hashtbl.find_opt clients (key options) with
        | Some client -> Some client
        | None -> None)
    |> Eta.Effect.bind (function
         | Some client -> Client.stats client
         | None ->
             Eta.Effect.pure
               {
                 Eta_http.Client.protocol = selected_protocol options;
                 active = 0;
                 idle = 0;
                 capacity = 0;
                 opened = 0;
                 released = 0;
               })
  in
  let shutdown_for options =
    Eta.Effect.sync (fun () ->
        let key = key options in
        with_lock (fun () ->
            match Hashtbl.find_opt clients key with
            | None -> None
            | Some client ->
                Hashtbl.remove clients key;
                Some client))
    |> Eta.Effect.bind (function
         | None -> Eta.Effect.unit
         | Some client -> Client.shutdown client)
  in
  Eta_http.Client.runtime_service
    {
      Eta_http.Client.request =
        (fun options request ->
          client_for options request
          |> Eta.Effect.bind (fun client -> Client.request client request));
      stats = stats_for;
      shutdown = shutdown_for;
    }

module Tls = struct
  module Config = Eta_http.Tls.Config
  module Eio = Tls_eio
end

module Transport = struct
  module Alpn = Eta_http.Transport.Alpn
  module Alpn_server = Alpn_server
  module Connect = Connect
  module Dispatch = Eta_http.Transport.Dispatch
end

module H1 = struct
  module Client = H1_client
  module Parse = Eta_http.H1.Parse
  module Server_connection = H1_server_connection
  module Write = Write
end

module H2 = struct
  module Admission = Eta_http.H2.Admission
  module Connection = Connection
  module Frame = Eta_http.H2.Frame
  module Informational_filter = Eta_http.H2.Informational_filter
  module Multiplexer = Multiplexer
  module Server_connection = H2_server_connection
  module Security = Eta_http.H2.Security
  module Stream_state = Eta_http.H2.Stream_state
  module Writer = Writer
end

module Ws = struct
  module Client = Ws_client
  module Codec = Eta_http.Ws.Codec
end
