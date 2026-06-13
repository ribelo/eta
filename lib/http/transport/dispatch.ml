(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Protocol dispatch policy for negotiated HTTP transports. *)

type protocol = H1 | H2
type decision = Use_h1 | Use_h2
type enabled_protocols = { h1 : bool; h2 : bool }
type alpn_error = Missing_alpn | Unsupported_alpn of string

let protocol_to_string = function H1 -> "h1" | H2 -> "h2"
let decision_protocol = function Use_h1 -> H1 | Use_h2 -> H2

let enabled_protocols ~h1 ~h2 = { h1; h2 }
let mixed_protocols = { h1 = true; h2 = true }

let enabled_protocols_of_alpn_protocols protocols =
  let rec loop enabled = function
    | [] -> enabled
    | "http/1.1" :: rest -> loop { enabled with h1 = true } rest
    | "h2" :: rest -> loop { enabled with h2 = true } rest
    | _ :: rest -> loop enabled rest
  in
  loop { h1 = false; h2 = false } protocols

let alpn_error_to_string = function
  | Missing_alpn -> "missing ALPN protocol"
  | Unsupported_alpn protocol -> protocol

let alpn_error_message = function
  | Missing_alpn -> "missing ALPN protocol"
  | Unsupported_alpn protocol -> "unsupported ALPN protocol " ^ protocol

let decide_alpn ~enabled_protocols alpn =
  match alpn with
  | None when enabled_protocols.h1 -> Ok Use_h1
  | None -> Error Missing_alpn
  | Some "http/1.1" when enabled_protocols.h1 -> Ok Use_h1
  | Some "h2" when enabled_protocols.h2 -> Ok Use_h2
  | Some protocol -> Error (Unsupported_alpn protocol)

let unsupported_alpn request error =
  Error.make ~protocol:Error.Unknown ~method_:request.Request.method_
    ~uri:request.uri
    (Tls_handshake_error
       { stage = Alpn_negotiation; message = alpn_error_message error })

let dispatch_alpn ~enabled_protocols ~close ~use_h1 ~use_h2 request alpn =
  match decide_alpn ~enabled_protocols alpn with
  | Error error ->
      close ()
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.fail (unsupported_alpn request error))
  | Ok Use_h1 -> use_h1 ()
  | Ok Use_h2 -> use_h2 ()
