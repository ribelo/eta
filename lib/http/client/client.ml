(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Error
module Request = Request
module Response = Response
module Retry = Retry

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type runtime_options = {
  selected_protocol : protocol;
  max_response_body_bytes : int;
  ca_file : string option;
}

type service = {
  request :
    runtime_options -> Request.t -> (Response.t, Error.t) Eta.Effect.t;
  stats : runtime_options -> (stats, Error.t) Eta.Effect.t;
  shutdown : runtime_options -> (unit, Error.t) Eta.Effect.t;
}

let service_key : service Eta.Runtime_contract.service_key =
  Eta.Runtime_contract.create_service_key ()

let runtime_service service =
  Eta.Runtime_contract.Service (service_key, service)

type t = {
  protocol : protocol;
  owner_domain : Domain.id;
  request_impl : Request.t -> (Response.t, Error.t) Eta.Effect.t;
  stats_impl : unit -> (stats, Error.t) Eta.Effect.t;
  shutdown_impl : unit -> (unit, Error.t) Eta.Effect.t;
}

let protocol_to_string = function
  | H1 -> "h1"
  | H2 -> "h2"
  | Auto -> "auto"

let default_max_response_body_bytes = Stream.default_max_bytes

let protocol t = t.protocol

let ensure_owner_domain t =
  if Domain.self () <> t.owner_domain then
    invalid_arg
      "Eta_http.Client: client used from a different domain; create and use each client on the same domain"

let stats t =
  ensure_owner_domain t;
  t.stats_impl ()

let shutdown t =
  ensure_owner_domain t;
  t.shutdown_impl ()

let request t req =
  ensure_owner_domain t;
  t.request_impl req

let request_with_retry ?policy t req =
  ensure_owner_domain t;
  Retry.run ?policy t.request_impl req

let runtime_service_error request =
  Error.make ~method_:request.Request.method_ ~uri:request.uri
    (Connection_protocol_violation
       {
         kind = "runtime_service";
         message = "missing eta-http runtime service";
       })

let runtime_service_effect ?request f =
  Eta.Effect.Expert.make ~leaf_name:"eta-http.runtime-service" (fun ctx ->
      match Eta.Effect.Expert.runtime_service ctx service_key with
      | Some service -> Eta.Effect.Expert.eval ctx (f service)
      | None ->
          let error =
            match request with
            | Some request -> runtime_service_error request
            | None ->
                Error.make ~method_:"*" ~uri:"*"
                  (Connection_protocol_violation
                     {
                       kind = "runtime_service";
                       message = "missing eta-http runtime service";
                     })
          in
          Eta.Effect.Expert.eval ctx (Eta.Effect.fail error))

let make_runtime ?(protocol = Auto)
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make_runtime: max_response_body_bytes must be >= 0";
  let options = { selected_protocol = protocol; max_response_body_bytes; ca_file } in
  let request_impl request =
    runtime_service_effect ~request (fun service ->
        service.request options request)
  in
  let stats_impl () =
    runtime_service_effect (fun service -> service.stats options)
  in
  let shutdown_impl () =
    runtime_service_effect (fun service -> service.shutdown options)
  in
  { protocol; owner_domain = Domain.self (); request_impl; stats_impl; shutdown_impl }

let make_custom ~protocol ~request ~stats ~shutdown =
  {
    protocol;
    owner_domain = Domain.self ();
    request_impl = request;
    stats_impl = stats;
    shutdown_impl = shutdown;
  }
