(** Pull-based byte body stream for eta-http responses. *)

type t
(** One-shot body stream.

    A stream permits one active operation at a time. Concurrent [read],
    [read_all], or [discard] calls fail with a typed [Decode_error] instead of
    racing the mutable stream state. *)

type read_result = Chunk of bytes | Last of bytes | End

val empty : unit -> t
val of_bytes :
  ?release:(unit -> (unit, Error.t) Eta.Effect.t) ->
  bytes list ->
  t
val of_reader :
  ?release:(unit -> (unit, Error.t) Eta.Effect.t) ->
  (unit -> (read_result, Error.t) Eta.Effect.t) ->
  t

val default_max_bytes : int
(** Default maximum bytes accumulated by [read_all]. *)

val read : t -> (bytes option, Error.t) Eta.Effect.t
val read_all : ?max_bytes:int -> t -> (bytes, Error.t) Eta.Effect.t
(** Read the full stream into memory, failing with [Body_too_large] if more
    than [max_bytes] would be accumulated. *)
val discard : t -> (unit, Error.t) Eta.Effect.t
