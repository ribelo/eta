(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Eio adapter for the OpenSSL TLS backend. *)

type config = Config.t
(** Client configuration. *)

type epoch = { alpn_protocol : string option }
(** Post-handshake metadata. *)

type flow =
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty | `Eta_tls ] Eio.Resource.t
(** An [Eio.Flow.two_way] backed by OpenSSL over an underlying flow. *)

module type EIO_FLOW = Eta.Host_eio.FLOW
(** Minimal host module shape needed by TLS flow hooks. *)

val client_of_flow :
  ?host_eio:Eta.Host_eio.t ->
  config ->
  ?host:[ `host ] Domain_name.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  flow
(** Wrap an existing TCP flow in TLS. Performs the handshake
    synchronously (blocking the fiber) before returning. *)

val epoch : flow -> (epoch, unit) result
(** Extract the negotiated epoch. [Error ()] if the handshake has not
    completed or the flow is not a TLS flow. *)

val alpn_protocol : flow -> string option
(** Convenience: the negotiated ALPN protocol, if any. *)
