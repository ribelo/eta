(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

type ('inner, 'scope) commit_switch = {
  old_inner : 'inner option;
  old_scope : 'scope option;
  new_inner : 'inner;
}

type 'inner eval_plan =
  | Switch
  | Reuse of 'inner

type ('inner, 'value) switch_eval = {
  eval_inner : 'inner;
  eval_value : 'value;
}

type ('dependency, 'value) reuse_eval =
  | Reuse_cached
  | Reuse_recompute of {
      reuse_dependencies : 'dependency list;
      reuse_value : 'value;
    }

val empty : ('source, 'inner, 'scope) snapshot

val switch :
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
  ('source, 'inner, 'scope) snapshot

val source_value : ('source, _, _) snapshot -> 'source option
val inner : (_, 'inner, _) snapshot -> 'inner option
val inner_scope : (_, _, 'scope) snapshot -> 'scope option

val dependencies :
  source:'dependency -> inner:'dependency option -> 'dependency list

val needs_new_inner :
  equal:('source -> 'source -> bool) ->
  ('source, _, _) snapshot ->
  'source ->
  bool

val eval_plan :
  equal:('source -> 'source -> bool) ->
  ('source, 'inner, _) snapshot ->
  source_value:'source ->
  ('inner eval_plan, [> `Invalid_scope ]) result

val eval_switch :
  scope:'scope ->
  source_value:'source ->
  selector:('source -> 'inner) ->
  with_scope:('scope -> (unit -> 'inner) -> 'inner) ->
  validate_inner:
    ('scope -> 'inner -> (unit, ([> `Invalid_scope ] as 'error)) result) ->
  compute_inner:('inner -> 'value * bool) ->
  on_failure:('scope -> unit) ->
  (('inner, 'value) switch_eval, 'error) result

val eval_reuse :
  source_dependency:'dependency ->
  inner_dependency:'dependency ->
  source_changed:bool ->
  compute_inner:(unit -> 'value * bool) ->
  dirty:bool ->
  initialized:bool ->
  dependencies_changed:('dependency list -> bool) ->
  ('dependency, 'value) reuse_eval

val switch_parts :
  ('source, 'inner, 'scope) snapshot ->
  ('source * 'inner * 'scope) option

val commit_switch :
  current:('source, 'inner, 'scope) snapshot ->
  staged:('source, 'inner, 'scope) snapshot ->
  (('inner, 'scope) commit_switch, [> `Invalid_scope ]) result

val rollback_switch :
  staged:('source, 'inner, 'scope) snapshot ->
  ('scope, [> `Invalid_scope ]) result

val preflight_switch :
  current:('source, 'inner, 'scope) snapshot ->
  staged:('source, 'inner, 'scope) snapshot ->
  ('scope option, [> `Invalid_scope ]) result
