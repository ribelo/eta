(** Proposed public surface for [effet-stream].

    This is a research contract, not a compiled package interface yet.
    Streams are pull-based, chunked, scoped by the surrounding Effet runtime,
    and use the same [('env, 'err, 'a) Effect.t] channels as [Effet.Effect]. *)

type +'a chunk = 'a list
(** A non-empty batch of stream elements. The implementation should preserve
    non-empty chunks internally; the alias stays simple until a dedicated
    [Chunk] module earns its keep. *)

module Stream : sig
  type ('env, 'err, 'a) t
  (** A lazy stream that requires ['env], may fail with ['err], and emits ['a]. *)

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
  (** Run both streams under the interpreter's current [Eio.Switch]. The first
      failure cancels the sibling; if both fail before cancellation is observed,
      the runtime may report [Cause.Both]. *)

  val flat_map_par :
    max_concurrency:int ->
    ('a -> ('env, 'err, 'b) t) ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'b) t
  (** Like [flat_map], but evaluates inner streams concurrently with a bounded
      number of owned child fibers. *)

  val from_eio_stream :
    ?capacity:int -> 'a Eio.Stream.t -> ('env, 'err, 'a) t
  (** Pull values from an existing [Eio.Stream.t]. Cancellation stops this
      stream's consumer; ownership of the source queue remains with the caller. *)

  val from_file : _ Eio.Path.t -> ('env, 'err, bytes) t
  (** Byte-level source. The file descriptor is acquired with [Effect.acquire_release]
      and closes on normal completion, early [take], failure, or cancellation. *)

  val named : string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val fn :
    string * int * int * int ->
    string ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'a) t
  (** Open one runtime tracer span per pulled chunk, not per element. *)
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

(** [Channel] is internal in v0. It remains a design concept for implementing
    stream/sink transducers, but it is not a public type until an OCaml example
    needs bidirectional input, input errors, and a terminal input value. *)
