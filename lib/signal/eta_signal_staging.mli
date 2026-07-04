(** Pure staging orchestration for Eta_signal internals. *)

type 'hook reset = {
  rollback_binds : unit -> 'hook list;
  pure_disposal_hooks : unit -> 'hook list;
  rollback_transaction : unit -> unit;
  clear_computed_nodes : unit -> unit;
  clear_staged_binds : unit -> unit;
  clear_pure_disposal_hooks : unit -> unit;
  clear_timer_refresh_staging : unit -> unit;
}

val reset : 'hook reset -> 'hook list
(** Roll back bind staging, collect pure disposal hooks, clear all staged graph
    state, and return hooks to run after graph lock release. *)

type 'hook commit = {
  preflight : unit -> unit;
  commit_binds : unit -> 'hook list;
  remember_pure_disposal_hooks : 'hook list -> unit;
  prepare_signals : unit -> unit;
  commit_transaction : unit -> unit;
  commit_timer_refresh : unit -> unit;
  commit_signals : unit -> unit;
  disposal_hooks : unit -> 'hook list;
  clear_computed_nodes : unit -> unit;
  clear_staged_binds : unit -> unit;
  clear_pure_disposal_hooks : unit -> unit;
  clear_timer_refresh_disposal_hooks : unit -> unit;
  clear_timer_refresh_staged_timers : unit -> unit;
  commit_snapshot : unit -> unit;
}

val commit : 'hook commit -> 'hook list
(** Run preflight, commit staged graph effects, collect disposal hooks, clear
    all staging state, advance the pure snapshot, and return hooks to run after
    graph lock release. *)
