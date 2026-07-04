(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('source, 'inner, 'scope, 'dependency, 'value, 'error) dynamic_context = {
  context_equal : 'source -> 'source -> bool;
  context_source_dependency : 'dependency;
  context_pack_inner : 'inner -> 'dependency;
  context_new_scope : unit -> 'scope;
  context_selector : 'source -> 'inner;
  context_with_scope : 'scope -> (unit -> 'inner) -> 'inner;
  context_validate_inner :
    'scope -> 'inner -> (unit, ([> `Invalid_scope ] as 'error)) result;
  context_compute_inner : 'inner -> 'value * bool;
  context_on_switch_failure : 'scope -> unit;
  context_dirty : bool;
  context_initialized : bool;
  context_dependencies_changed : 'dependency list -> bool;
  context_mark_recomputed : unit -> unit;
  context_switch_changed : 'value -> bool;
  context_stage_switch :
    source_value:'source -> inner:'inner -> scope:'scope -> unit;
  context_stage_dependencies : 'dependency list -> unit;
  context_stage_value : 'value -> unit;
  context_current_value : unit -> 'value;
  context_recompute_with_dependencies :
    'dependency list -> 'value -> 'value * bool;
  context_use_cached : unit -> 'value * bool;
}

val empty : ('source, 'inner, 'scope) snapshot

val switch :
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
    ('source, 'inner, 'scope) snapshot

val inner : (_, 'inner, _) snapshot -> 'inner option
val inner_scope : (_, _, 'scope) snapshot -> 'scope option

val dependencies :
  source:'dependency -> inner:'dependency option -> 'dependency list

val compute_dynamic :
  ('source, 'inner, 'scope, 'dependency, 'value, 'error) dynamic_context ->
  ('source, 'inner, 'scope) snapshot ->
  source_value:'source ->
  source_changed:bool ->
  ('value * bool, 'error) result

val stage_transaction_switch :
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t ->
  ('source, 'inner, 'scope) snapshot Eta_signal_transaction.staged ->
  remember:(unit -> unit) ->
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
  unit

type ('source, 'inner, 'scope, 'owner) staged_switch = {
  owner : 'owner option;
  current : ('source, 'inner, 'scope) snapshot;
  staged : ('source, 'inner, 'scope) snapshot option;
}

type ('scope, 'owner) packed_staged_switch =
  | Packed_staged_switch :
      ('source, 'inner, 'scope, 'owner) staged_switch
      -> ('scope, 'owner) packed_staged_switch

val commit_staged_switch :
  ('source, 'inner, 'scope, 'owner) staged_switch ->
  detach_old_inner:('owner -> 'inner -> unit) ->
  invalidate_old_scope:('scope -> 'hook list) ->
  attach_new_inner:('owner -> 'inner -> unit) ->
  ('hook list, [> `Invalid_scope ]) result

val rollback_staged_switch :
  staged:('source, 'inner, 'scope) snapshot option ->
  invalidate_new_scope:('scope -> 'hook list) ->
  ('hook list, [> `Invalid_scope ]) result

val preflight_staged_switch :
  ('source, 'inner, 'scope, 'owner) staged_switch ->
  collect_old_scope:('owner -> 'scope -> unit) ->
  (unit, [> `Invalid_scope ]) result

val collect_staged_switch_invalidations :
  init:'acc ->
  switches:'switch list ->
  staged_switch:('switch -> ('scope, 'owner) packed_staged_switch) ->
  collect_old_scope:('acc -> owner:'owner -> 'scope -> 'acc) ->
  ('acc, [> `Invalid_scope ]) result
