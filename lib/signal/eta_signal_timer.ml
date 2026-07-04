type catch_up_policy =
  | Catch_up_every_cadence
  | Catch_up_once_per_wake
  | Catch_up_coalesced

type state =
  | Timer_inactive of int
  | Timer_starting of int
  | Timer_running_uncancellable of int * int option
  | Timer_running of int * int option * (unit -> unit)
  | Timer_finished of int

type snapshot = {
  state : state;
  on_demand_refresh_token : int;
}

type ('runtime, 'dirty) refresh_context = {
  refresh_token : int;
  refresh_runtime_contract : 'runtime;
  refresh_now_ms : unit -> int;
  mutable refresh_sample_ms : int option;
  mutable refresh_dirty_items : 'dirty list;
}

type debug_snapshot = {
  debug_state_label : string;
  debug_active : bool;
  debug_running_generation : int option;
  debug_has_cancel : bool;
  debug_finished : bool;
  debug_generation : int;
}

type due_refresh = {
  missed : int;
  saturated_due : bool;
  next_due_ms : int option;
}

type wake_plan = {
  wake_next_due_ms : int;
  wake_saturated_due : bool;
  wake_update_count : int;
  wake_update_missed : int;
}

type update_batch = {
  update_batch_count : int;
  update_batch_remaining : int;
  update_batch_yield : bool;
}

type deadline_refresh = {
  deadline_value : bool;
  deadline_finish : bool;
}

type interval_refresh = {
  interval_value : int option;
  interval_next_due_ms : int option;
  interval_finish : bool;
}

type 'a refresh_plan = {
  refresh_value : 'a option;
  refresh_next_due_ms : int option;
  refresh_finish : bool;
}

type _ refresh_spec =
  | Refresh_current_time : int refresh_spec
  | Refresh_deadline : int -> bool refresh_spec
  | Refresh_interval : int -> int refresh_spec

type 'a source_policy = {
  source_update_on_start : bool;
  source_catch_up_policy : catch_up_policy;
  source_refresh_when_inactive : bool;
  source_refresh_on_demand : 'a refresh_spec option;
}

type demand_action =
  | Demand_none
  | Demand_start
  | Demand_stop

type 'a demand_item = {
  demand_item : 'a;
  demand_necessary : bool;
  demand_effective_state : state;
  demand_current_state : state;
}

type daemon_status =
  | Daemon_continue
  | Daemon_stop

type daemon_exit =
  | Daemon_ok
  | Daemon_error

type stop_plan = {
  stop_state : state;
  stop_cancel_hooks : (unit -> unit) list;
}

type start_plan = {
  start_state : state;
  start_generation : int;
}

type 'a demand_plan =
  | Demand_plan_start of 'a * start_plan
  | Demand_plan_stop of 'a * stop_plan option

type ('start, 'hook) demand_effects = {
  demand_start_attempts : 'start list;
  demand_cancel_hooks : 'hook list;
}

type finish_plan = {
  finish_state : state;
  finish_cancel_hooks : (unit -> unit) list;
}

type 'a refresh_action =
  | Refresh_set of 'a
  | Refresh_advance_due of int
  | Refresh_finish of finish_plan

type advance_next_due_action =
  | Advance_next_due_stop
  | Advance_next_due_stale
  | Advance_next_due_update of state

let saturating_succ value =
  if value = max_int then max_int else value + 1

let add_ms_capped left right =
  if right <= 0 then left
  else if left > max_int - right then max_int
  else left + right

let mul_ms_capped left right =
  if left <= 0 || right <= 0 then 0
  else if left > max_int / right then max_int
  else left * right

let add_int_capped left right =
  if right <= 0 then left
  else if left > max_int - right then max_int
  else left + right

let missed_cadences ~interval_ms ~next_due_ms ~now_ms =
  if now_ms < next_due_ms then 0
  else
    let elapsed = (now_ms - next_due_ms) / interval_ms in
    saturating_succ elapsed

let advance_due next_due_ms interval_ms missed =
  add_ms_capped next_due_ms (mul_ms_capped interval_ms missed)

let initial_next_due_ms ~now_ms ~interval_ms =
  add_ms_capped now_ms interval_ms

let sleep_delay_ms ~now_ms ~next_due_ms =
  if next_due_ms <= now_ms then 0
  else if now_ms < 0 && next_due_ms > max_int + now_ms then max_int
  else next_due_ms - now_ms

