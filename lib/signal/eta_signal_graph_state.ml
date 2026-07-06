type staging = Staging of unit ref

type ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t = {
  mutable generation : int;
  mutable pending : 'pending list;
  mutable staged_binds : 'bind list;
  mutable computed_nodes : 'node list;
  mutable pure_disposal_hooks : 'hook list;
  mutable timer_refresh_disposal_hooks : 'hook list;
  mutable timer_refresh_staged_timers : 'timer list;
  mutable pure_snapshot_commit_count : int;
  mutable next_timer_refresh_token : int;
  mutable active_timer_refresh : 'refresh option;
  mutable active_staging : staging option;
}

let create () =
  {
    generation = 0;
    pending = [];
    staged_binds = [];
    computed_nodes = [];
    pure_disposal_hooks = [];
    timer_refresh_disposal_hooks = [];
    timer_refresh_staged_timers = [];
    pure_snapshot_commit_count = 0;
    next_timer_refresh_token = 0;
    active_timer_refresh = None;
    active_staging = None;
  }

let generation t = t.generation
let set_generation t generation = t.generation <- generation
let advance_generation t ~advance = t.generation <- advance t.generation

let staging_matches left right =
  match (left, right) with
  | Staging left, Staging right -> left == right

let validate_staging t staging =
  match t.active_staging with
  | Some active when staging_matches active staging -> ()
  | Some _ -> invalid_arg "Eta_signal graph staging token is not active"
  | None -> invalid_arg "Eta_signal graph staging is not active"

let clear_staging_token t staging =
  validate_staging t staging;
  t.active_staging <- None

let begin_staging t ~timer_refresh =
  (match t.active_staging with
  | None -> ()
  | Some _ -> invalid_arg "Eta_signal graph staging is already active");
  let staging = Staging (ref ()) in
  t.computed_nodes <- [];
  t.staged_binds <- [];
  t.pure_disposal_hooks <- [];
  t.timer_refresh_disposal_hooks <- [];
  t.timer_refresh_staged_timers <- [];
  t.active_timer_refresh <- timer_refresh;
  t.active_staging <- Some staging;
  staging

let require_staging t =
  match t.active_staging with
  | Some staging -> staging
  | None -> invalid_arg "Eta_signal graph staging is not active"

let drain_pending t =
  let pending = List.rev t.pending in
  t.pending <- [];
  pending

let enqueue_pending t pending = t.pending <- pending :: t.pending

let remember_computed t staging ~generation node ~project ~remember =
  validate_staging t staging;
  t.computed_nodes <- remember ~generation t.computed_nodes (project node)

let computed_nodes t = t.computed_nodes

let stage_bind t staging bind =
  validate_staging t staging;
  t.staged_binds <- bind :: t.staged_binds

let staged_binds t = t.staged_binds

let remember_pure_disposal_hooks t staging hooks =
  validate_staging t staging;
  t.pure_disposal_hooks <- hooks @ t.pure_disposal_hooks

let remember_timer_refresh_disposal_hooks t staging hooks =
  validate_staging t staging;
  match t.active_timer_refresh with
  | Some _ ->
      t.timer_refresh_disposal_hooks <-
        hooks @ t.timer_refresh_disposal_hooks
  | None -> remember_pure_disposal_hooks t staging hooks

let active_timer_refresh t = t.active_timer_refresh
let clear_active_timer_refresh t = t.active_timer_refresh <- None

let stage_timer_refresh_timer t staging timer =
  validate_staging t staging;
  t.timer_refresh_staged_timers <- timer :: t.timer_refresh_staged_timers

let next_timer_refresh_token t ~advance =
  let token = t.next_timer_refresh_token in
  t.next_timer_refresh_token <- advance t.next_timer_refresh_token;
  token

let set_next_timer_refresh_token t token =
  t.next_timer_refresh_token <- token

let clear_timer_refresh_staging t ~rollback_dirty ~clear_timer =
  Option.iter rollback_dirty t.active_timer_refresh;
  List.iter clear_timer t.timer_refresh_staged_timers;
  t.timer_refresh_staged_timers <- [];
  t.timer_refresh_disposal_hooks <- []

