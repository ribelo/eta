(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('source, 'inner, 'scope, 'dependency, 'value) dynamic_plan

type ('source, 'inner, 'scope, 'dependency, 'value) dynamic_apply_context

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_eval_context
  constraint 'error = [> `Invalid_scope ]

val dynamic_eval_context :
  equal:('source -> 'source -> bool) ->
  source_dependency:'dependency ->
  pack_inner:('inner -> 'dependency) ->
  new_scope:('capability -> 'scope) ->
  selector:('source -> 'inner) ->
  with_scope:('capability -> 'scope -> (unit -> 'inner) -> 'inner) ->
  validate_inner:
    ('capability ->
    'scope ->
    'inner ->
    (unit, ([> `Invalid_scope ] as 'error)) result) ->
  compute_inner:('capability -> 'inner -> 'value * bool) ->
  on_switch_failure:('capability -> 'scope -> unit) ->
  dirty:bool ->
  initialized:bool ->
  dependencies_changed:('capability -> 'dependency list -> bool) ->
  ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
  dynamic_eval_context

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

val plan_dynamic :
  ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
  dynamic_eval_context ->
  'capability ->
  ('source, 'inner, 'scope) snapshot ->
  source_value:'source ->
  source_changed:bool ->
  (('source, 'inner, 'scope, 'dependency, 'value) dynamic_plan, 'error) result

val dynamic_apply_context :
  current_value:(unit -> 'value option) ->
  cached_value:(unit -> 'value) ->
  initialized:(unit -> bool) ->
  equal:('value -> 'value -> bool) ->
  bump_recompute:(unit -> unit) ->
  stage_switch:
    (source_value:'source -> inner:'inner -> scope:'scope -> unit) ->
  stage_dependencies:('dependency list -> unit) ->
  stage_value:('value -> unit) ->
  ('source, 'inner, 'scope, 'dependency, 'value) dynamic_apply_context

val apply_dynamic_plan :
  ('source, 'inner, 'scope, 'dependency, 'value) dynamic_apply_context ->
  ('source, 'inner, 'scope, 'dependency, 'value) dynamic_plan ->
  'value * bool

val stage_transaction_switch :
  (Eta_signal_transaction.pure, 'error) Eta_signal_transaction.t ->
  ('source, 'inner, 'scope) snapshot Eta_signal_transaction.staged ->
  remember:(unit -> unit) ->
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
  unit

type ('source, 'inner, 'scope, 'owner) staged_switch

val staged_switch :
  owner:'owner option ->
  current:('source, 'inner, 'scope) snapshot ->
  staged:('source, 'inner, 'scope) snapshot option ->
  ('source, 'inner, 'scope, 'owner) staged_switch

type ('scope, 'owner) packed_staged_switch

val pack_staged_switch :
  ('source, 'inner, 'scope, 'owner) staged_switch ->
  ('scope, 'owner) packed_staged_switch

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
