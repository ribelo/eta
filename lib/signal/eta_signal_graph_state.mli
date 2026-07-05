(** Stabilization-facing graph state for Eta_signal internals. *)

type ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t
type staging

val create : unit -> ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t

val generation : (_, _, _, _, _, _) t -> int

val set_generation : (_, _, _, _, _, _) t -> int -> unit

val advance_generation :
  (_, _, _, _, _, _) t -> advance:(int -> int) -> unit

val begin_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t ->
  timer_refresh:'refresh option ->
  staging

val require_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t -> staging

val drain_pending :
  ('pending, _, _, _, _, _) t -> 'pending list

val enqueue_pending :
  ('pending, _, _, _, _, _) t -> 'pending -> unit

val remember_computed :
  (_, _, 'node, _, _, _) t ->
  staging ->
  generation:int ->
  'node ->
  project:('node -> 'compute_node) ->
  remember:(generation:int -> 'node list -> 'compute_node -> 'node list) ->
  unit

val computed_nodes : (_, _, 'node, _, _, _) t -> 'node list

val stage_bind : (_, 'bind, _, _, _, _) t -> staging -> 'bind -> unit
val staged_binds : (_, 'bind, _, _, _, _) t -> 'bind list

val remember_pure_disposal_hooks :
  (_, _, _, 'hook, _, _) t -> staging -> 'hook list -> unit

val remember_timer_refresh_disposal_hooks :
  (_, _, _, 'hook, _, _) t -> staging -> 'hook list -> unit

val active_timer_refresh : (_, _, _, _, _, 'refresh) t -> 'refresh option
val clear_active_timer_refresh : (_, _, _, _, _, _) t -> unit

val stage_timer_refresh_timer :
  (_, _, _, _, 'timer, _) t -> staging -> 'timer -> unit

val next_timer_refresh_token :
  (_, _, _, _, _, _) t -> advance:(int -> int) -> int

val set_next_timer_refresh_token : (_, _, _, _, _, _) t -> int -> unit

val clear_timer_refresh_staging :
  (_, _, _, _, 'timer, 'refresh) t ->
  rollback_dirty:('refresh -> unit) ->
  clear_timer:('timer -> unit) ->
  unit

type ('bind, 'hook, 'timer, 'refresh) reset_context

val reset_context :
  rollback_bind:('bind -> 'hook list) ->
  rollback_transaction:(unit -> unit) ->
  rollback_timer_refresh_dirty:('refresh -> unit) ->
  clear_timer_refresh_timer:('timer -> unit) ->
  ('bind, 'hook, 'timer, 'refresh) reset_context

val reset_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t ->
  staging ->
  ('bind, 'hook, 'timer, 'refresh) reset_context ->
  'hook list

type ('bind, 'node, 'hook, 'timer) commit_context

val commit_context :
  preflight:(unit -> unit) ->
  commit_bind:('bind -> 'hook list) ->
  prepare_signal:('node -> unit) ->
  commit_transaction:(unit -> unit) ->
  commit_timer_refresh:('timer -> unit) ->
  commit_signal:('node -> unit) ->
  advance_snapshot:(int -> int) ->
  ('bind, 'node, 'hook, 'timer) commit_context

val commit_staging :
  ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t ->
  staging ->
  ('bind, 'node, 'hook, 'timer) commit_context ->
  'hook list

val pure_snapshot_commit_count : (_, _, _, _, _, _) t -> int
val set_pure_snapshot_commit_count : (_, _, _, _, _, _) t -> int -> unit
