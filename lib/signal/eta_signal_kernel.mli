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

module type DIRTY_NODE = sig
  type id
  type packed

  val id : packed -> id
  val equal_id : id -> id -> bool
  val dirty : packed -> bool
  val set_dirty : packed -> bool -> unit
end

module Make_dirty (Node : DIRTY_NODE) : sig
  val mark : Node.packed -> unit

  val mark_recording_previous :
    (Node.packed * bool) list ->
    Node.packed ->
    (Node.packed * bool) list

  val restore : (Node.packed * bool) list -> unit
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

module Make_compute (Node : COMPUTE_NODE) : sig
  val remember :
    generation:int -> Node.packed list -> Node.t -> Node.packed list

  val seen : generation:int -> Node.t -> bool
  val changed_seen : Node.t -> bool

  val run :
    generation:int ->
    Node.t ->
    cycle:(unit -> 'a * bool) ->
    compute:(unit -> 'a * bool) ->
    'a * bool
end

module Value_cutoff : sig
  val changed :
    equal:('a -> 'a -> bool) ->
    initialized:bool ->
    current:'a option ->
    next:'a ->
    bool
end

module Static_eval : sig
  type ('dependency, 'a) child
  type ('dependency, 'a) result

  val child :
    dependency:'dependency -> 'a * bool -> ('dependency, 'a) child

  val leaf : 'a -> ('dependency, 'a) result

  val map :
    ('dependency, 'a) child ->
    ('a -> 'b) ->
    ('dependency, 'b) result

  val map2 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('a -> 'b -> 'c) ->
    ('dependency, 'c) result

  val map3 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('a -> 'b -> 'c -> 'd) ->
    ('dependency, 'd) result

  val map4 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('a -> 'b -> 'c -> 'd -> 'e) ->
    ('dependency, 'e) result

  val map5 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('dependency, 'e) child ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f) ->
    ('dependency, 'f) result

  val map6 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('dependency, 'e) child ->
    ('dependency, 'f) child ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g) ->
    ('dependency, 'g) result

  val map7 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('dependency, 'e) child ->
    ('dependency, 'f) child ->
    ('dependency, 'g) child ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h) ->
    ('dependency, 'h) result

  val map8 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('dependency, 'e) child ->
    ('dependency, 'f) child ->
    ('dependency, 'g) child ->
    ('dependency, 'h) child ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i) ->
    ('dependency, 'i) result

  val map9 :
    ('dependency, 'a) child ->
    ('dependency, 'b) child ->
    ('dependency, 'c) child ->
    ('dependency, 'd) child ->
    ('dependency, 'e) child ->
    ('dependency, 'f) child ->
    ('dependency, 'g) child ->
    ('dependency, 'h) child ->
    ('dependency, 'i) child ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i -> 'j) ->
    ('dependency, 'j) result

  val all :
    ('dependency, 'a) child list -> ('dependency, 'a list) result

  val dependencies : ('dependency, 'a) result -> 'dependency list
  val output : ('dependency, 'a) result -> 'a
  val children_changed : ('dependency, 'a) result -> bool

  val should_recompute :
    dirty:bool ->
    initialized:bool ->
    dependencies_changed:('dependency list -> bool) ->
    ('dependency, 'a) result ->
    bool
end
