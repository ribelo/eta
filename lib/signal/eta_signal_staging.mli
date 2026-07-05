(** Pure staging orchestration for Eta_signal internals. *)

type reset_context
type commit_context

type 'hook reset = {
  rollback_binds : reset_context -> 'hook list;
  pure_disposal_hooks : reset_context -> 'hook list;
  rollback_transaction : reset_context -> unit;
  clear_computed_nodes : reset_context -> unit;
  clear_staged_binds : reset_context -> unit;
  clear_pure_disposal_hooks : reset_context -> unit;
  clear_timer_refresh_staging : reset_context -> unit;
}

val reset : 'hook reset -> 'hook list
(** Roll back bind staging, collect pure disposal hooks, clear all staged graph
    state, and return hooks to run after graph lock release. *)

type 'hook commit = {
  preflight : commit_context -> unit;
  commit_binds : commit_context -> 'hook list;
  remember_pure_disposal_hooks : commit_context -> 'hook list -> unit;
  prepare_signals : commit_context -> unit;
  commit_transaction : commit_context -> unit;
  commit_timer_refresh : commit_context -> unit;
  commit_signals : commit_context -> unit;
  disposal_hooks : commit_context -> 'hook list;
  clear_computed_nodes : commit_context -> unit;
  clear_staged_binds : commit_context -> unit;
  clear_pure_disposal_hooks : commit_context -> unit;
  clear_timer_refresh_disposal_hooks : commit_context -> unit;
  clear_timer_refresh_staged_timers : commit_context -> unit;
  commit_snapshot : commit_context -> unit;
}

val commit : 'hook commit -> 'hook list
(** Run preflight, commit staged graph effects, collect disposal hooks, clear
    all staging state, advance the pure snapshot, and return hooks to run after
    graph lock release. *)
