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

let add_relative_deadline now_ms duration_ms =
  if duration_ms <= 0 then Error `Past_deadline
  else if now_ms > max_int - duration_ms then Error `Deadline_overflow
  else Ok (now_ms + duration_ms)

let catch_up_update_count policy missed =
  match policy with
  | Catch_up_every_cadence -> missed
  | Catch_up_once_per_wake -> if missed <= 0 then 0 else 1
  | Catch_up_coalesced -> if missed <= 0 then 0 else 1

let catch_up_update_missed policy missed =
  match policy with
  | Catch_up_every_cadence | Catch_up_once_per_wake -> 1
  | Catch_up_coalesced -> missed

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
