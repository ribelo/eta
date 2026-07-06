(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('capability, 'source, 'inner, 'dependency) dynamic_source_plan

val dynamic_source_plan :
  equal:('source -> 'source -> bool) ->
  compute_source:('capability -> 'source * bool) ->
  source_dependency:'dependency ->
  inner_dependency:('inner -> 'dependency) ->
  ('capability, 'source, 'inner, 'dependency) dynamic_source_plan

type ('capability, 'source, 'inner, 'scope, 'value, 'error)
     dynamic_switch_plan
  constraint 'error = [> `Invalid_scope ]

val dynamic_switch_plan :
  new_scope:('capability -> 'scope) ->
  with_scope:('capability -> 'scope -> (unit -> 'inner) -> 'inner) ->
  on_switch_failure:('capability -> 'scope -> unit) ->
  selector:('source -> 'inner) ->
  validate_inner:
    ('capability ->
    'scope ->
    'inner ->
    (unit, ([> `Invalid_scope ] as 'error)) result) ->
  compute_inner:('capability -> 'inner -> 'value * bool) ->
  ('capability, 'source, 'inner, 'scope, 'value, 'error)
  dynamic_switch_plan

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_context
  constraint 'error = [> `Invalid_scope ]

type ('capability, 'dependency) dynamic_reuse_plan

val dynamic_reuse_plan :
  dirty:bool ->
  dependencies_changed:('capability -> 'dependency list -> bool) ->
  ('capability, 'dependency) dynamic_reuse_plan

type 'value dynamic_value_state

val dynamic_value_state :
  initialized:bool -> current:'value option -> 'value dynamic_value_state

type 'value dynamic_value_context

val dynamic_value_context :
  state:(unit -> 'value dynamic_value_state) ->
  cached_value:(unit -> 'value) ->
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
  switch:
    ('capability, 'source, 'inner, 'scope, 'value, 'error)
    dynamic_switch_plan ->
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

val inner_scope : (_, _, 'scope) snapshot -> 'scope option

val dependencies :
  source:'dependency ->
  inner_dependency:('inner -> 'dependency) ->
  (_, 'inner, _) snapshot ->
  'dependency list

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
