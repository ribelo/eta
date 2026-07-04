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

val empty : ('source, 'inner, 'scope) snapshot

val switch :
  source_value:'source ->
  inner:'inner ->
  scope:'scope ->
  ('source, 'inner, 'scope) snapshot

val source_value : ('source, _, _) snapshot -> 'source option
val inner : (_, 'inner, _) snapshot -> 'inner option
val inner_scope : (_, _, 'scope) snapshot -> 'scope option

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
