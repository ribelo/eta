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
  ca_file : string option;
}

type server_certificate = {
  server_name : string;
  certificate_chain_file : string;
  private_key_file : string;
}

type server = {
  certificate_chain_file : string;
  private_key_file : string;
  server_certificates : server_certificate list;
  require_sni_match : bool;
  server_alpn_protocols : string list;
}

let default_client ?peer_name ?ip ?(alpn_protocols = default_alpn) ?ca_file () =
  { peer_name; ip; alpn_protocols; ca_file }

let server_certificate ~server_name ~certificate_chain_file ~private_key_file =
  { server_name; certificate_chain_file; private_key_file }

let default_server ?(alpn_protocols = default_alpn) ?(certificates = [])
    ?(require_sni_match = false) ~certificate_chain_file ~private_key_file () =
  {
    certificate_chain_file;
    private_key_file;
    server_certificates = certificates;
    require_sni_match;
    server_alpn_protocols = alpn_protocols;
  }

let peer_name t = t.peer_name
let ip t = t.ip
let alpn_protocols t = t.alpn_protocols
let ca_file t = t.ca_file
let server_certificate_name (t : server_certificate) = t.server_name
let server_certificate_chain_file (t : server_certificate) =
  t.certificate_chain_file

let server_certificate_private_key_file (t : server_certificate) =
  t.private_key_file
let certificate_chain_file t = t.certificate_chain_file
let private_key_file t = t.private_key_file
let server_certificates t = t.server_certificates
let require_sni_match t = t.require_sni_match
let server_alpn_protocols t = t.server_alpn_protocols
