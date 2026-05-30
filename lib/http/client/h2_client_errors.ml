(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module H2_proto = H2

let error request kind =
  Error.make ~protocol:Error.H2 ~method_:request.Request.method_
    ~uri:request.uri kind

let protocol_violation request kind message =
  error request (Connection_protocol_violation { kind; message })

let closed request during = error request (Connection_closed { during })

let pp_client_error = function
  | `Malformed_response message -> "malformed_response:" ^ message
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, message) ->
      Format.asprintf "protocol_error:%a:%s" H2_proto.Error_code.pp_hum code
        message
  | `Exn exn -> "exn:" ^ Printexc.to_string exn
