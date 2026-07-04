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

module type ORDER_NODE = sig
  type id
  type t

  val id : t -> id
  val equal_id : id -> id -> bool
  val compare_id : id -> id -> int
  val children : t -> t list
end

module Make_order (Node : ORDER_NODE) = struct
  let same_node left right =
    Node.equal_id (Node.id left) (Node.id right)

  let depends_on node dependency =
    let target_id = Node.id dependency in
    let seen = Hashtbl.create 16 in
    let rec visit candidate =
      let candidate_id = Node.id candidate in
      if Node.equal_id candidate_id target_id then true
      else if Hashtbl.mem seen candidate_id then false
      else (
        Hashtbl.add seen candidate_id ();
        List.exists visit (Node.children candidate))
    in
    List.exists visit (Node.children node)

  let compare left right =
    if same_node left right then 0
    else if depends_on left right then 1
    else if depends_on right left then -1
    else Node.compare_id (Node.id left) (Node.id right)
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

module Weak_cell = struct
  type t = Obj.t Weak.t

  let create raw =
    let cell = Weak.create 1 in
    (* Store the raw node, not a short-lived existential wrapper. *)
    Weak.set cell 0 (Some (Obj.repr raw));
    cell

  let value ~pack cell =
    match Weak.get cell 0 with
    | None -> None
    | Some raw -> Some (pack (Obj.obj raw))

  let collect ~pack ~keep cells =
    let rec loop kept_cells kept_values = function
      | [] -> (List.rev kept_cells, List.rev kept_values)
      | cell :: rest -> (
          match value ~pack cell with
          | None -> loop kept_cells kept_values rest
          | Some packed ->
              if keep packed then
                loop (cell :: kept_cells) (packed :: kept_values) rest
              else loop kept_cells kept_values rest)
    in
    loop [] [] cells
end

