(** Small raw HTTP/2 frame helpers for tests and defensive probes. *)

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

type envelope = {
  length : int;
  frame_type : int;
  flags : int;
  stream_id : int;
}
(** Parsed HTTP/2 frame envelope. [stream_id] masks out the reserved high bit,
    matching RFC 9113 section 4.1. *)

val header_size : int
val frame_type_code : frame_type -> int
val parse_header_string : string -> off:int -> envelope
val parse_header_bytes : bytes -> off:int -> envelope
val parse_header_buffer : Buffer.t -> off:int -> envelope
val header : length:int -> frame_type:frame_type -> flags:int -> stream_id:int -> string
val uint32 : int -> string
val settings : string
val goaway_no_error : last_stream_id:int -> string
val payload : int -> string
