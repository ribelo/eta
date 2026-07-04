(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('source, 'inner, 'scope, 'dependency, 'value) dynamic_eval =
  | Dynamic_switch of {
      dynamic_source_value : 'source;
      dynamic_inner : 'inner;
      dynamic_scope : 'scope;
      dynamic_switch_dependencies : 'dependency list;
      dynamic_switch_value : 'value;
    }
  | Dynamic_reuse_cached
  | Dynamic_reuse_recompute of {
      dynamic_reuse_dependencies : 'dependency list;
      dynamic_reuse_value : 'value;
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

val eval_dynamic :
  equal:('source -> 'source -> bool) ->
  ('source, 'inner, 'scope) snapshot ->
  source_dependency:'dependency ->
  pack_inner:('inner -> 'dependency) ->
  source_value:'source ->
  source_changed:bool ->
  new_scope:(unit -> 'scope) ->
  selector:('source -> 'inner) ->
  with_scope:('scope -> (unit -> 'inner) -> 'inner) ->
  validate_inner:
    ('scope -> 'inner -> (unit, ([> `Invalid_scope ] as 'error)) result) ->
  compute_inner:('inner -> 'value * bool) ->
  on_switch_failure:('scope -> unit) ->
  dirty:bool ->
  initialized:bool ->
  dependencies_changed:('dependency list -> bool) ->
  (('source, 'inner, 'scope, 'dependency, 'value) dynamic_eval, 'error) result

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