module Snapshot = struct
  type ('id, 'a) t = {
    value : 'a option;
    initialized : bool;
    version : int;
    dependency_versions : ('id * int) list;
  }

  let empty =
    {
      value = None;
      initialized = false;
      version = 0;
      dependency_versions = [];
    }

  let initialized value =
    {
      value = Some value;
      initialized = true;
      version = 0;
      dependency_versions = [];
    }

  let value snapshot = snapshot.value
  let is_initialized snapshot = snapshot.initialized
  let version snapshot = snapshot.version
  let dependency_versions snapshot = snapshot.dependency_versions
  let with_version snapshot version = { snapshot with version }

  let publish ~advance_version ~current snapshot value =
    let version =
      if snapshot.version = current.version then
        advance_version snapshot.version
      else snapshot.version
    in
    { snapshot with value = Some value; initialized = true; version }

  let with_dependency_versions snapshot dependency_versions =
    { snapshot with dependency_versions }

  let preflight_commit_version ~advance_version ~current ~staged =
    if staged.version <> current.version then
      ignore (advance_version current.version : int)
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

module type COMPUTE_NODE = sig
  type packed
  type t

  val pack : t -> packed
  val seen_generation : t -> int
  val set_seen_generation : t -> int -> unit
  val changed_seen : t -> bool
  val set_changed_seen : t -> bool -> unit
  val computing : t -> bool
  val set_computing : t -> bool -> unit
  val computed_generation : t -> int
  val set_computed_generation : t -> int -> unit
end

module Make_compute (Node : COMPUTE_NODE) = struct
  let remember ~generation computed node =
    if Node.computed_generation node = generation then computed
    else (
      Node.set_computed_generation node generation;
      Node.pack node :: computed)

  let seen ~generation node =
    Node.seen_generation node = generation

  let changed_seen node =
    Node.changed_seen node

  let run ~generation node ~cycle ~compute =
    if Node.computing node then cycle ()
    else (
      Node.set_computing node true;
      match
        Fun.protect
          ~finally:(fun () -> Node.set_computing node false)
          compute
      with
      | value, changed ->
          Node.set_seen_generation node generation;
          Node.set_changed_seen node changed;
          (value, changed))
end

module Value_cutoff = struct
  let changed ~equal ~initialized ~current ~next =
    (not initialized)
    ||
    match current with
    | None -> true
    | Some old_value -> not (equal old_value next)
end

module Static_eval = struct
  type ('dependency, 'a) child = {
    dependency : 'dependency;
    value : 'a;
    changed : bool;
  }

  type ('dependency, 'a) result = {
    dependencies : 'dependency list;
    children_changed : bool;
    output : unit -> 'a;
  }

  let child ~dependency (value, changed) = { dependency; value; changed }

  let result ~dependencies ~children_changed output =
    { dependencies; children_changed; output }

  let leaf output =
    { dependencies = []; children_changed = false; output = (fun () -> output) }

  let map a f =
    result ~dependencies:[ a.dependency ] ~children_changed:a.changed
      (fun () -> f a.value)

  let map2 a b f =
    result
      ~dependencies:[ a.dependency; b.dependency ]
      ~children_changed:(a.changed || b.changed)
      (fun () -> f a.value b.value)

  let map3 a b c f =
    result
      ~dependencies:[ a.dependency; b.dependency; c.dependency ]
      ~children_changed:(a.changed || b.changed || c.changed)
      (fun () -> f a.value b.value c.value)

  let map4 a b c d f =
    result
      ~dependencies:[ a.dependency; b.dependency; c.dependency; d.dependency ]
      ~children_changed:(a.changed || b.changed || c.changed || d.changed)
      (fun () -> f a.value b.value c.value d.value)

  let map5 a b c d e f =
    result
      ~dependencies:
        [ a.dependency; b.dependency; c.dependency; d.dependency; e.dependency ]
      ~children_changed:
        (a.changed || b.changed || c.changed || d.changed || e.changed)
      (fun () -> f a.value b.value c.value d.value e.value)

  let map6 a b c d e f_child f =
    result
      ~dependencies:
        [
          a.dependency;
          b.dependency;
          c.dependency;
          d.dependency;
          e.dependency;
          f_child.dependency;
        ]
      ~children_changed:
        (a.changed || b.changed || c.changed || d.changed || e.changed
       || f_child.changed)
      (fun () -> f a.value b.value c.value d.value e.value f_child.value)

  let map7 a b c d e f_child g f =
    result
      ~dependencies:
        [
          a.dependency;
          b.dependency;
          c.dependency;
          d.dependency;
          e.dependency;
          f_child.dependency;
          g.dependency;
        ]
      ~children_changed:
        (a.changed || b.changed || c.changed || d.changed || e.changed
       || f_child.changed || g.changed)
      (fun () ->
        f a.value b.value c.value d.value e.value f_child.value g.value)

  let map8 a b c d e f_child g h f =
    result
      ~dependencies:
        [
          a.dependency;
          b.dependency;
          c.dependency;
          d.dependency;
          e.dependency;
          f_child.dependency;
          g.dependency;
          h.dependency;
        ]
      ~children_changed:
        (a.changed || b.changed || c.changed || d.changed || e.changed
       || f_child.changed || g.changed || h.changed)
      (fun () ->
        f a.value b.value c.value d.value e.value f_child.value g.value
          h.value)

  let map9 a b c d e f_child g h i f =
    result
      ~dependencies:
        [
          a.dependency;
          b.dependency;
          c.dependency;
          d.dependency;
          e.dependency;
          f_child.dependency;
          g.dependency;
          h.dependency;
          i.dependency;
        ]
      ~children_changed:
        (a.changed || b.changed || c.changed || d.changed || e.changed
       || f_child.changed || g.changed || h.changed || i.changed)
      (fun () ->
        f a.value b.value c.value d.value e.value f_child.value g.value h.value
          i.value)

  let all children =
    result
      ~dependencies:(List.map (fun child -> child.dependency) children)
      ~children_changed:(List.exists (fun child -> child.changed) children)
      (fun () -> List.map (fun child -> child.value) children)

  let dependencies result = result.dependencies
  let output result = result.output ()
  let children_changed result = result.children_changed

  type ('dependency, 'a) plan =
    | Use_cached
    | Recompute of {
        dependencies : 'dependency list;
        output : 'a;
        stage_dependencies : bool;
      }

  let should_recompute ~dirty ~initialized ~dependencies_changed result =
    dirty || (not initialized) || result.children_changed
    || dependencies_changed result.dependencies

  let plan ?(stage_dependencies = true) ~dirty ~initialized
      ~dependencies_changed result =
    if should_recompute ~dirty ~initialized ~dependencies_changed result then
      Recompute
        {
          dependencies = result.dependencies;
          output = output result;
          stage_dependencies;
        }
    else Use_cached
end
