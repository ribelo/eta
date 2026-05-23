(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type protocol = H1 | H2

type pending = { id : int }

type state =
  | Empty
  | Pending of pending
  | Ready of protocol

type begin_result =
  | Leader of pending
  | Wait of pending
  | Ready of protocol

type resolve_result =
  | Installed of protocol
  | Already_ready of protocol
  | Ignored

type stats = {
  leaders : int;
  waiters : int;
  redundant_cancelled : int;
  h1_resolved : int;
  h2_resolved : int;
}

type t = {
  mutable next_pending_id : int;
  mutable state : state;
  mutable leaders : int;
  mutable waiters : int;
  mutable redundant_cancelled : int;
  mutable h1_resolved : int;
  mutable h2_resolved : int;
}

let create () =
  {
    next_pending_id = 1;
    state = Empty;
    leaders = 0;
    waiters = 0;
    redundant_cancelled = 0;
    h1_resolved = 0;
    h2_resolved = 0;
  }

let pending_id pending = pending.id

let begin_request t =
  match t.state with
  | Ready protocol -> Ready protocol
  | Pending pending ->
      t.waiters <- t.waiters + 1;
      t.redundant_cancelled <- t.redundant_cancelled + 1;
      Wait pending
  | Empty ->
      let pending = { id = t.next_pending_id } in
      t.next_pending_id <- t.next_pending_id + 1;
      t.state <- Pending pending;
      t.leaders <- t.leaders + 1;
      Leader pending

let record_resolution t = function
  | H1 -> t.h1_resolved <- t.h1_resolved + 1
  | H2 -> t.h2_resolved <- t.h2_resolved + 1

let same_pending left right = left.id = right.id

let resolve t pending protocol =
  match t.state with
  | Empty -> Ignored
  | Ready ready -> Already_ready ready
  | Pending current when same_pending pending current ->
      t.state <- Ready protocol;
      record_resolution t protocol;
      Installed protocol
  | Pending _ -> Ignored

let cancel t pending =
  match t.state with
  | Pending current when same_pending pending current -> t.state <- Empty
  | Empty | Ready _ | Pending _ -> ()

let protocol_of_alpn = function
  | Some "h2" -> Ok H2
  | Some "http/1.1" | None -> Ok H1
  | Some protocol -> Error protocol

let stats t =
  {
    leaders = t.leaders;
    waiters = t.waiters;
    redundant_cancelled = t.redundant_cancelled;
    h1_resolved = t.h1_resolved;
    h2_resolved = t.h2_resolved;
  }
