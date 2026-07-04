type catch_up_policy =
  | Catch_up_every_cadence
  | Catch_up_once_per_wake
  | Catch_up_coalesced

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
