(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('inner, 'dependency) dynamic_dependencies

val dynamic_dependencies :
  source:'dependency ->
  pack_inner:('inner -> 'dependency) ->
  ('inner, 'dependency) dynamic_dependencies

type ('capability, 'source, 'inner, 'dependency) dynamic_source_plan

val dynamic_source_plan :
  equal:('source -> 'source -> bool) ->
  compute_source:('capability -> 'source * bool) ->
  dependencies:('inner, 'dependency) dynamic_dependencies ->
  ('capability, 'source, 'inner, 'dependency) dynamic_source_plan

type ('capability, 'inner, 'scope) dynamic_scope_plan

val dynamic_scope_plan :
  new_scope:('capability -> 'scope) ->
  with_scope:('capability -> 'scope -> (unit -> 'inner) -> 'inner) ->
  on_switch_failure:('capability -> 'scope -> unit) ->
  ('capability, 'inner, 'scope) dynamic_scope_plan

type ('capability, 'source, 'inner, 'scope, 'value, 'error)
     dynamic_inner_plan
  constraint 'error = [> `Invalid_scope ]

val dynamic_inner_plan :
  selector:('source -> 'inner) ->
  validate_inner:
    ('capability ->
    'scope ->
    'inner ->
    (unit, ([> `Invalid_scope ] as 'error)) result) ->
  compute_inner:('capability -> 'inner -> 'value * bool) ->
  ('capability, 'source, 'inner, 'scope, 'value, 'error)
  dynamic_inner_plan

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_context
  constraint 'error = [> `Invalid_scope ]

type ('capability, 'dependency) dynamic_reuse_plan

val dynamic_reuse_plan :
  dirty:bool ->
  dependencies_changed:('capability -> 'dependency list -> bool) ->
  ('capability, 'dependency) dynamic_reuse_plan

type 'value dynamic_value_context

val dynamic_value_context :
  current_value:(unit -> 'value option) ->
  cached_value:(unit -> 'value) ->
  initialized:(unit -> bool) ->
  value_equal:('value -> 'value -> bool) ->
  bump_recompute:(unit -> unit) ->
  'value dynamic_value_context

type ('source, 'inner, 'scope, 'dependency, 'value)
     dynamic_staging_context

val dynamic_staging_context :
  stage_switch:
    (source_value:'source -> inner:'inner -> scope:'scope -> unit) ->
  stage_dependencies:('dependency list -> unit) ->
  stage_value:('value -> unit) ->
  ('source, 'inner, 'scope, 'dependency, 'value)
  dynamic_staging_context

val dynamic_context :
  source:('capability, 'source, 'inner, 'dependency) dynamic_source_plan ->
  scope:('capability, 'inner, 'scope) dynamic_scope_plan ->
  inner:
    ('capability, 'source, 'inner, 'scope, 'value, 'error)
    dynamic_inner_plan ->
  reuse:('capability, 'dependency) dynamic_reuse_plan ->
  value:'value dynamic_value_context ->
  staging:
    ('source, 'inner, 'scope, 'dependency, 'value)
    dynamic_staging_context ->
  ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
  dynamic_context

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

val run_dynamic :
  ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
  dynamic_context ->
  'capability ->
  ('source, 'inner, 'scope) snapshot ->
  ('value * bool, 'error) result

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

type ('owner, 'inner, 'scope, 'hook) staged_switch_lifecycle

val staged_switch_lifecycle :
  detach_old_inner:('owner -> 'inner -> unit) ->
  invalidate_scope:('scope -> 'hook list) ->
  attach_new_inner:('owner -> 'inner -> unit) ->
  ('owner, 'inner, 'scope, 'hook) staged_switch_lifecycle

val commit_staged_switch :
  ('source, 'inner, 'scope, 'owner) staged_switch ->
  ('owner, 'inner, 'scope, 'hook) staged_switch_lifecycle ->
  ('hook list, [> `Invalid_scope ]) result

val rollback_staged_switch :
  staged:('source, 'inner, 'scope) snapshot option ->
  ('owner, 'inner, 'scope, 'hook) staged_switch_lifecycle ->
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
