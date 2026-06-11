(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Server_error
module Request = Server_request
module Response = Server_response

type t = Request.t -> (Response.t, Error.t) Eta.Effect.t

let map_error f handler request = handler request |> Eta.Effect.map_error f

let default_reason = function
  | 400 -> "bad request\n"
  | 408 -> "request timeout\n"
  | 413 -> "request body too large\n"
  | 503 -> "service unavailable\n"
  | _ -> "internal server error\n"

let default_error_response error =
  let status = Option.value ~default:500 (Error.to_status error) in
  Response.text ~status (default_reason status)

let with_default_error_response ?(renderer = default_error_response) handler request =
  handler request
  |> Eta.Effect.catch (fun error -> Eta.Effect.pure (renderer error))

let route_not_found _request = Eta.Effect.pure (Response.text ~status:404 "not found\n")
