type 'hook reset = {
  rollback_binds : unit -> 'hook list;
  pure_disposal_hooks : unit -> 'hook list;
  rollback_transaction : unit -> unit;
  clear_computed_nodes : unit -> unit;
  clear_staged_binds : unit -> unit;
  clear_pure_disposal_hooks : unit -> unit;
  clear_timer_refresh_staging : unit -> unit;
}

let reset ops =
  let rollback_hooks = ops.rollback_binds () in
  let pure_hooks = ops.pure_disposal_hooks () in
  let disposal_hooks = rollback_hooks @ pure_hooks in
  ops.rollback_transaction ();
  ops.clear_computed_nodes ();
  ops.clear_staged_binds ();
  ops.clear_pure_disposal_hooks ();
  ops.clear_timer_refresh_staging ();
  disposal_hooks

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

let commit ops =
  ops.preflight ();
  let commit_hooks = ops.commit_binds () in
  ops.remember_pure_disposal_hooks commit_hooks;
  ops.prepare_signals ();
  ops.commit_transaction ();
  ops.commit_timer_refresh ();
  ops.commit_signals ();
  let disposal_hooks = ops.disposal_hooks () in
  ops.clear_computed_nodes ();
  ops.clear_staged_binds ();
  ops.clear_pure_disposal_hooks ();
  ops.clear_timer_refresh_disposal_hooks ();
  ops.clear_timer_refresh_staged_timers ();
  ops.commit_snapshot ();
  disposal_hooks
