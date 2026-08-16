module Codec = Crux_codec

module Incarnation : sig
  type t

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_int64 : t -> int64
end

module Kind : sig
  type ('key, 'value) t
  type packed = Pack : ('key, 'value) t -> packed

  val define :
    name:string ->
    key_compare:('key -> 'key -> int) ->
    key_codec:'key Codec.t ->
    value_codec:'value Codec.t ->
    value_equal:('value -> 'value -> bool) ->
    cutoff:('value -> 'value -> bool) ->
    ('key, 'value) t

  val same : ('key, 'value) t -> ('other_key, 'other_value) t -> bool
  val name : ('key, 'value) t -> string
  val key_codec : ('key, 'value) t -> 'key Codec.t
  val value_codec : ('key, 'value) t -> 'value Codec.t
end

module Catalog : sig
  type t

  val create : Kind.packed list -> t
  val rank : t -> ('key, 'value) Kind.t -> int option
end

type preflight_error =
  | Unknown_kind
  | Identity_collision
  | Projection_capacity_exceeded
  | Incarnation_exhausted

type ('key, 'value) entry = {
  key : 'key;
  incarnation : Incarnation.t;
  value : 'value;
}

type ('key, 'value) update =
  | Attached of ('key, 'value) entry
  | Changed of ('key, 'value) entry
  | Removed of {
      key : 'key;
      incarnation : Incarnation.t;
    }

module Snapshot : sig
  type t

  val find_opt :
    ('key, 'value) Kind.t ->
    key:'key ->
    t ->
    ('key, 'value) entry option

  type packed_entry =
    | Pack :
        ('key, 'value) Kind.t * ('key, 'value) entry ->
        packed_entry

  val fold : t -> init:'acc -> f:('acc -> packed_entry -> 'acc) -> 'acc
end

module Batch : sig
  type t

  val find_opt :
    ('key, 'value) Kind.t ->
    key:'key ->
    t ->
    ('key, 'value) update list

  type packed_update =
    | Pack :
        ('key, 'value) Kind.t * ('key, 'value) update ->
        packed_update

  val fold : t -> init:'acc -> f:('acc -> packed_update -> 'acc) -> 'acc
  val target_snapshot : t -> Snapshot.t
end

type delivery =
  | Updates of Batch.t
  | Bootstrap of Snapshot.t

module Commit : sig
  type t

  val snapshot : t -> Snapshot.t
  val batch : t -> Batch.t
end

type occurrence
type candidate =
  | Candidate : {
      stamp : int;
      occurrence : occurrence;
      kind : ('key, 'value) Kind.t;
      key : 'key;
      value : 'value;
    } -> candidate

type candidates

val occurrence : unit -> occurrence

val candidate :
  occurrence:occurrence ->
  ('key, 'value) Kind.t ->
  key:'key ->
  'value ->
  candidate

val candidates_empty : candidates
val candidates_prepend : candidate -> candidates -> candidates
val candidates_append : candidates -> candidates -> candidates
val candidates_equal : candidates -> candidates -> bool
val candidates_replace :
  previous:candidates ->
  current:candidates ->
  candidates ->
  candidates

module State : sig
  type t
  type prepared

  val create : catalog:Catalog.t -> capacity:int -> t

  val prepare :
    t ->
    candidates ->
    (prepared, preflight_error) result

  val commit : prepared -> Commit.t
  val install : t -> prepared -> unit
  val set_next_incarnation_for_test : t -> int64 -> unit
end

val snapshot_of_delivery : delivery -> Snapshot.t
