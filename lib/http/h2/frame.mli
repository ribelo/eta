(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 frame types and envelope helpers, per RFC 9113 section 6. *)

type frame_type =
  | Data
  | Headers
  | Priority
  | Rst_stream
  | Settings
  | Push_promise
  | Ping
  | Goaway
  | Window_update
  | Continuation
  | Other of int

val frame_type_code : frame_type -> int
val frame_type_of_code : int -> frame_type

module Flags : sig
  type t = int

  val empty : t
  val end_stream : t
  val ack : t
  val end_headers : t
  val padded : t
  val priority : t
  val has : t -> t -> bool
  val ( + ) : t -> t -> t
end

type envelope = {
  length : int;
  frame_type : int;
  flags : int;
  stream_id : int;
}

val header_size : int

(** Parse a frame envelope from a buffer. Returns [None] if fewer than
    [header_size] bytes are available. *)
val parse_envelope : Bigstringaf.t -> off:int -> len:int -> envelope option

(** Validate an envelope against protocol limits. *)
val validate_envelope : envelope -> max_frame_size:int -> (unit, Error_code.t) result

(** Serialize a frame envelope. [buf] must have at least [header_size] bytes
    available at [off]. *)
val serialize_envelope : buf:bytes -> off:int -> length:int -> frame_type:frame_type -> flags:Flags.t -> stream_id:int -> unit

(** Serialize a frame envelope as a [string]. *)
val header : length:int -> frame_type:frame_type -> flags:Flags.t -> stream_id:int -> string

(** Serialize an unsigned 32-bit integer as a big-endian [string]. *)
val uint32 : int -> string

(** Serialize the fixed 8-byte GOAWAY payload for [last_stream_id] and
    [NO_ERROR]. *)
val goaway_no_error : last_stream_id:int -> string

(** A pre-serialized empty SETTINGS frame. *)
val settings : string

(** [payload len] returns a string of [len] NUL bytes. *)
val payload : int -> string

(** Parse a frame envelope from a [bytes] buffer. Raises [Invalid_argument] if
    fewer than [header_size] bytes are available. *)
val parse_header_bytes : bytes -> off:int -> envelope

(** Parse a frame envelope from a [Buffer.t]. Raises [Invalid_argument] if
    fewer than [header_size] bytes are available. *)
val parse_header_buffer : Buffer.t -> off:int -> envelope

(** Parse a frame envelope from a [string]. Raises [Invalid_argument] if
    fewer than [header_size] bytes are available. *)
val parse_header_string : string -> off:int -> envelope

(** Payload decoders. Each returns the payload and the number of payload bytes
    consumed (which is always [envelope.length] on success). *)

module Data : sig
  type t = {
    data : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Headers : sig
  type priority = {
    exclusive : bool;
    stream_dependency : int;
    weight : int;
  }

  type t = {
    priority : priority option;
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  val default_priority : priority
  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Priority : sig
  type t = Headers.priority

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Rst_stream : sig
  type t = { error_code : Error_code.t }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Settings : sig
  type setting =
    | Header_table_size of int
    | Enable_push of bool
    | Max_concurrent_streams of int
    | Initial_window_size of int
    | Max_frame_size of int
    | Max_header_list_size of int

  type t = setting list

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Ping : sig
  type t = { payload : bytes }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Goaway : sig
  type t = {
    last_stream_id : int;
    error_code : Error_code.t;
    debug_data : Bigstringaf.t;
    off : int;
    len : int;
  }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Window_update : sig
  type t = { window_size_increment : int }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t * bool) result
  (** The boolean is [true] when the error is stream-level per RFC 9113. *)
end

module Push_promise : sig
  type t = {
    promised_stream_id : int;
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end

module Continuation : sig
  type t = {
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
  }

  val decode : Bigstringaf.t -> off:int -> envelope:envelope -> (t, Error_code.t) result
end
