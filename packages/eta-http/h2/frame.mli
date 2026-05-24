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

val frame_type_code : frame_type -> int
val header : length:int -> frame_type:frame_type -> flags:int -> stream_id:int -> string
val uint32 : int -> string
val settings : string
val goaway_no_error : last_stream_id:int -> string
val payload : int -> string
