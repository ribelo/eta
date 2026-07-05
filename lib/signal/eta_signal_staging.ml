type reset_context = Reset_context
type commit_context = Commit_context

type 'hook reset = {
  rollback_binds : reset_context -> 'hook list;
  pure_disposal_hooks : reset_context -> 'hook list;
  rollback_transaction : reset_context -> unit;
  clear_staging : reset_context -> unit;
}

let reset_ops ~rollback_binds ~pure_disposal_hooks ~rollback_transaction
    ~clear_staging =
  {
    rollback_binds;
    pure_disposal_hooks;
    rollback_transaction;
    clear_staging;
  }

let reset ops =
  let context = Reset_context in
  let rollback_hooks = ops.rollback_binds context in
  let pure_hooks = ops.pure_disposal_hooks context in
  let disposal_hooks = rollback_hooks @ pure_hooks in
  ops.rollback_transaction context;
  ops.clear_staging context;
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
  clear_staging : commit_context -> unit;
  commit_snapshot : commit_context -> unit;
}

let commit_ops ~preflight ~commit_binds ~remember_pure_disposal_hooks
    ~prepare_signals ~commit_transaction ~commit_timer_refresh
    ~commit_signals ~disposal_hooks ~clear_staging ~commit_snapshot =
  {
    preflight;
    commit_binds;
    remember_pure_disposal_hooks;
    prepare_signals;
    commit_transaction;
    commit_timer_refresh;
    commit_signals;
    disposal_hooks;
    clear_staging;
    commit_snapshot;
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
  ops.clear_staging context;
  ops.commit_snapshot context;
  disposal_hooks
