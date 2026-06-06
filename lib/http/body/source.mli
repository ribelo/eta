(** Request-body source classification for replay and length policy. *)

type replayability = Replayable | Rewindable | One_shot

type t =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t);
    }

type owned_stream = {
  length : int option;
  stream : Stream.t;
}

val empty : t
val fixed : bytes list -> t
val stream : Stream.t -> t
val rewindable : ?length:int -> (unit -> Stream.t) -> t

val replayability : t -> replayability
val content_length : t -> int option
val to_stream : t -> Stream.t
val with_owned_stream :
  t ->
  (owned_stream option -> ('a, Error.t) Eta.Effect.t) ->
  ('a, Error.t) Eta.Effect.t
(** Run [f] with a stream that this scope owns. Streaming and rewindable bodies
    are discarded when the scope exits; fixed and empty bodies do not allocate a
    stream. *)
