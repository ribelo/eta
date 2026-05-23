(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type protocol = H1 | H2

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
  request_impl : Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t;
  stats_impl : unit -> (stats, Eta_http_error.Error.t) Eta.Effect.t;
  shutdown_impl : unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t;
}

let protocol_to_string = function H1 -> "h1" | H2 -> "h2"
let protocol t = t.protocol
let stats t = t.stats_impl ()
let shutdown t = t.shutdown_impl ()
let request t req = t.request_impl req

let h1_body = function
  | Request.Empty -> Eta_http_h1.Client.Empty
  | Fixed chunks -> Eta_http_h1.Client.Fixed chunks

let h1_request_of_request request =
  match
    try Ok (Request.url request) with Invalid_argument message -> Error message
  with
  | Ok url ->
      Ok
        {
          Eta_http_h1.Client.method_ = request.Request.method_;
          url;
          headers = request.headers;
          body = h1_body request.body;
        }
  | Error message ->
      Error
        (Eta_http_error.Error.make ~method_:request.method_ ~uri:request.uri
           (Connection_protocol_violation { kind = "url"; message }))

let response_of_h1 (response : Eta_http_h1.Client.response) =
  Response.make ~status:response.Eta_http_h1.Client.status
    ~headers:response.headers ~body:response.body ()

let make_h1 ~sw ~net ~authenticator () =
  let pools = Hashtbl.create 8 in
  let pool_values () = Hashtbl.fold (fun _ pool acc -> pool :: acc) pools [] in
  let pool_for request =
    let key = Eta_http_h1.Client.origin_key request.Eta_http_h1.Client.url in
    match Hashtbl.find_opt pools key with
    | Some pool -> Eta.Effect.pure pool
    | None ->
        Eta_http_h1.Client.make_pool ~sw ~net ~authenticator request.url
        |> Eta.Effect.map (fun pool ->
               Hashtbl.replace pools key pool;
               pool)
  in
  let request_impl request =
    match h1_request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        pool_for request
        |> Eta.Effect.bind (fun pool ->
               Eta_http_h1.Client.request_with_pool pool request)
        |> Eta.Effect.map response_of_h1
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        pool_values ()
        |> List.fold_left
             (fun acc pool ->
               let stats = Eta_http_h1.Client.pool_stats pool in
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
    pool_values () |> List.map Eta_http_h1.Client.shutdown_pool |> Eta.Effect.concat
  in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }

let make_for_test ~protocol ~request ~stats ~shutdown =
  {
    protocol;
    request_impl = request;
    stats_impl = stats;
    shutdown_impl = shutdown;
  }
