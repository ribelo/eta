(** ADR 0002 TLS client configuration chokepoint. *)

val policy_version : Tls.Core.tls_version * Tls.Core.tls_version
(** The v1 policy offers TLS 1.2 only on the pinned 0.17.5 substrate. *)

val policy_ciphers : Tls.Ciphersuite.ciphersuite list
(** ECDHE RSA/ECDSA AEAD ciphers allowed by ADR 0002. *)

val default_alpn : string list
(** Client ALPN offer order: HTTP/2 first, HTTP/1.1 fallback. *)

val default_client :
  ?peer_name:[ `host ] Domain_name.t ->
  ?ip:Ipaddr.t ->
  ?alpn_protocols:string list ->
  authenticator:X509.Authenticator.t ->
  unit ->
  Tls.Config.client
(** Build the only supported eta-http client TLS config.

    The API intentionally exposes no [~version] or [~ciphers] override. *)
