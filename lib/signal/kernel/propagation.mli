(* Propagation: generation-safe topological freshness and rollback.

   Invariant: only the current generation of a handle participates; stale
   nodes evaluate after their stale dependencies; failed passes restore
   committed values and topology.

   DAG: Propagation and Post_commit are independent leaves; Graph composes
   both. This module must not reference Post_commit, Graph, or Eta.

   The node, signal, scope, and handle representations are intentionally
   concrete here: typed value storage is owned by issue 16, and the
   remaining representation consumers are being retired with the
   eta_signal_map test seam. *)

type phase = Idle | Active | Cleanup_pending
type stabilization = Quiescent | Committed
type error = Defect of exn | Reentrant_stabilization
type handle = { slot : int; generation : int; }

(* Handle records compare by their two integer fields; structural [=] on the
   record would call the generic [caml_equal]. *)
val same_handle : handle -> handle -> bool
type work = {
  mutable admissions : int;
  mutable claims : int;
  mutable evaluations : int;
  mutable dependency_edges : int;
  mutable propagation_edges : int;
  mutable topology_edits : int;
  mutable dependent_inserts : int;
  mutable adjacency_searches : int;
  mutable cleanup_visits : int;
  mutable rollback_visits : int;
  mutable verdict_steps : int;
}
type keyed_stats = {
  mutable keyed_reconciliation_count : int;
  mutable keyed_input_key_comparison_count : int;
  mutable keyed_input_diff_event_count : int;
  mutable keyed_child_visit_count : int;
  mutable keyed_provisional_addition_count : int;
  mutable keyed_committed_addition_count : int;
  mutable keyed_committed_removal_count : int;
  mutable keyed_reconciliation_rollback_count : int;
  mutable keyed_node_count : int;
  mutable keyed_committed_child_count : int;
}
type height_queue = {
  mutable heads : int array;
  mutable tails : int array;
  mutable lowest : int;
  mutable highest : int;
}
type ('a : value_or_null) node = {
  graph : graph;
  handle : handle;
  mutable height : int;
  mutable current : 'a;
  mutable undo : 'a;
  mutable written_in : int;
  mutable flags : int;
  compute : unit -> 'a;
  cutoff : 'a -> 'a -> bool;
  mutable dependencies : packed array;
  mutable dependents : packed list;
  mutable demand : int;
  mutable queued_in : int;
  mutable queue_next : int;
  mutable topology_priority : int;
  mutable keyed_owner : Obj.t option;
  mutable change_listeners : ('a -> unit) list;
  mutable demand_listeners : (bool -> unit) list;
  scope_next : int;
  scope : scope option;
}
and packed = P : ('a : value_or_null). 'a node -> packed [@@unboxed]

and scope = {
  mutable valid : bool;
  mutable slot_head : int;
  parent : scope or_null;
  mutable first_child : scope or_null;
  mutable previous_sibling : scope or_null;
  mutable next_sibling : scope or_null;
  mutable owner : packed or_null;
  mutable counted : bool;
}

and slot = {
  mutable generation : int;
  mutable strong : packed option;
  mutable contents : packed Weak.t option;
  mutable is_free : bool;
}
and topology_action = Created of int | Retired of int * packed
and capsule = {
  rollback_capsule : unit -> unit;
  cleanup_capsule : unit -> unit;
}
and graph = {
  mutable phase : phase;
  mutable pass : int;
  mutable slots : slot array;
  mutable slot_count : int;
  mutable free : int array;
  mutable free_length : int;
  mutable quarantine : int array;
  mutable quarantine_length : int;
  mutable journal : int array;
  mutable journal_length : int;
  mutable journal_high_water : int;
  mutable actions : topology_action array;
  mutable action_length : int;
  mutable capsules : capsule array;
  mutable capsule_length : int;
  queue : height_queue;
  priority_queue : height_queue;
  mutable admissions : int array;
  mutable admission_length : int;
  mutable current_scope : scope option;
  mutable pending_reclaims : handle array;
  mutable pending_reclaim_length : int;
  mutable suppress_reclaim : bool;
  mutable change_listeners_enabled : bool;
  mutable tombstones : handle array;
  mutable tombstone_length : int;
  mutable dynamic_scope_count : int;
  mutable keyed_reconciliations_in_pass : int;
  keyed_stats : keyed_stats;
  work : work;
}
(* Packed per-node flags (see [node]): 1 = constant, 2 = necessary,
   4 = in_queue, 8 = admitted, 16 = reclaim_queued. *)
val node_constant : ('a : value_or_null). 'a node -> bool
val node_necessary : ('a : value_or_null). 'a node -> bool
val node_in_queue : ('a : value_or_null). 'a node -> bool
val node_admitted : ('a : value_or_null). 'a node -> bool
val node_reclaim_queued : ('a : value_or_null). 'a node -> bool
val set_node_constant : ('a : value_or_null). 'a node -> bool -> unit
val set_node_necessary : ('a : value_or_null). 'a node -> bool -> unit
val set_node_in_queue : ('a : value_or_null). 'a node -> bool -> unit
val set_node_admitted : ('a : value_or_null). 'a node -> bool -> unit
val set_node_reclaim_queued : ('a : value_or_null). 'a node -> bool -> unit

type ('a : value_or_null) signal = {
  graph : graph;
  handle : handle;
  node : 'a node;
  packed : packed;
}
type ('a : value_or_null) var = {
  signal : 'a signal;
  accepted : 'a ref;
  source_cutoff : 'a -> 'a -> bool;
}
type demand = packed
type ('a : value_or_null) change =
  | Left of 'a
  | Right of 'a
  | Changed of 'a * 'a
type ('key, 'data : value_or_null, 'map : value_or_null) input_ops = {
  empty_input : 'map;
  compare_key : 'key -> 'key -> int;
  iter_diff : 'map -> 'map -> ('key -> 'data change -> unit) -> unit;
}
type ('key, 'value : value_or_null, 'map : value_or_null) output_ops = {
  empty_output : 'map;
  set_output : 'key -> 'value -> 'map -> 'map;
  remove_output : 'key -> 'map -> 'map;
}
val keyed_stats_for : graph -> keyed_stats
val set_keyed_counter_for :
  graph ->
  [< `Child_visit
   | `Committed_addition
   | `Committed_child
   | `Committed_removal
   | `Input_diff_event
   | `Input_key_comparison
   | `Node
   | `Provisional_addition
   | `Reconciliation
   | `Reconciliation_rollback ] ->
  int -> unit
val create : unit -> graph
val work : graph -> work
val enable_change_listeners : graph -> unit

(* Value slots carry the nullable [value_or_null] kind, so an existentially
   packed node needs these helpers to inspect its slot. *)
val raw_is_null : ('a : value_or_null). 'a -> bool
val raw_same : ('a : value_or_null) ('b : value_or_null). 'a -> 'b -> bool
val validate_handle : ('a : value_or_null). 'a signal -> bool
val enqueue_if_uninitialized : graph -> packed -> unit
val handle : ('a : value_or_null). 'a signal -> handle
val push_capsule : graph -> capsule -> unit
val attach : packed -> packed -> unit
val detach : packed -> packed -> unit
val replace_dependency : packed -> packed -> packed -> unit
val make_node :
  ('a : value_or_null).
  ?constant:bool ->
  graph ->
  height:int ->
  dependencies:packed array ->
  compute:(unit -> 'a) ->
  cutoff:('a -> 'a -> bool) -> initial:'a -> 'a signal
val var :
  ('a : value_or_null). ?cutoff:('a -> 'a -> bool) -> graph -> 'a -> 'a var
val watch : ('a : value_or_null). 'a var -> 'a signal
val enqueue : packed -> unit
(* Run the propagation step for [packed] immediately (used to initialize a
   dependency-free bind inner during the owner's compute). *)
val evaluate_node : packed -> bool
val enqueue_deferred : packed -> unit
val unlink_queued_node : packed -> unit
val activate : packed -> unit
val demand : ('a : value_or_null). 'a signal -> packed
val deactivate : packed -> unit
val release : packed -> unit
val value : ('a : value_or_null). 'a signal -> 'a
val set : ('a : value_or_null). graph -> 'a var -> 'a -> unit
val release_unreachable_roots : graph -> unit
val count_necessary : graph -> int
val unlink_unnecessary_queued : graph -> unit
val enqueue_all_uninitialized_necessary : graph -> unit
val clear_queue_mark : packed -> unit
val cancel_admission : graph -> packed -> unit
val public_node_counts : graph -> int * int * int
val create_scope : ?parent:scope -> graph -> unit -> scope
val scope_valid : scope -> bool
val current_scope : graph -> scope option
val current_pass : graph -> int
val invalidate_scope_chain : graph -> scope -> int
val prepend_change_listener :
  packed -> (('a : value_or_null). 'a -> unit) -> unit
val move_dependent_last : packed -> handle -> unit
val ensure_parent_height : graph -> ?current:bool -> packed -> int -> unit
val dependency_subgraph : packed -> packed list
val adjust_topology_priority : int -> packed list -> unit
val enqueue_uninitialized_topology : packed -> unit
val distinct_scopes : packed -> scope list
val reaches_handle : packed -> handle -> bool
val enqueue_reactivated : packed -> unit
val unlink_queued_descendants : 'a -> packed list -> unit
val enqueue_stale_freshness :
  graph ->
  bind_order:handle list ->
  custom_cutoff_nodes:(int, handle) Hashtbl.t ->
  duplicate_dependency_nodes:(int, handle) Hashtbl.t -> bool
val reinstall_freed : graph -> handle -> packed -> bool
val stabilize :
  ?checkpoint:(unit -> unit) -> graph -> (stabilization, error) result
val with_scope : graph -> scope -> (unit -> 'a) -> 'a
type ('a, 'b) bind_owner = {
  bind_signal : 'b signal;
  source : 'a signal;
  selector : 'a -> 'b signal;
  mutable selected_source : 'a;
  mutable inner : 'b signal;
  mutable inner_scope : scope;
  mutable rollback_inner : 'b signal;
  mutable rollback_scope : scope;
  mutable tentative_inner : 'b signal;
}
type ('key, 'data : value_or_null, 'output : value_or_null) keyed_child = {
  key : 'key;
  data : 'data var;
  output : 'output signal;
  scope : scope;
}
type keyed_event =
    Keyed_detached of scope
  | Keyed_invalidated of scope
  | Keyed_attached of scope
type ('key, 'value) child_tree =
    Child_empty
  | Child_branch of { height : int; left : ('key, 'value) child_tree;
      key : 'key; value : 'value; right : ('key, 'value) child_tree;
    }
type ('key, 'data : value_or_null, 'input : value_or_null,
      'output : value_or_null, 'output_map : value_or_null) keyed_owner = {
  keyed_signal : 'output_map signal;
  keyed_input : 'input signal;
  input_ops : ('key, 'data, 'input) input_ops;
  output_ops : ('key, 'output, 'output_map) output_ops;
  data_cutoff : 'data -> 'data -> bool;
  builder : key:'key -> data:'data signal -> 'output signal;
  mutable precommit : (unit -> unit) option;
  mutable event_recorder : keyed_event -> unit;
  mutable committed_input : 'input;
  mutable children : ('key, ('key, 'data, 'output) keyed_child) child_tree;
  mutable output_root : 'output_map;
  mutable candidate_children :
    ('key, ('key, 'data, 'output) keyed_child) child_tree;
  mutable candidate_output : 'output_map;
  mutable output_undo : 'output_map;
  mutable output_written_in : int;
}
val keyed_node_counts : graph -> int * int
val append_nodes_dot :
  Buffer.t ->
  graph ->
  only_necessary:bool ->
  scope_label:string -> dot_state:bool -> dot_dynamic_scopes:bool -> unit
val keyed_find :
  ('b : value_or_null) ('c : value_or_null) ('d : value_or_null)
  ('e : value_or_null).
  ('a, 'b, 'c, 'd, 'e) keyed_owner -> 'a -> ('a, 'b, 'd) keyed_child option
val keyed_owner :
  ('a : value_or_null) ('b : value_or_null) ('d : value_or_null)
  ('input : value_or_null).
  ?cutoff:('a -> 'a -> bool) ->
  ?data_cutoff:('b -> 'b -> bool) ->
  input:'input signal ->
  input_ops:('c, 'b, 'input) input_ops ->
  output_ops:('c, 'd, 'a) output_ops ->
  build:(key:'c -> data:'b signal -> 'd signal) ->
  unit -> ('c, 'b, 'input, 'd, 'a) keyed_owner
val set_keyed_event_recorder :
  ('b : value_or_null) ('c : value_or_null) ('d : value_or_null)
  ('e : value_or_null).
  ('a, 'b, 'c, 'd, 'e) keyed_owner -> (keyed_event -> unit) -> unit
val set_keyed_precommit :
  ('b : value_or_null) ('c : value_or_null) ('d : value_or_null)
  ('e : value_or_null).
  ('a, 'b, 'c, 'd, 'e) keyed_owner -> (unit -> unit) -> unit
val child_iter :
  ('b : value_or_null) ('c : value_or_null).
  (('a, 'b, 'c) keyed_child -> unit) ->
  ('a, ('a, 'b, 'c) keyed_child) child_tree ->
  unit
type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}
val raw_scalar : ?cutoff:bool -> int -> workload
