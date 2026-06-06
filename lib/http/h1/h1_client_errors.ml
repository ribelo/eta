(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta
open H1_client_types

module Error = Error
module Url = Url

let uri request = Url.to_string request.url

let make_error request kind =
  Error.make ~protocol:H1 ~method_:request.method_ ~uri:(uri request) kind

let protocol_violation request kind message =
  make_error request (Connection_protocol_violation { kind; message })

let io_closed request during =
  make_error request (Connection_closed { during })

let pool_context_error ~method_ ~uri = function
  | `Http error -> error
  | `Pool_shutdown | `Pool_shutdown_timeout ->
      Error.make ~protocol:H1 ~method_ ~uri Pool_shutdown
  | `Health_probe_timeout ->
      Error.make ~protocol:H1 ~method_ ~uri
        (Connection_protocol_violation
           { kind = "pool_health"; message = "health probe timed out" })

let map_http_error eff = Effect.catch (fun e -> Effect.fail (`Http e)) eff

let close_flow request flow =
  Effect.sync (fun () ->
      try Ok (Eio.Flow.close flow) with _ -> Error ())
  |> Effect.bind (function
       | Ok () -> Effect.unit
       | Error () -> Effect.fail (io_closed request Http_response))

let close_conn conn =
  Effect.sync (fun () ->
      try Eio.Flow.close conn.flow with _ -> ())

let parse_error request error =
  protocol_violation request "parse" (Parse.parse_error_to_string error)

let body_too_large request ~limit ~length =
  make_error request (Body_too_large { limit; length })
