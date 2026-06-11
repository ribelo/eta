(** Shared Eta HTTP Eio server statistics counters. *)

module Listener : sig
  type snapshot = {
    active_connections : int;
    opened_connections : int;
    closed_connections : int;
    tls_handshakes : int;
    tls_handshake_failures : int;
    alpn_h1 : int;
    alpn_h2 : int;
    alpn_rejected : int;
    listener_errors : int;
  }

  type t

  val create : unit -> t
  val opened_connection : t -> unit
  val closed_connection : t -> unit
  val tls_handshake : t -> unit
  val tls_handshake_failure : t -> unit
  val alpn_h1 : t -> unit
  val alpn_h2 : t -> unit
  val alpn_rejected : t -> unit
  val listener_error : t -> unit
  val snapshot : t -> active_connections:int -> snapshot
end

module H1 : sig
  type snapshot = {
    active_requests : int;
    completed_requests : int;
    request_bytes : int;
    response_bytes : int;
    protocol_errors : int;
  }

  type t

  val create : unit -> t
  val request_started : t -> unit
  val request_completed : t -> unit
  val add_request_bytes : t -> int -> unit
  val add_response_bytes : t -> int -> unit
  val protocol_error : t -> unit
  val snapshot : t -> snapshot
end

module H2 : sig
  type snapshot = {
    active_streams : int;
    opened_streams : int;
    completed_streams : int;
    reset_streams : int;
    request_bytes : int;
    response_bytes : int;
    protocol_errors : int;
  }

  type t

  val create : unit -> t
  val stream_opened : t -> unit
  val stream_completed : t -> unit
  val stream_reset : t -> unit
  val add_reset_streams : t -> int -> unit
  val add_request_bytes : t -> int -> unit
  val add_response_bytes : t -> int -> unit
  val protocol_error : t -> unit
  val snapshot : t -> active_streams:int -> snapshot
end
