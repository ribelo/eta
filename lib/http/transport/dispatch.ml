(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Protocol dispatch policy for negotiated HTTP transports. *)

type protocol : immutable_data = H1 | H2
type decision : immutable_data = Use_h1 | Use_h2

let protocol_to_string = function H1 -> "h1" | H2 -> "h2"
let decision_protocol = function Use_h1 -> H1 | Use_h2 -> H2

let decide_alpn alpn =
  match Alpn.protocol_of_alpn alpn with
  | Ok Alpn.H1 -> Ok Use_h1
  | Ok Alpn.H2 -> Ok Use_h2
  | Error protocol -> Error protocol

let unsupported_alpn request protocol =
  Error.make ~protocol:Error.Unknown ~method_:request.Request.method_
    ~uri:request.uri
    (Tls_handshake_error
       {
         stage = Alpn_negotiation;
         message = "unsupported ALPN protocol " ^ protocol;
       })

let dispatch_alpn ~close ~use_h1 ~use_h2 request alpn =
  match decide_alpn alpn with
  | Error protocol ->
      close ()
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.fail (unsupported_alpn request protocol))
  | Ok Use_h1 -> use_h1 ()
  | Ok Use_h2 -> use_h2 ()
