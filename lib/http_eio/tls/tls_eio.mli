(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Eio adapter for the OpenSSL TLS backend. *)

type config = Config.t
(** Client configuration. *)

type server_config = Config.server
(** Server configuration. *)

type epoch = {
  alpn_protocol : string option;
  sni : string option;
  peer_certificate_verified : bool;
}
(** Post-handshake metadata. *)

type flow =
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty | `Eta_tls ] Eio.Resource.t
(** An [Eio.Flow.two_way] backed by OpenSSL over an underlying flow. *)

module type EIO_FLOW = Eta_eio.Host.FLOW
(** Minimal host module shape needed by TLS flow hooks. *)

val client_of_flow :
  ?host_eio:Eta_eio.Host.t ->
  config ->
  ?host:[ `host ] Domain_name.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  flow
(** Wrap an existing TCP flow in TLS. Performs the handshake
    synchronously (blocking the fiber) before returning. *)

val server_of_flow :
  ?host_eio:Eta_eio.Host.t ->
  server_config ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  flow * epoch
(** Wrap an accepted TCP flow in server-side TLS. Performs the handshake
    synchronously (blocking the fiber) before returning the TLS flow and
    negotiated epoch. *)

val epoch : flow -> (epoch, unit) result
(** Extract the negotiated epoch. [Error ()] if the handshake has not
    completed or the flow is not a TLS flow. *)

val alpn_protocol : flow -> string option
(** Convenience: the negotiated ALPN protocol, if any. *)
