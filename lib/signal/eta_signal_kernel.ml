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

module type REACHABLE_NODE = sig
  type id
  type packed

  val id : packed -> id
  val valid : packed -> bool
  val children : packed -> packed list
end

module Make_reachable (Node : REACHABLE_NODE) = struct
  let fold ~roots ~init ~f =
    let seen = Hashtbl.create 16 in
    let rec visit acc packed =
      let id = Node.id packed in
      if (not (Node.valid packed)) || Hashtbl.mem seen id then acc
      else (
        Hashtbl.add seen id ();
        List.fold_left visit (f acc packed) (Node.children packed))
    in
    List.fold_left visit init roots

  let ids ~roots =
    fold ~roots ~init:(Hashtbl.create 16) ~f:(fun seen packed ->
        Hashtbl.replace seen (Node.id packed) ();
        seen)
end

module type VERSION_NODE = sig
  type id
  type packed

  val id : packed -> id
  val equal_id : id -> id -> bool
  val version : packed -> int
end

module Make_versions (Node : VERSION_NODE) = struct
  let snapshot nodes =
    List.map (fun node -> (Node.id node, Node.version node)) nodes

  let rec same_snapshot left right =
    match (left, right) with
    | [], [] -> true
    | (left_id, left_version) :: left_rest,
      (right_id, right_version) :: right_rest ->
        Node.equal_id left_id right_id
        && Int.equal left_version right_version
        && same_snapshot left_rest right_rest
    | [], _ :: _ | _ :: _, [] -> false

  let changed ~current nodes =
    not (same_snapshot current (snapshot nodes))
end

module type DIRTY_NODE = sig
  type id
  type packed

  val id : packed -> id
  val equal_id : id -> id -> bool
  val dirty : packed -> bool
  val set_dirty : packed -> bool -> unit
end

module Make_dirty (Node : DIRTY_NODE) = struct
  let mark node =
    Node.set_dirty node true

  let same_node node (candidate, _) =
    Node.equal_id (Node.id node) (Node.id candidate)

  let mark_recording_previous entries node =
    let entries =
      if List.exists (same_node node) entries then entries
      else (node, Node.dirty node) :: entries
    in
    mark node;
    entries

  let restore entries =
    List.iter (fun (node, dirty) -> Node.set_dirty node dirty) entries
end
