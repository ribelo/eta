(** Pull-based byte body stream for eta-http responses. *)

type t

type read_result = Chunk of bytes | Last of bytes | End

val empty : unit -> t
val of_bytes :
  ?release:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
  bytes list ->
  t
val of_reader :
  ?release:(unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t) ->
  (unit -> (read_result, Eta_http_error.Error.t) Eta.Effect.t) ->
  t

val default_max_bytes : int
(** Default maximum bytes accumulated by [read_all]. *)

val read : t -> (bytes option, Eta_http_error.Error.t) Eta.Effect.t
val read_all : ?max_bytes:int -> t -> (bytes, Eta_http_error.Error.t) Eta.Effect.t
(** Read the full stream into memory, failing with [Body_too_large] if more
    than [max_bytes] would be accumulated. *)
val discard : t -> (unit, Eta_http_error.Error.t) Eta.Effect.t
