(** Static graph kernel helpers for Eta_signal internals. *)

module type EDGE_NODE = sig
  type id
  type packed
  type t

  val pack : t -> packed
  val unpack : packed -> t
  val id : t -> id
  val equal_id : id -> id -> bool
  val dependencies : t -> packed list
  val set_dependencies : t -> packed list -> unit
  val dependents : t -> packed list
  val set_dependents : t -> packed list -> unit
end

module Make_edges (Node : EDGE_NODE) : sig
  val remove_dependent : child:Node.t -> parent:Node.t -> unit
  val detach_dependency : parent:Node.t -> child:Node.t -> unit
  val has_dependency : parent:Node.t -> child:Node.t -> bool
  val has_dependent : child:Node.t -> parent:Node.t -> bool
  val attach_dependency : parent:Node.t -> child:Node.t -> unit
  val attach_packed_dependency : parent:Node.t -> Node.packed -> unit
end

module type REACHABLE_NODE = sig
  type id
  type packed

  val id : packed -> id
  val valid : packed -> bool
  val children : packed -> packed list
end

module Make_reachable (Node : REACHABLE_NODE) : sig
  val fold :
    roots:Node.packed list ->
    init:'acc ->
    f:('acc -> Node.packed -> 'acc) ->
    'acc

  val ids : roots:Node.packed list -> (Node.id, unit) Hashtbl.t
end

module type VERSION_NODE = sig
  type id
  type packed

  val id : packed -> id
  val equal_id : id -> id -> bool
  val version : packed -> int
end

module Make_versions (Node : VERSION_NODE) : sig
  val snapshot : Node.packed list -> (Node.id * int) list
  val changed : current:(Node.id * int) list -> Node.packed list -> bool
end
