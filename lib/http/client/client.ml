(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Connect = Connect
module Dispatch = Dispatch
module Error = Error
module Header = Header
module Url = Url
module H2_proto = H2

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type t = {
  protocol : protocol;
  request_impl : Request.t -> (Response.t, Error.t) Eta.Effect.t;
  stats_impl : unit -> (stats, Error.t) Eta.Effect.t;
  shutdown_impl : unit -> (unit, Error.t) Eta.Effect.t;
}

let protocol_to_string = function H1 -> "h1" | H2 -> "h2" | Auto -> "auto"
let default_max_response_body_bytes =
  H1_client.default_max_response_body_bytes

let protocol t = t.protocol
let stats t = t.stats_impl ()
let shutdown t = t.shutdown_impl ()
let request t req = t.request_impl req
let request_with_retry ?policy t req = Retry.run ?policy t.request_impl req

let request_url request =
  match Url.parse request.Request.uri with
  | Ok url -> Ok url
  | Error error ->
      Error
        (Error.make ~method_:request.Request.method_ ~uri:request.uri
           (Connection_protocol_violation
              { kind = "url"; message = Url.parse_error_to_string error }))

module H1 = struct
  let body = function
    | Request.Empty -> H1_client.Empty
    | Fixed chunks -> H1_client.Fixed chunks
    | Stream body -> H1_client.Stream body
    | Rewindable_stream { length; make } ->
        H1_client.Rewindable_stream { length; make }

  let request_of_request request =
    match request_url request with
    | Ok url ->
        Ok
          {
            H1_client.method_ = request.Request.method_;
            url;
            headers = request.headers;
            body = body request.body;
          }
    | Error _ as error -> error

  let response (response : H1_client.response) =
    Response.make ~status:response.H1_client.status
      ~headers:response.headers ~trailers:response.trailers ~body:response.body ()
end

module H2 = H2_client_request_runner

let request_h2_on_connection = H2.request_on_connection

let make_h1 ~sw ~net
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make_h1: max_response_body_bytes must be >= 0";
  let pools = Hashtbl.create 8 in
  let pool_values () = Hashtbl.fold (fun _ pool acc -> pool :: acc) pools [] in
  let pool_for request =
    let key = H1_client.origin_key request.H1_client.url in
    match Hashtbl.find_opt pools key with
    | Some pool -> Eta.Effect.pure pool
    | None ->
        H1_client.make_pool ~max_response_body_bytes ?ca_file ~sw ~net
          request.url
        |> Eta.Effect.map (fun pool ->
               Hashtbl.replace pools key pool;
               pool)
  in
  let request_impl request =
    match H1.request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        pool_for request
        |> Eta.Effect.bind (fun pool ->
               H1_client.request_with_pool pool request)
        |> Eta.Effect.map H1.response
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        pool_values ()
        |> List.fold_left
             (fun acc pool ->
               let stats = H1_client.pool_stats pool in
               {
                 protocol = H1;
                 active = acc.active + stats.Eta.Pool.active;
                 idle = acc.idle + stats.idle;
                 capacity = acc.capacity + stats.max_size;
                 opened = acc.opened + stats.opened;
                 released = acc.released + stats.closed;
               })
             {
               protocol = H1;
               active = 0;
               idle = 0;
               capacity = 0;
               opened = 0;
               released = 0;
             })
  in
  let shutdown_impl () =
    pool_values () |> List.map H1_client.shutdown_pool |> Eta.Effect.concat
  in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }

let make_h1_direct ~sw ~net ?host_eio
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg
      "Eta_http.Client.make_h1_direct: max_response_body_bytes must be >= 0";
  let request_impl request =
    match H1.request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        H1_client.request ~max_response_body_bytes ?host_eio ?ca_file ~sw ~net
          request
        |> Eta.Effect.map H1.response
  in
  let stats_impl () =
    Eta.Effect.pure
      {
        protocol = H1;
        active = 0;
        idle = 0;
        capacity = 0;
        opened = 0;
        released = 0;
      }
  in
  let shutdown_impl () = Eta.Effect.unit in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }

let run_host_h1 host_eio ~sw ~clock ~net ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace
    ?max_response_body_bytes ?ca_file f =
  Eta.Runtime.with_host_eio host_eio ~sw ~clock ?tracer ?sampler
    ?auto_instrument ?logger ?meter ?random ?island_pool ?blocking_pool
    ?capture_backtrace @@ fun runtime ->
  let client =
    make_h1_direct ~sw ~net ~host_eio ?max_response_body_bytes ?ca_file ()
  in
  Eta.Runtime.run runtime (f client)

(* ---------------------------------------------------------------- *)
(* Auto (ALPN-dispatch) client state and helpers                     *)
(*                                                                   *)
(* The make function below builds an explicit state record, then     *)
(* threads it through top-level helpers. This keeps the data flow    *)
(* visible: each helper's first parameter declares exactly which     *)
(* fields it touches, instead of hiding dependencies in a forest of  *)
(* closures over four mutable cells.                                 *)
(* ---------------------------------------------------------------- *)

type 'net auto_state = {
  sw : Eio.Switch.t;
  net : 'net;
  ca_file : string option;
  max_response_body_bytes : int;
  opened : int ref;
  released : int ref;
  last_protocol : protocol ref;
  h2_connections : (string, Connection.t) Hashtbl.t;
}

