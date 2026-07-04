(** Dynamic scope state for Eta_signal internals. *)

type ('id, 'owner, 'node) t

val create :
  id:'id ->
  owner:'owner ->
  parent:('id, 'owner, 'node) t option ->
  ('id, 'owner, 'node) t

val id : ('id, _, _) t -> 'id
val owner : (_, 'owner, _) t -> 'owner
val parent : ('id, 'owner, 'node) t -> ('id, 'owner, 'node) t option
val valid : (_, _, _) t -> bool
val nodes : (_, _, 'node) t -> 'node list
val add_node : (_, _, 'node) t -> 'node -> unit
val invalidate : (_, _, 'node) t -> 'node list option

val is_ancestor :
  ancestor:('id, 'owner, 'node) t -> ('id, 'owner, 'node) t -> bool

val depth : ('id, 'owner, 'node) t option -> int
