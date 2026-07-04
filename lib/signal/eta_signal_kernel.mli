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
