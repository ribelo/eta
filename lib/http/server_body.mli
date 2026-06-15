(** Pull-based eta-http server request body. *)

type t

val empty : unit -> t

val of_reader :
  ?read_all:(max_bytes:int -> (bytes, Server_error.t) Eta.Effect.t) ->
  ?release:(unit -> (unit, Server_error.t) Eta.Effect.t) ->
  ?discard:(drain:bool -> (unit, Server_error.t) Eta.Effect.t) ->
  (unit -> (bytes option, Server_error.t) Eta.Effect.t) ->
  t
(** Build a body from an adapter-owned reader.

    [read] arms one upstream read and returns [None] at EOF. [release] runs
    once when EOF is reached or [read_all] finishes. [read_all], when supplied,
    reads the full adapter-owned body directly under the same single-operation
    and release contract. [discard] runs once when callers explicitly discard
    unread data. *)

val read : t -> (bytes option, Server_error.t) Eta.Effect.t

val read_all :
  ?max_bytes:int ->
  t ->
  (bytes, Server_error.t) Eta.Effect.t

val discard :
  ?drain:bool ->
  t ->
  (unit, Server_error.t) Eta.Effect.t
