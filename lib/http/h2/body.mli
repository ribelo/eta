(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 request/response bodies. *)

module Reader : sig
  type t

  type read_result =
    | Ok of Bigstringaf.t * int * int
    | Eof
    | Error of Error_code.t

  val create : unit -> t

  (** Internal: install the callback invoked when a chunk is delivered to the
      application. The connection uses this to release receive-window credit. *)
  val set_consume_fn : t -> (int -> unit) -> unit

  (** [is_closed t] is [true] once no further chunks can be read. A reader that
      has received EOF but still has buffered chunks is not closed until those
      chunks have been delivered. *)
  val is_closed : t -> bool

  (** [close t] discards unread chunks and wakes a pending reader with EOF. *)
  val close : t -> unit

  (** Internal: deliver a body chunk to the reader. *)
  val feed : t -> Bigstringaf.t -> off:int -> len:int -> unit

  (** Internal: signal end-of-body to the reader. Buffered chunks remain
      readable before EOF is delivered. *)
  val feed_eof : t -> unit

  (** [schedule_read t ~on_read ~on_eof] requests the next body chunk.
      [on_read] receives the buffer, offset, and length. The buffer is
      borrowed to the callback and must not be retained after the callback
      returns. At most one read may be scheduled at a time. *)
  val schedule_read :
    t -> on_read:(Bigstringaf.t -> off:int -> len:int -> unit) -> on_eof:(unit -> unit) -> unit
end

module Writer : sig
  type t

  val create : unit -> t
  val is_closed : t -> bool
  val close : t -> unit

  (** Internal: install the callback that consumes body data for transmission. *)
  val set_write_fn :
    t -> (Bigstringaf.t -> off:int -> len:int -> unit) -> unit

  (** Internal: install the callback invoked when the writer is closed. *)
  val set_close_callback : t -> (unit -> unit) -> unit

  (** Internal: install the callback that owns flush scheduling. *)
  val set_flush_fn : t -> ((unit -> unit) -> unit) -> unit

  (** Internal: invoke any pending flush callbacks. *)
  val run_flush_callbacks : t -> unit

  (** Write data to the body. The buffer is copied if it must outlive the
      call. Returns an error if the stream is closed or flow-controlled. *)
  val write_string : t -> string -> (unit, Error_code.t) result
  val write_bytes : t -> bytes -> off:int -> len:int -> (unit, Error_code.t) result
  val write_bigstring : t -> Bigstringaf.t -> off:int -> len:int -> (unit, Error_code.t) result

  (** [flush t f] invokes [f] once data accepted before the call has drained
      from the stream's HTTP/2 send queue. *)
  val flush : t -> (unit -> unit) -> unit
end
