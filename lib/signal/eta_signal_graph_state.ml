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
  let hooks =
    Eta_signal_staging.reset
    {
      rollback_binds =
        (fun _context ->
          List.concat_map context.reset_rollback_bind t.staged_binds);
      pure_disposal_hooks = (fun _context -> t.pure_disposal_hooks);
      rollback_transaction =
        (fun _context -> context.reset_rollback_transaction ());
      clear_computed_nodes = (fun _context -> t.computed_nodes <- []);
      clear_staged_binds = (fun _context -> t.staged_binds <- []);
      clear_pure_disposal_hooks =
        (fun _context -> t.pure_disposal_hooks <- []);
      clear_timer_refresh_staging =
        (fun _context ->
          clear_timer_refresh_staging t
            ~rollback_dirty:context.reset_rollback_timer_refresh_dirty
            ~clear_timer:context.reset_clear_timer_refresh_timer);
    }
  in
  clear_staging_token t staging;
  hooks

type ('bind, 'node, 'hook, 'timer) commit_context = {
  commit_preflight : unit -> unit;
  commit_bind : 'bind -> 'hook list;
  commit_prepare_signal : 'node -> unit;
  commit_transaction : unit -> unit;
  commit_timer_refresh : 'timer -> unit;
  commit_signal : 'node -> unit;
  commit_advance_snapshot : int -> int;
}

let commit_context ~preflight ~commit_bind ~prepare_signal
    ~commit_transaction ~commit_timer_refresh ~commit_signal
    ~advance_snapshot =
  {
    commit_preflight = preflight;
    commit_bind;
    commit_prepare_signal = prepare_signal;
    commit_transaction;
    commit_timer_refresh;
    commit_signal;
    commit_advance_snapshot = advance_snapshot;
  }

let commit_staging t staging context =
  validate_staging t staging;
  let hooks =
    Eta_signal_staging.commit
    {
      preflight = (fun _context -> context.commit_preflight ());
      commit_binds =
        (fun _context -> List.concat_map context.commit_bind t.staged_binds);
      remember_pure_disposal_hooks =
        (fun _context hooks -> remember_pure_disposal_hooks t staging hooks);
      prepare_signals =
        (fun _context -> List.iter context.commit_prepare_signal t.computed_nodes);
      commit_transaction = (fun _context -> context.commit_transaction ());
      commit_timer_refresh =
        (fun _context ->
          List.iter context.commit_timer_refresh t.timer_refresh_staged_timers);
      commit_signals =
        (fun _context -> List.iter context.commit_signal t.computed_nodes);
      disposal_hooks =
        (fun _context ->
          t.pure_disposal_hooks @ t.timer_refresh_disposal_hooks);
      clear_computed_nodes = (fun _context -> t.computed_nodes <- []);
      clear_staged_binds = (fun _context -> t.staged_binds <- []);
      clear_pure_disposal_hooks =
        (fun _context -> t.pure_disposal_hooks <- []);
      clear_timer_refresh_disposal_hooks =
        (fun _context -> t.timer_refresh_disposal_hooks <- []);
      clear_timer_refresh_staged_timers =
        (fun _context -> t.timer_refresh_staged_timers <- []);
      commit_snapshot =
        (fun _context ->
          t.pure_snapshot_commit_count <-
            context.commit_advance_snapshot t.pure_snapshot_commit_count);
    }
  in
  clear_staging_token t staging;
  hooks

let pure_snapshot_commit_count t = t.pure_snapshot_commit_count

let set_pure_snapshot_commit_count t count =
  t.pure_snapshot_commit_count <- count
