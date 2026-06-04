(** RFC 6455 frame codec and handshake helpers. *)

type opcode : immutable_data = Continuation | Text | Binary | Close | Ping | Pong

type frame = {
  fin : bool;
  opcode : opcode;
  payload : bytes;
}

type parse_error : immutable_data =
  | Incomplete
  | Reserved_bits
  | Unsupported_opcode of int
  | Control_fragmented
  | Control_payload_too_large
  | Non_minimal_length
  | Mask_required
  | Mask_forbidden
  | Payload_too_large of int64

val parse_error_to_string : parse_error -> string
val opcode_to_int : opcode -> int
val opcode_of_int : int -> opcode option

val encode : ?mask:bytes -> frame -> bytes
(** Encode a frame. [mask], when present, must be exactly four bytes. *)

val decode : ?masked:bool -> bytes -> (frame * int, parse_error) result
(** Decode one frame from a byte buffer. [masked] defaults to [false], matching
    server-to-client frames. The returned integer is the number of bytes
    consumed. *)

val accept_key : string -> string
(** Compute [Sec-WebSocket-Accept] for a client key. *)

val random_key : unit -> string
(** Generate a base64-encoded 16-byte client key. *)
