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

module Make_edges (Node : EDGE_NODE) = struct
  let packed_id packed = Node.id (Node.unpack packed)

  let remove_by_id id packed =
    not (Node.equal_id (packed_id packed) id)

  let remove_dependent ~child ~parent =
    Node.set_dependents child
      (List.filter (remove_by_id (Node.id parent)) (Node.dependents child))

  let detach_dependency ~parent ~child =
    remove_dependent ~child ~parent;
    Node.set_dependencies parent
      (List.filter (remove_by_id (Node.id child)) (Node.dependencies parent))

  let has_id id packed = Node.equal_id (packed_id packed) id

  let has_dependency ~parent ~child =
    List.exists (has_id (Node.id child)) (Node.dependencies parent)

  let has_dependent ~child ~parent =
    List.exists (has_id (Node.id parent)) (Node.dependents child)

  let attach_dependency ~parent ~child =
    if not (has_dependent ~child ~parent) then
      Node.set_dependents child (Node.pack parent :: Node.dependents child);
    if not (has_dependency ~parent ~child) then
      Node.set_dependencies parent (Node.pack child :: Node.dependencies parent)

  let attach_packed_dependency ~parent packed =
    attach_dependency ~parent ~child:(Node.unpack packed)
end
