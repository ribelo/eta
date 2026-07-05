type reset_context = Reset_context
type commit_context = Commit_context

type 'hook reset = {
  rollback_binds : reset_context -> 'hook list;
  pure_disposal_hooks : reset_context -> 'hook list;
  rollback_transaction : reset_context -> unit;
  clear_computed_nodes : reset_context -> unit;
  clear_staged_binds : reset_context -> unit;
  clear_pure_disposal_hooks : reset_context -> unit;
  clear_timer_refresh_staging : reset_context -> unit;
}

let reset ops =
  let context = Reset_context in
  let rollback_hooks = ops.rollback_binds context in
  let pure_hooks = ops.pure_disposal_hooks context in
  let disposal_hooks = rollback_hooks @ pure_hooks in
  ops.rollback_transaction context;
  ops.clear_computed_nodes context;
  ops.clear_staged_binds context;
  ops.clear_pure_disposal_hooks context;
  ops.clear_timer_refresh_staging context;
  disposal_hooks

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

let commit ops =
  let context = Commit_context in
  ops.preflight context;
  let commit_hooks = ops.commit_binds context in
  ops.remember_pure_disposal_hooks context commit_hooks;
  ops.prepare_signals context;
  ops.commit_transaction context;
  ops.commit_timer_refresh context;
  ops.commit_signals context;
  let disposal_hooks = ops.disposal_hooks context in
  ops.clear_computed_nodes context;
  ops.clear_staged_binds context;
  ops.clear_pure_disposal_hooks context;
  ops.clear_timer_refresh_disposal_hooks context;
  ops.clear_timer_refresh_staged_timers context;
  ops.commit_snapshot context;
  disposal_hooks
