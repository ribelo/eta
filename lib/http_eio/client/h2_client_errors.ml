(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module H2_proto = Eta_http_h2

let error request kind =
  Error.make ~protocol:Error.H2 ~method_:request.Request.method_
    ~uri:request.uri kind

let protocol_violation request kind message =
  error request (Connection_protocol_violation { kind; message })

let closed request during = error request (Connection_closed { during })

let pp_client_error (error : H2_proto.Connection.error) =
  Format.asprintf "protocol_error:%a:%s" H2_proto.Error_code.pp_hum
    error.error_code error.message
