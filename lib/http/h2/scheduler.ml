(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Simple weighted round-robin scheduler.

    This is intentionally a minimal first implementation: active refs are
    enqueued [weight] times per cycle, giving each ref a number of dispatch
    opportunities proportional to its weight. Dependency-tree scheduling,
    deficit round-robin, exclusive-reprioritization, and stream-id tracking
    are left for a later pass once the connection state machine is solid. *)

type ref = {
  id : int;
  mutable weight : int;
  mutable active : bool;
  mutable queued : int;
}

type t = { q : ref Queue.t }

let next_id =
  let c = Atomic.make 0 in
  fun () -> Atomic.fetch_and_add c 1

let create () = { q = Queue.create () }
let id r = r.id

let open_ref ~id ~parent:_ ~weight ~exclusive:_ =
  let weight = max 1 (min 256 weight) in
  { id; weight; active = false; queued = 0 }

let close_ref r =
  r.active <- false;
  r.queued <- 0

let rebind r ~parent:_ ~weight ~exclusive:_ =
  r.weight <- max 1 (min 256 weight)

let activate t r =
  if not r.active then r.active <- true;
  if r.queued = 0 then (
    for _ = 1 to r.weight do
      Queue.push r t.q
    done;
    r.queued <- r.weight)

let deactivate _t r = r.active <- false
(* Leave queued copies in the queue; [run] will drop them lazily. *)

let run t ~f =
  let continue = ref true in
  while !continue && not (Queue.is_empty t.q) do
    let r = Queue.pop t.q in
    r.queued <- r.queued - 1;
    if r.active then (
      match f r with
      | `Stop -> continue := false
      | `Continue still_active ->
          if still_active then (
            Queue.push r t.q;
            r.queued <- r.queued + 1)
          else r.active <- false)
  done;
  if !continue then `Done else `Stopped

let is_active t =
  let found = ref false in
  let snapshot = Queue.fold (fun acc r -> r :: acc) [] t.q in
  List.iter (fun r -> if r.active then found := true) snapshot;
  !found
