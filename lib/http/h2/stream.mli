(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Per-stream HTTP/2 state. *)

type id = int

type state =
  | Idle
  | Reserved_local
  | Reserved_remote
  | Open
  | Half_closed_local
  | Half_closed_remote
  | Closed

type error =
  | Stream_closed
  | Protocol_violation of string
  | Flow_control_violation of string

type t

val create : id:id -> initial_send_window:int -> initial_recv_window:int -> t
val total_pending : t -> int
val notify_drained : t -> unit
val on_drained : t -> (unit -> unit) -> unit
val id : t -> id
val state : t -> state
val is_open : t -> bool
val is_closed : t -> bool
val send_end_stream : t -> bool
val sent_end_stream : t -> bool
val recv_end_stream : t -> bool

(** The request body reader for an inbound stream. *)
val request_body : t -> Body.Reader.t

(** Stream-level flow-control windows. *)
val send_window : t -> Window.t
val recv_window : t -> Window.t

(** Record request-body bytes delivered to the application. Returns the number
    of bytes that should be advertised with WINDOW_UPDATE when the stream's
    unannounced credit reaches the available-window threshold. *)
val note_recv_window_consumed : t -> int -> int option

(** Queue a DATA chunk for transmission. The chunk must be accounted against
    the stream and connection send windows before calling. *)
val queue_data : t -> Bigstringaf.t -> off:int -> len:int -> (unit, error) result

(** Mark the stream as having sent/received END_STREAM. *)
val mark_send_end_stream : t -> unit
val mark_sent_end_stream : t -> unit
val mark_recv_end_stream : t -> unit

(** Trailing response headers queued for the stream. *)
val set_trailers : t -> (string * string) list -> unit
val has_trailers : t -> bool
val take_trailers : t -> (string * string) list option

(** RST_STREAM handling. *)
val reset : t -> error_code:Error_code.t -> unit
val reset_by_peer : t -> error_code:Error_code.t -> unit

(** Take pending DATA frames for the scheduler/write loop, bounded by the
    stream send window and the caller's maximum chunk size. *)
val take_pending_data : t -> max_len:int -> (Bigstringaf.t * int * int) option