let add_relative_deadline now_ms duration_ms =
  if duration_ms <= 0 then Error `Past_deadline
  else if now_ms > max_int - duration_ms then Error `Deadline_overflow
  else Ok (now_ms + duration_ms)

let validate_interval_ms interval_ms =
  if interval_ms <= 0 then Error `Invalid_interval else Ok ()

let validate_future_deadline ~now_ms ~deadline_ms =
  if deadline_ms <= now_ms then Error `Past_deadline else Ok ()

let validate_positive_duration_ms duration_ms =
  if duration_ms <= 0 then Error `Past_deadline else Ok ()

let source_policy ~update_on_start ~catch_up_policy ~refresh_when_inactive
    ~refresh_on_demand =
  {
    source_update_on_start = update_on_start;
    source_catch_up_policy = catch_up_policy;
    source_refresh_when_inactive = refresh_when_inactive;
    source_refresh_on_demand = refresh_on_demand;
  }

let current_time_source_policy () =
  source_policy ~update_on_start:true
    ~catch_up_policy:Catch_up_once_per_wake
    ~refresh_when_inactive:true
    ~refresh_on_demand:(Some Refresh_current_time)

let deadline_source_policy ~deadline_ms =
  source_policy ~update_on_start:true
    ~catch_up_policy:Catch_up_once_per_wake
    ~refresh_when_inactive:true
    ~refresh_on_demand:(Some (Refresh_deadline deadline_ms))

let interval_source_policy ~interval_ms =
  source_policy ~update_on_start:false
    ~catch_up_policy:Catch_up_coalesced
    ~refresh_when_inactive:false
    ~refresh_on_demand:(Some (Refresh_interval interval_ms))

let step_source_policy () =
  source_policy ~update_on_start:false
    ~catch_up_policy:Catch_up_coalesced
    ~refresh_when_inactive:false ~refresh_on_demand:None

let step_replay_source_policy () =
  source_policy ~update_on_start:false
    ~catch_up_policy:Catch_up_every_cadence
    ~refresh_when_inactive:false ~refresh_on_demand:None

let catch_up_update_count policy missed =
  match policy with
  | Catch_up_every_cadence -> missed
  | Catch_up_once_per_wake -> if missed <= 0 then 0 else 1
  | Catch_up_coalesced -> if missed <= 0 then 0 else 1

let catch_up_update_missed policy missed =
  match policy with
  | Catch_up_every_cadence | Catch_up_once_per_wake -> 1
  | Catch_up_coalesced -> missed

let update_batch_size = 64

let update_batch ~remaining =
  if remaining <= 0 then None
  else
    let update_batch_count = min remaining update_batch_size in
    let update_batch_remaining = remaining - update_batch_count in
    Some
      {
        update_batch_count;
        update_batch_remaining;
        update_batch_yield = update_batch_remaining > 0;
      }

let daemon_wake_plan ~catch_up_policy ~interval_ms ~next_due_ms ~now_ms =
  let missed = missed_cadences ~interval_ms ~next_due_ms ~now_ms in
  let wake_next_due_ms = advance_due next_due_ms interval_ms missed in
  let wake_update_count = catch_up_update_count catch_up_policy missed in
  {
    wake_next_due_ms;
    wake_saturated_due =
      wake_next_due_ms = max_int && now_ms >= wake_next_due_ms;
    wake_update_count;
    wake_update_missed =
      (if wake_update_count <= 0 then 0
       else catch_up_update_missed catch_up_policy missed);
  }

let state_generation = function
  | Timer_inactive generation
  | Timer_starting generation
  | Timer_running_uncancellable (generation, _)
  | Timer_running (generation, _, _)
  | Timer_finished generation ->
      generation

let state_with_generation state generation =
  match state with
  | Timer_inactive _ -> Timer_inactive generation
  | Timer_starting _ -> Timer_starting generation
  | Timer_running_uncancellable (_, next_due_ms) ->
      Timer_running_uncancellable (generation, next_due_ms)
  | Timer_running (_, next_due_ms, cancel) ->
      Timer_running (generation, next_due_ms, cancel)
  | Timer_finished _ -> Timer_finished generation

let snapshot ~state ~on_demand_refresh_token =
  { state; on_demand_refresh_token }

let initial_snapshot =
  snapshot ~state:(Timer_inactive 0) ~on_demand_refresh_token:(-1)

let snapshot_state snapshot = snapshot.state

let snapshot_on_demand_refresh_token snapshot =
  snapshot.on_demand_refresh_token

let snapshot_with_state snapshot state = { snapshot with state }

let snapshot_with_generation snapshot generation =
  snapshot_with_state snapshot
    (state_with_generation snapshot.state generation)

let snapshot_with_on_demand_refresh_token snapshot token =
  { snapshot with on_demand_refresh_token = token }

let snapshot_with_next_due snapshot next_due_ms =
  match snapshot.state with
  | Timer_running_uncancellable (generation, _) ->
      Some
        {
          snapshot with
          state = Timer_running_uncancellable (generation, Some next_due_ms);
        }
  | Timer_running (generation, _, cancel) ->
      Some
        {
          snapshot with
          state = Timer_running (generation, Some next_due_ms, cancel);
        }
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> None

let create_refresh_context ~token ~runtime_contract ~now_ms =
  {
    refresh_token = token;
    refresh_runtime_contract = runtime_contract;
    refresh_now_ms = now_ms;
    refresh_sample_ms = None;
    refresh_dirty_items = [];
  }

let refresh_token context = context.refresh_token

let refresh_runtime_contract context = context.refresh_runtime_contract

let refresh_sample_now_ms context =
  match context.refresh_sample_ms with
  | Some now_ms -> now_ms
  | None ->
      let now_ms = context.refresh_now_ms () in
      context.refresh_sample_ms <- Some now_ms;
      now_ms

let refresh_dirty_items context = context.refresh_dirty_items

let set_refresh_dirty_items context items =
  context.refresh_dirty_items <- items

let clear_refresh_dirty_items context =
  context.refresh_dirty_items <- []

let state_label = function
  | Timer_inactive _ -> "inactive"
  | Timer_starting _ -> "starting"
  | Timer_running_uncancellable _ -> "running_uncancellable"
  | Timer_running _ -> "running"
  | Timer_finished _ -> "finished"

let state_active = function
  | Timer_starting _ | Timer_running_uncancellable _ | Timer_running _ -> true
  | Timer_inactive _ | Timer_finished _ -> false

let state_finished = function
  | Timer_finished _ -> true
  | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
  | Timer_running _ ->
      false

let state_has_current_start = function
  | Timer_running_uncancellable _ | Timer_running _ -> true
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> false

let state_running_generation = function
  | Timer_running_uncancellable (generation, _)
  | Timer_running (generation, _, _) ->
      Some generation
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> None

let state_has_cancel = function
  | Timer_running (_, _, _) -> true
  | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
  | Timer_finished _ ->
      false

let state_running_current state generation =
  match state with
  | Timer_running_uncancellable (running_generation, _)
  | Timer_running (running_generation, _, _) ->
      running_generation = generation
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> false

let state_next_due = function
  | Timer_running_uncancellable (_, next_due_ms)
  | Timer_running (_, next_due_ms, _) ->
      next_due_ms
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> None

let state_set_next_due state next_due_ms =
  match state with
  | Timer_running_uncancellable (generation, _) ->
      Timer_running_uncancellable (generation, next_due_ms)
  | Timer_running (generation, _, cancel) ->
      Timer_running (generation, next_due_ms, cancel)
  | Timer_inactive _ | Timer_starting _ | Timer_finished _ -> state

let debug_snapshot state =
  {
    debug_state_label = state_label state;
    debug_active = state_active state;
    debug_running_generation = state_running_generation state;
    debug_has_cancel = state_has_cancel state;
    debug_finished = state_finished state;
    debug_generation = state_generation state;
  }

let daemon_status state ~generation =
  if state_running_current state generation then Daemon_continue
  else Daemon_stop

let needs_start ~effective_state ~current_state =
  not
    (state_finished effective_state
    || (state_active effective_state && state_has_current_start current_state))

let needs_stop ~effective_state =
  state_active effective_state
  || Option.is_some (state_running_generation effective_state)
  || state_has_cancel effective_state

let demand_action ~necessary ~effective_state ~current_state =
  if necessary then
    if needs_start ~effective_state ~current_state then Demand_start
    else Demand_none
  else if needs_stop ~effective_state then Demand_stop
  else Demand_none

let start ~advance_generation ~effective_state ~current_state =
  if needs_start ~effective_state ~current_state then
    let generation = advance_generation (state_generation current_state) in
    Some
      {
        start_state = Timer_starting generation;
        start_generation = generation;
      }
  else None

let preflight_start ~advance_generation ~effective_state ~current_state =
  ignore
    (start ~advance_generation ~effective_state ~current_state
      : start_plan option)

let preflight_stop ~advance_generation ~effective_state ~current_state =
  if needs_stop ~effective_state then
    ignore (advance_generation (state_generation current_state) : int)

let begin_start state ~generation =
  match state with
  | Timer_starting starting_generation when starting_generation = generation ->
      Some (Timer_running_uncancellable (generation, None))
  | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
  | Timer_running _ | Timer_finished _ ->
      None

let install_cancel state ~generation ~cancel =
  match state with
  | Timer_running_uncancellable (running_generation, next_due_ms)
    when running_generation = generation ->
      Some (Timer_running (generation, next_due_ms, cancel))
  | Timer_running (running_generation, next_due_ms, _)
    when running_generation = generation ->
      Some (Timer_running (generation, next_due_ms, cancel))
  | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
  | Timer_running _ | Timer_finished _ ->
      None

let mark_stopped state ~generation =
  if state_running_current state generation then Some (Timer_inactive generation)
  else None

let stop ~advance_generation ~cancel_running state =
  match state with
  | Timer_inactive _ | Timer_finished _ -> None
  | Timer_starting _ | Timer_running_uncancellable _ ->
      Some
        {
          stop_state =
            Timer_inactive (advance_generation (state_generation state));
          stop_cancel_hooks = [];
        }
  | Timer_running (_, _, cancel) ->
      Some
        {
          stop_state =
            Timer_inactive (advance_generation (state_generation state));
          stop_cancel_hooks = (if cancel_running then [ cancel ] else []);
        }

let demand_plans ~advance_generation ~cancel_running items =
  List.filter_map
    (fun item ->
      match
        demand_action ~necessary:item.demand_necessary
          ~effective_state:item.demand_effective_state
          ~current_state:item.demand_current_state
      with
      | Demand_none -> None
      | Demand_start ->
          start ~advance_generation
            ~effective_state:item.demand_effective_state
            ~current_state:item.demand_current_state
          |> Option.map (fun plan ->
                 Demand_plan_start (item.demand_item, plan))
      | Demand_stop ->
          Some
            (Demand_plan_stop
               ( item.demand_item,
                 stop ~advance_generation ~cancel_running
                   item.demand_current_state )))
    items

let apply_demand_plans ~start ~stop plans =
  let start_attempts = ref [] in
  let cancel_hooks = ref [] in
  List.iter
    (function
      | Demand_plan_start (timer, plan) ->
          start_attempts := start timer plan :: !start_attempts
      | Demand_plan_stop (timer, Some plan) ->
          cancel_hooks := List.rev_append (stop timer plan) !cancel_hooks
      | Demand_plan_stop (_, None) -> ())
    plans;
  {
    demand_start_attempts = List.rev !start_attempts;
    demand_cancel_hooks = List.rev !cancel_hooks;
  }

let mark_failed ~advance_generation ~effective_state ~current_state ~generation
    =
  if state_running_current effective_state generation then
    match stop ~advance_generation ~cancel_running:false current_state with
    | Some plan -> Some plan.stop_state
    | None -> None
  else None

let cleanup_after_exit ~advance_generation ~effective_state ~current_state
    ~generation = function
  | Daemon_ok -> mark_stopped effective_state ~generation
  | Daemon_error ->
      mark_failed ~advance_generation ~effective_state ~current_state
        ~generation

let cleanup_failed_start ~advance_generation ~effective_state ~current_state
    ~generation = function
  | Daemon_ok -> None
  | Daemon_error ->
      mark_failed ~advance_generation ~effective_state ~current_state
        ~generation

let finish_state ~advance_generation state =
  let generation =
    if state_active state then advance_generation (state_generation state)
    else state_generation state
  in
  Timer_finished generation

let finish_current_daemon ~advance_generation ~effective_state ~current_state
    ~generation =
  match daemon_status effective_state ~generation with
  | Daemon_continue -> Some (finish_state ~advance_generation current_state)
  | Daemon_stop -> None

let read_next_due state ~generation ~fallback =
  if state_running_current state generation then
    Some (Option.value (state_next_due state) ~default:fallback)
  else None

let set_next_due ~effective_state ~current_state ~generation ~next_due_ms =
  if state_running_current effective_state generation then
    Some (state_set_next_due current_state (Some next_due_ms))
  else None

let advance_next_due ~effective_state ~current_state ~generation ~expected
    ~next_due_ms =
  if state_running_current effective_state generation then
    match state_next_due effective_state with
    | Some current when current = expected ->
        Advance_next_due_update
          (state_set_next_due current_state (Some next_due_ms))
    | Some _ | None -> Advance_next_due_stale
  else Advance_next_due_stop

let can_refresh_on_demand ~refresh_operation ~current_token ~staged_token ~token
    ~refresh_when_inactive ~active ~finished =
  refresh_operation && current_token <> token && staged_token <> token
  && (refresh_when_inactive || active)
  && not finished

let finish_cancel_hooks = function
  | Timer_running (_, _, cancel) -> [ cancel ]
  | Timer_inactive _ | Timer_starting _ | Timer_running_uncancellable _
  | Timer_finished _ ->
      []

let finish ~advance_generation state =
  {
    finish_state = finish_state ~advance_generation state;
    finish_cancel_hooks = finish_cancel_hooks state;
  }

let due_refresh state ~interval_ms ~now_ms =
  match state_next_due state with
  | None -> { missed = 0; saturated_due = false; next_due_ms = None }
  | Some next_due_ms ->
      let missed = missed_cadences ~interval_ms ~next_due_ms ~now_ms in
      if missed <= 0 then
        { missed = 0; saturated_due = false; next_due_ms = None }
      else
        let advanced_due_ms = advance_due next_due_ms interval_ms missed in
        let saturated_due =
          advanced_due_ms = max_int && now_ms >= advanced_due_ms
        in
        { missed; saturated_due; next_due_ms = Some advanced_due_ms }

let deadline_refresh ~now_ms ~deadline_ms =
  let reached = now_ms >= deadline_ms in
  { deadline_value = reached; deadline_finish = reached }

let interval_refresh ~state ~interval_ms ~current_value ~now_ms =
  let due = due_refresh state ~interval_ms ~now_ms in
  {
    interval_value =
      (if due.missed <= 0 then None
       else Some (add_int_capped current_value due.missed));
    interval_next_due_ms = due.next_due_ms;
    interval_finish = due.saturated_due;
  }

let current_time_refresh_plan ~now_ms =
  {
    refresh_value = Some now_ms;
    refresh_next_due_ms = None;
    refresh_finish = false;
  }

let refresh_actions ~advance_generation ~state refresh =
  let due_transitions =
    match refresh.refresh_next_due_ms with
    | None -> []
    | Some next_due_ms -> [ Refresh_advance_due next_due_ms ]
  in
  let source_transitions =
    match refresh.refresh_value with
    | None -> []
    | Some value -> [ Refresh_set value ]
  in
  due_transitions @ source_transitions
  @
  (if refresh.refresh_finish then
     [ Refresh_finish (finish ~advance_generation state) ]
   else [])

let deadline_refresh_plan ~now_ms ~deadline_ms =
  let refresh = deadline_refresh ~now_ms ~deadline_ms in
  {
    refresh_value = Some refresh.deadline_value;
    refresh_next_due_ms = None;
    refresh_finish = refresh.deadline_finish;
  }

let interval_refresh_plan ~state ~interval_ms ~current_value ~now_ms =
  let refresh = interval_refresh ~state ~interval_ms ~current_value ~now_ms in
  {
    refresh_value = refresh.interval_value;
    refresh_next_due_ms = refresh.interval_next_due_ms;
    refresh_finish = refresh.interval_finish;
  }

let refresh_plan_for_spec : type a.
    state:state -> current_value:a -> now_ms:int -> a refresh_spec -> a refresh_plan =
 fun ~state ~current_value ~now_ms -> function
  | Refresh_current_time -> current_time_refresh_plan ~now_ms
  | Refresh_deadline deadline_ms ->
      deadline_refresh_plan ~now_ms ~deadline_ms
  | Refresh_interval interval_ms ->
      interval_refresh_plan ~state ~interval_ms ~current_value ~now_ms

let refresh_actions_for_spec ~advance_generation ~state ~current_value ~now_ms
    spec =
  refresh_plan_for_spec ~state ~current_value ~now_ms spec
  |> refresh_actions ~advance_generation ~state