type ('bind, 'hook, 'timer, 'refresh) reset_context = {
  reset_rollback_bind : 'bind -> 'hook list;
  reset_rollback_transaction : unit -> unit;
  reset_rollback_timer_refresh_dirty : 'refresh -> unit;
  reset_clear_timer_refresh_timer : 'timer -> unit;
}

let reset_context ~rollback_bind ~rollback_transaction
    ~rollback_timer_refresh_dirty ~clear_timer_refresh_timer =
  {
    reset_rollback_bind = rollback_bind;
    reset_rollback_transaction = rollback_transaction;
    reset_rollback_timer_refresh_dirty = rollback_timer_refresh_dirty;
    reset_clear_timer_refresh_timer = clear_timer_refresh_timer;
  }

let reset_staging t staging context =
  validate_staging t staging;
  let rollback_hooks =
    List.concat_map context.reset_rollback_bind t.staged_binds
  in
  let hooks = rollback_hooks @ t.pure_disposal_hooks in
  context.reset_rollback_transaction ();
  t.computed_nodes <- [];
  t.staged_binds <- [];
  t.pure_disposal_hooks <- [];
  clear_timer_refresh_staging t
    ~rollback_dirty:context.reset_rollback_timer_refresh_dirty
    ~clear_timer:context.reset_clear_timer_refresh_timer;
  clear_staging_token t staging;
  hooks

type ('bind, 'hook) bind_commit_plan = {
  bind_commit : 'bind -> 'hook list;
}

let bind_commit_plan ~commit = { bind_commit = commit }

type ('node, 'prepared) signal_commit_plan = {
  signal_prepare : 'node -> 'prepared;
  signal_commit : 'prepared -> unit;
}

let signal_commit_plan ~prepare_signal ~commit_signal =
  { signal_prepare = prepare_signal; signal_commit = commit_signal }

type 'timer timer_commit_plan = {
  timer_commit : 'timer -> unit;
}

let timer_commit_plan ~commit = { timer_commit = commit }

type snapshot_commit_plan = {
  snapshot_commit_transaction : unit -> unit;
  snapshot_advance : int -> int;
}

let snapshot_commit_plan ~commit_transaction ~advance_snapshot =
  {
    snapshot_commit_transaction = commit_transaction;
    snapshot_advance = advance_snapshot;
  }

type ('bind, 'node, 'prepared, 'hook, 'timer) commit_plan = {
  commit_preflight : unit -> unit;
  commit_binds : ('bind, 'hook) bind_commit_plan;
  commit_signals : ('node, 'prepared) signal_commit_plan;
  commit_timers : 'timer timer_commit_plan;
  commit_snapshot : snapshot_commit_plan;
}

let commit_plan ~preflight ~binds ~signals ~timers ~snapshot =
  {
    commit_preflight = preflight;
    commit_binds = binds;
    commit_signals = signals;
    commit_timers = timers;
    commit_snapshot = snapshot;
  }

let commit_staging t staging context =
  validate_staging t staging;
  context.commit_preflight ();
  let bind_hooks =
    List.concat_map context.commit_binds.bind_commit t.staged_binds
  in
  remember_pure_disposal_hooks t staging bind_hooks;
  let signal_commits =
    List.map context.commit_signals.signal_prepare t.computed_nodes
  in
  context.commit_snapshot.snapshot_commit_transaction ();
  List.iter context.commit_timers.timer_commit t.timer_refresh_staged_timers;
  List.iter context.commit_signals.signal_commit signal_commits;
  let hooks = t.pure_disposal_hooks @ t.timer_refresh_disposal_hooks in
  t.computed_nodes <- [];
  t.staged_binds <- [];
  t.pure_disposal_hooks <- [];
  t.timer_refresh_disposal_hooks <- [];
  t.timer_refresh_staged_timers <- [];
  t.pure_snapshot_commit_count <-
    context.commit_snapshot.snapshot_advance t.pure_snapshot_commit_count;
  clear_staging_token t staging;
  hooks

let pure_snapshot_commit_count t = t.pure_snapshot_commit_count

let set_pure_snapshot_commit_count t count =
  t.pure_snapshot_commit_count <- count
