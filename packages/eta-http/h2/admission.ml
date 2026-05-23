(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type state = Active | Cancelled | Complete | Released

type permit = {
  id : int;
  mutable state : state;
}

type stats = {
  active : int;
  cancelled : int;
  inflight : int;
  opened : int;
  completed : int;
  local_resets : int;
  remote_resets : int;
  admission_rejected : int;
  max_inflight : int;
  max_concurrent : int;
}

type release = Queue_rst | No_rst

type t = {
  max_concurrent : int;
  mutable next_id : int;
  mutable active : int;
  mutable cancelled : int;
  mutable opened : int;
  mutable completed : int;
  mutable local_resets : int;
  mutable remote_resets : int;
  mutable admission_rejected : int;
  mutable max_inflight : int;
  mutable closed : bool;
}

let create ~max_concurrent =
  if max_concurrent <= 0 then
    invalid_arg "Eta_http.H2.Admission.create: max_concurrent must be > 0";
  {
    max_concurrent;
    next_id = 1;
    active = 0;
    cancelled = 0;
    opened = 0;
    completed = 0;
    local_resets = 0;
    remote_resets = 0;
    admission_rejected = 0;
    max_inflight = 0;
    closed = false;
  }

let inflight t = t.active + t.cancelled

let update_max_inflight t =
  t.max_inflight <- max t.max_inflight (inflight t)

let try_acquire t =
  if t.closed || inflight t >= t.max_concurrent then (
    t.admission_rejected <- t.admission_rejected + 1;
    Error ())
  else
    let permit = { id = t.next_id; state = Active } in
    t.next_id <- t.next_id + 2;
    t.active <- t.active + 1;
    t.opened <- t.opened + 1;
    update_max_inflight t;
    Ok permit

let stream_id permit = permit.id

let mark_remote_reset t permit =
  match permit.state with
  | Active ->
      permit.state <- Cancelled;
      t.active <- max 0 (t.active - 1);
      t.cancelled <- t.cancelled + 1;
      t.remote_resets <- t.remote_resets + 1;
      update_max_inflight t
  | Cancelled | Complete | Released -> ()

let mark_complete _t permit =
  match permit.state with
  | Active -> permit.state <- Complete
  | Cancelled | Complete | Released -> ()

let release t permit =
  match permit.state with
  | Active ->
      permit.state <- Released;
      t.active <- max 0 (t.active - 1);
      t.local_resets <- t.local_resets + 1;
      t.completed <- t.completed + 1;
      Queue_rst
  | Cancelled ->
      permit.state <- Released;
      t.cancelled <- max 0 (t.cancelled - 1);
      t.completed <- t.completed + 1;
      No_rst
  | Complete ->
      permit.state <- Released;
      t.active <- max 0 (t.active - 1);
      t.completed <- t.completed + 1;
      No_rst
  | Released -> No_rst

let close t =
  t.closed <- true;
  t.active <- 0;
  t.cancelled <- 0

let stats t =
  {
    active = t.active;
    cancelled = t.cancelled;
    inflight = inflight t;
    opened = t.opened;
    completed = t.completed;
    local_resets = t.local_resets;
    remote_resets = t.remote_resets;
    admission_rejected = t.admission_rejected;
    max_inflight = t.max_inflight;
    max_concurrent = t.max_concurrent;
  }
