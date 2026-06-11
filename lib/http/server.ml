(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Server_error
module Body = Server_body
module Config = Server_config
module Request = Server_request
module Response = Server_response

type handler = Request.t -> (Response.t, Error.t) Eta.Effect.t

module Handler = Server_handler
