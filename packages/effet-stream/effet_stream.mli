(** Pull-based, chunked streams for Effet. *)

type +'a chunk = 'a list

module Stream : sig
  type ('env, 'err, 'a) t

  val empty : ('env, 'err, 'a) t
  val succeed : 'a -> ('env, 'err, 'a) t
  val from_chunk : 'a chunk -> ('env, 'err, 'a) t
  val from_iterable : 'a list -> ('env, 'err, 'a) t
  val from_effect : ('env, 'err, 'a) Effet.Effect.t -> ('env, 'err, 'a) t
  val fail : 'err -> ('env, 'err, 'a) t

  val map : ('a -> 'b) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
  val map_effect :
    ('a -> ('env, 'err, 'b) Effet.Effect.t) ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'b) t
  val filter : ('a -> bool) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val take : int -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val drop : int -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val scan : ('s -> 'a -> 's) -> 's -> ('env, 'err, 'a) t -> ('env, 'err, 's) t

  val concat :
    ('env, 'err, 'a) t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val flat_map :
    ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t

  val merge :
    ('env, 'err, 'a) t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val flat_map_par :
    max_concurrency:int ->
    ('a -> ('env, 'err, 'b) t) ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'b) t

  val from_eio_stream : 'a Eio.Stream.t -> ('env, 'err, 'a) t
  val from_file : _ Eio.Path.t -> ('env, 'err, bytes) t

  val named : string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val fn :
    string * int * int * int ->
    string ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'a) t
end

module Sink : sig
  type ('env, 'err, 'in_, 'out) t

  val fold :
    ('out -> 'in_ -> 'out) -> 'out -> ('env, 'err, 'in_, 'out) t
  val fold_effect :
    ('out -> 'in_ -> ('env, 'err, 'out) Effet.Effect.t) ->
    'out ->
    ('env, 'err, 'in_, 'out) t
  val collect_to_list : ('env, 'err, 'a, 'a list) t
  val count : ('env, 'err, 'a, int) t
  val drain : ('env, 'err, 'a, unit) t
end

val run :
  ('env, 'err, 'a) Stream.t ->
  ('env, 'err, 'a, 'b) Sink.t ->
  ('env, 'err, 'b) Effet.Effect.t

val run_collect :
  ('env, 'err, 'a) Stream.t -> ('env, 'err, 'a list) Effet.Effect.t

val run_drain : ('env, 'err, 'a) Stream.t -> ('env, 'err, unit) Effet.Effect.t
