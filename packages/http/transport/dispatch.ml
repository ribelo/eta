(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Protocol dispatch policy for negotiated HTTP transports. *)

type protocol = H1 | H2
type decision = Use_h1 | Use_h2

let protocol_to_string = function H1 -> "h1" | H2 -> "h2"
let decision_protocol = function Use_h1 -> H1 | Use_h2 -> H2

let decide_alpn alpn =
  match Alpn.protocol_of_alpn alpn with
  | Ok Alpn.H1 -> Ok Use_h1
  | Ok Alpn.H2 -> Ok Use_h2
  | Error protocol -> Error protocol
