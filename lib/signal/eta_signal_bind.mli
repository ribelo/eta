(** Bind switch state for Eta_signal internals. *)

type ('source, 'inner, 'scope) snapshot

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

val switch_parts :
  ('source, 'inner, 'scope) snapshot ->
  ('source * 'inner * 'scope) option