let h2_default_config =
  {
    H2_proto.Config.default with
    read_buffer_size = 131072;
    response_body_buffer_size = 131072;
    request_body_buffer_size = 131072;
  }

let h2_key target =
  Printf.sprintf "https://%s:%d" target.Connect.host target.port

let h2_connections_values state =
  Hashtbl.fold (fun _ connection acc -> connection :: acc) state.h2_connections []

let h2_connection_for state target =
  let key = h2_key target in
  match Hashtbl.find_opt state.h2_connections key with
  | Some connection when not (Connection.is_closed connection) -> Some connection
  | Some _ ->
      Hashtbl.remove state.h2_connections key;
      None
  | None -> None

let note_open state = Eta.Effect.sync (fun () -> incr state.opened)

let close_counted state flow =
  Eta.Effect.sync (fun () ->
      incr state.released;
      try Eio.Flow.close flow with _ -> ())

let h1_on_flow state flow request =
  match H1.request_of_request request with
  | Error error ->
      close_counted state flow
      |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
  | Ok h1_request ->
      H1_client.request_on_flow
        ~release:(fun () -> close_counted state flow)
        ~max_response_body_bytes:state.max_response_body_bytes ~flow h1_request
      |> Eta.Effect.map H1.response

let h2_on_connection state connection request url =
  state.last_protocol := H2;
  H2.request_on_connection connection request url

let h2_on_tls state target tls request url =
  let key = h2_key target in
  let connection =
    Connection.create ~sw:state.sw ~flow:(tls :> Connect.tcp_flow)
      ~config:h2_default_config ~reader_buffer_size:(512 * 1024)
      ~on_close:(fun () ->
        incr state.released;
        Hashtbl.remove state.h2_connections key)
      ()
  in
  Hashtbl.replace state.h2_connections key connection;
  h2_on_connection state connection request url

let dispatch_tls state target (tls, alpn) request url =
  Dispatch.dispatch_alpn
    ~close:(fun () -> close_counted state (tls :> Connect.tcp_flow))
    ~use_h1:(fun () ->
      state.last_protocol := H1;
      h1_on_flow state (tls :> Connect.tcp_flow) request)
    ~use_h2:(fun () -> h2_on_tls state target tls request url)
    request alpn

let auto_request_impl state request =
  match request_url request with
  | Error error -> Eta.Effect.fail error
  | Ok url -> (
      let target = Connect.target_of_url url in
      match (target.Connect.scheme, h2_connection_for state target) with
      | Https, Some connection -> h2_on_connection state connection request url
      | _ ->
          Connect.connect_tcp ~sw:state.sw ~net:state.net
            ~method_:request.method_ target
          |> Eta.Effect.bind (fun tcp ->
                 note_open state
                 |> Eta.Effect.bind (fun () ->
                        match target.Connect.scheme with
                        | Http ->
                            state.last_protocol := H1;
                            h1_on_flow state tcp request
                        | Https ->
                            Connect.connect_tls ?ca_file:state.ca_file
                              ~method_:request.method_ target tcp
                            |> Eta.Effect.bind (fun (tls, alpn) ->
                                   dispatch_tls state target (tls, alpn)
                                     request url))))

let auto_stats_impl state () =
  Eta.Effect.sync (fun () ->
      let h2_stats =
        h2_connections_values state
        |> List.fold_left
             (fun acc connection ->
               let stats = Connection.stats connection in
               {
                 acc with
                 active = acc.active + stats.active;
                 capacity = acc.capacity + stats.max_concurrent;
                 idle = acc.idle + 1;
               })
             {
               protocol = H2;
               active = 0;
               idle = 0;
               capacity = 0;
               opened = 0;
               released = 0;
             }
      in
      {
        protocol = !(state.last_protocol);
        active = h2_stats.active;
        idle = h2_stats.idle;
        capacity = h2_stats.capacity;
        opened = !(state.opened);
        released = !(state.released);
      })

let auto_shutdown_impl state () =
  Eta.Effect.sync (fun () ->
      h2_connections_values state |> List.iter Connection.shutdown;
      Hashtbl.clear state.h2_connections)

let make ~sw ~net
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make: max_response_body_bytes must be >= 0";
  let state =
    {
      sw;
      net;
      ca_file;
      max_response_body_bytes;
      opened = ref 0;
      released = ref 0;
      last_protocol = ref Auto;
      h2_connections = Hashtbl.create 8;
    }
  in
  {
    protocol = Auto;
    request_impl = auto_request_impl state;
    stats_impl = auto_stats_impl state;
    shutdown_impl = auto_shutdown_impl state;
  }

let make_custom ~protocol ~request ~stats ~shutdown =
  {
    protocol;
    request_impl = request;
    stats_impl = stats;
    shutdown_impl = shutdown;
  }
