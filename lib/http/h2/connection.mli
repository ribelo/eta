(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 connection state machine, for client and server use. *)

type t

type error = {
  error_code : Error_code.t;
  message : string;
}

type 'a iovec = {
  buffer : 'a;
  off : int;
  len : int;
}

type write_operation =
  | Write of Bigstringaf.t iovec list
  | Yield
  | Close of int

(** Feed network bytes into the connection. Returns the number of bytes accepted
    from the caller's buffer. The connection owns a bounded ingress buffer and
    may accept bytes even when a complete HTTP/2 frame is not yet available.
    Protocol errors are delivered through the configured error handler and move
    the connection into its closing state. *)
val read : t -> Bigstringaf.t -> off:int -> len:int -> int

(** Like [read] but signals transport EOF. If EOF arrives with a partial frame
    or continuation block buffered, the connection reports a protocol error;
    otherwise it stops accepting new streams and emits GOAWAY. Request body EOF
    is still driven by HTTP/2 END_STREAM, not by transport EOF. *)
val read_eof : t -> Bigstringaf.t -> off:int -> len:int -> int

(** Returns the next write operation to perform. The caller must drain the
    returned iovecs and then call [report_write_result]. *)
val next_write_operation : t -> write_operation

(** True when the connection already has serialized bytes waiting to be written
    to the transport. This does not run the stream scheduler. *)
val has_pending_write : t -> bool

(** Report the result of the last [Write] or [Close] operation. *)
val report_write_result : t -> [ `Ok of int | `Closed ] -> unit

(** Register a callback to be invoked when the connection would yield on
    writes (i.e., when there is no data to send right now but more may appear
    later). *)
val yield_writer : t -> (unit -> unit) -> unit

(** Initiate connection shutdown. *)
val shutdown : t -> unit

(** True when the connection is closing or closed because of a local shutdown
    or connection-level error. A peer GOAWAY can leave the connection draining
    existing streams while this remains false. *)
val is_closed : t -> bool

(** True while the connection can open locally initiated streams. This becomes
    false after peer GOAWAY, local shutdown, or connection-level close. *)
val accepts_new_streams : t -> bool

module Client : sig
  type connection = t

  type request = {
    meth : string;
    scheme : string option;
    authority : string option;
    path : string;
    headers : (string * string) list;
  }

  type response = {
    status : int;
    headers : (string * string) list;
    body : Body.Reader.t;
  }

  type error_handler = error -> unit
  type response_handler = Stream.id -> response -> unit
  type trailers_handler = (string * string) list -> unit

  val create :
    ?config:Settings.t ->
    ?push_handler:(request -> (response_handler, unit) result) ->
    error_handler:error_handler ->
    unit ->
    connection

  (** Open a new client stream. Returns the request body writer. The response
      (and any request failure) is delivered through callbacks. *)
  val request :
    connection ->
    stream_id:Stream.id ->
    ?end_stream:bool ->
    ?trailers_handler:trailers_handler ->
    request ->
    error_handler:(Stream.id -> error -> unit) ->
    response_handler:(Stream.id -> response -> unit) ->
    Body.Writer.t
end

module Server : sig
  type connection = t

  type request = {
    stream_id : int;
    meth : string;
    scheme : string;
    authority : string option;
    path : string;
    headers : (string * string) list;
    body : Body.Reader.t;
  }

  type response = {
    status : int;
    headers : (string * string) list;
    body : [ `Empty | `String of string | `Reader of Body.Reader.t ];
    trailers : (string * string) list Lazy.t;
  }

  (** Respond to a request. *)
  module Reqd : sig
    type t

    val request : t -> request
    val request_body : t -> Body.Reader.t

    val respond_with_string : t -> response -> string -> unit
    val respond_with_streaming : t -> response -> Body.Writer.t
    val schedule_trailers : t -> (string * string) list -> unit
    val report_exn : t -> exn -> unit
  end

  type request_handler = Reqd.t -> unit
  type error_handler = error -> unit

  val create :
    ?config:Settings.t ->
    request_handler:request_handler ->
    error_handler:error_handler ->
    unit ->
    connection
end
