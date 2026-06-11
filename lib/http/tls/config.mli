(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** ADR 0002 TLS client configuration chokepoint. *)

val policy_version : [ `TLS_1_2 ] * [ `TLS_1_2 ]
(** The v1 policy offers TLS 1.2 only on the OpenSSL substrate. *)

val policy_ciphers : string list
(** OpenSSL cipher names for the allowed ECDHE RSA/ECDSA AEAD ciphers. *)

val default_alpn : string list
(** Client ALPN offer order: HTTP/2 first, HTTP/1.1 fallback. *)

type t
(** Opaque client TLS configuration. *)

type server
(** Opaque server TLS configuration. *)

type server_certificate
(** A certificate chain and private key selected by SNI server name. *)

val default_client :
  ?peer_name:[ `host ] Domain_name.t ->
  ?ip:Ipaddr.t ->
  ?alpn_protocols:string list ->
  ?ca_file:string ->
  unit ->
  t
(** Build the only supported eta-http client TLS config.

    [ca_file] is an optional PEM file added to the trust store on top of
    the system roots. The API intentionally exposes no [~version] or
    [~ciphers] override. *)

val peer_name : t -> [ `host ] Domain_name.t option
val ip : t -> Ipaddr.t option
val alpn_protocols : t -> string list
val ca_file : t -> string option

val default_server :
  ?alpn_protocols:string list ->
  ?certificates:server_certificate list ->
  ?require_sni_match:bool ->
  certificate_chain_file:string ->
  private_key_file:string ->
  unit ->
  server
(** Build the supported eta-http server TLS config. The certificate chain
    and private key must be PEM files accepted by OpenSSL. [certificates] are
    selected by TLS SNI. [require_sni_match] aborts handshakes that omit SNI or
    send a name absent from [certificates]; leave it [false] when the default
    certificate should act as fallback. *)

val server_certificate :
  server_name:string ->
  certificate_chain_file:string ->
  private_key_file:string ->
  server_certificate
(** Build an SNI certificate entry. [server_name] is matched
    case-insensitively against the client's TLS SNI hostname. *)

val server_certificate_name : server_certificate -> string
val server_certificate_chain_file : server_certificate -> string
val server_certificate_private_key_file : server_certificate -> string
val certificate_chain_file : server -> string
val private_key_file : server -> string
val server_certificates : server -> server_certificate list
val require_sni_match : server -> bool
val server_alpn_protocols : server -> string list
