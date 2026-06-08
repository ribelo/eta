type +'a chunk = 'a list


module Stream : sig
  type ('a, 'err) t

  val empty : ('a, 'err) t
  val succeed : 'a -> ('a, 'err) t
  val from_chunk : 'a chunk -> ('a, 'err) t
  val from_iterable : 'a list -> ('a, 'err) t
  val range : start:int -> stop:int -> (int, 'err) t
  val from_effect : ('a, 'err) Eta_js.Effect.t -> ('a, 'err) t
  val fail : 'err -> ('a, 'err) t
  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val map_effect : ('a -> ('b, 'err) Eta_js.Effect.t) -> ('a, 'err) t -> ('b, 'err) t
  val filter : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  val take : int -> ('a, 'err) t -> ('a, 'err) t
  val drop : int -> ('a, 'err) t -> ('a, 'err) t
  val scan : ('s -> 'a -> 's) -> 's -> ('a, 'err) t -> ('s, 'err) t
  val grouped : int -> ('a, 'err) t -> ('a list, 'err) t
  val concat : ('a, 'err) t -> ('a, 'err) t -> ('a, 'err) t
  val flat_map : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
end

module Sink : sig
  type ('in_, 'out, 'err) t

  val fold : ('out -> 'in_ -> 'out) -> 'out -> ('in_, 'out, 'err) t
  val fold_effect : ('out -> 'in_ -> ('out, 'err) Eta_js.Effect.t) -> 'out -> ('in_, 'out, 'err) t
  val collect_to_list : ('a, 'a list, 'err) t
  val count : ('a, int, 'err) t
  val drain : ('a, unit, 'err) t
end

val run : ('a, 'err) Stream.t -> ('a, 'b, 'err) Sink.t -> ('b, 'err) Eta_js.Effect.t
val run_collect : ('a, 'err) Stream.t -> ('a list, 'err) Eta_js.Effect.t
val run_drain : ('a, 'err) Stream.t -> (unit, 'err) Eta_js.Effect.t
