(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

let policy_version = (`TLS_1_2, `TLS_1_2)

let policy_ciphers =
  [
    `ECDHE_RSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_RSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256;
    `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_ECDSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256;
  ]

let default_alpn = [ "h2"; "http/1.1" ]

let default_client ?peer_name ?ip ?(alpn_protocols = default_alpn)
    ~authenticator () =
  Tls.Config.client ~authenticator ?peer_name ?ip ~alpn_protocols
    ~version:policy_version ~ciphers:policy_ciphers ()
