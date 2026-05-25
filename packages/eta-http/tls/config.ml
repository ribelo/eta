(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

let policy_version = (`TLS_1_2, `TLS_1_2)

let policy_ciphers =
  [
    "ECDHE-RSA-AES128-GCM-SHA256";
    "ECDHE-RSA-AES256-GCM-SHA384";
    "ECDHE-RSA-CHACHA20-POLY1305";
    "ECDHE-ECDSA-AES128-GCM-SHA256";
    "ECDHE-ECDSA-AES256-GCM-SHA384";
    "ECDHE-ECDSA-CHACHA20-POLY1305";
  ]

let default_alpn = [ "h2"; "http/1.1" ]

type t = {
  peer_name : [ `host ] Domain_name.t option;
  ip : Ipaddr.t option;
  alpn_protocols : string list;
}

let default_client ?peer_name ?ip ?(alpn_protocols = default_alpn) () =
  { peer_name; ip; alpn_protocols }

let peer_name t = t.peer_name
let ip t = t.ip
let alpn_protocols t = t.alpn_protocols
