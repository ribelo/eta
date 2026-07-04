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

val children_with_scope_owner :
  owner_valid:('owner -> bool) ->
  owner_node:('owner -> 'node) ->
  ('id, 'owner, 'node) t option ->
  'node list ->
  'node list

type ('id, 'owner, 'node) context

val create_context : unit -> ('id, 'owner, 'node) context
val current : ('id, 'owner, 'node) context -> ('id, 'owner, 'node) t option

val require_valid_current :
  ('id, 'owner, 'node) context ->
  (('id, 'owner, 'node) t, [> `Ambiguous_scope ]) result

val with_current :
  ('id, 'owner, 'node) context ->
  ('id, 'owner, 'node) t ->
  (unit -> 'a) ->
  'a

module type VALIDATION_NODE = sig
  type node_id
  type scope_id
  type owner
  type node

  val node_id : node -> node_id
  val valid : node -> bool
  val scope : node -> (scope_id, owner, node) t option
  val children : node -> node list
end

module Make_validation (Node : VALIDATION_NODE) : sig
  val validate_inner :
    scope:(Node.scope_id, Node.owner, Node.node) t ->
    Node.node ->
    (unit, [> `Invalid_scope ]) result
end

module type INVALIDATION_NODE = sig
  type node_id
  type scope_id
  type owner
  type node

  val node_id : node -> node_id
  val equal_node_id : node_id -> node_id -> bool
  val valid : node -> bool
  val dependents : node -> node list
  val nested_scope : node -> (scope_id, owner, node) t option
end

module Make_invalidation (Node : INVALIDATION_NODE) : sig
  val collect :
    ?exclude_node_id:Node.node_id ->
    (Node.node_id, unit) Hashtbl.t ->
    Node.node list ref ->
    (Node.scope_id, Node.owner, Node.node) t ->
    unit
end
