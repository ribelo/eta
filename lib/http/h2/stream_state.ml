(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Admission = Admission
module P_atomic = Atomic

type status = Active | Remote_reset | Complete | Released

type stream = {
  id : int;
  tag : int;
  permit : Admission.permit;
  status : status P_atomic.t;
}

type stats = {
  active : int;
  cancelled : int;
  inflight : int;
  live : int;
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
  admission : Admission.t;
  streams : (int, stream) Hashtbl.t;
  mutable closed : bool;
}

let create ~max_concurrent =
  {
    admission = Admission.create ~max_concurrent;
    streams = Hashtbl.create max_concurrent;
    closed = false;
  }

let id stream = stream.id
let tag stream = stream.tag
let status stream = P_atomic.get stream.status
let is_client_stream_id id = id > 0 && (id land 1) = 1

let cas_status stream seen replace_with =
  P_atomic.compare_and_set stream.status seen replace_with

let open_stream t ~tag =
  if t.closed then Error ()
  else
    match Admission.try_acquire t.admission with
    | Error () -> Error ()
    | Ok permit ->
        let id = Admission.stream_id permit in
        if not (is_client_stream_id id) then
          invalid_arg
            "Eta_http.H2.Stream_state.open_stream: client stream id must be positive odd";
        let stream = { id; tag; permit; status = P_atomic.make Active } in
        Hashtbl.replace t.streams id stream;
        Ok stream

let find t stream_id =
  if t.closed then None else Hashtbl.find_opt t.streams stream_id

let rec mark_remote_reset t stream_id =
  match find t stream_id with
  | None -> ()
  | Some stream -> (
      match status stream with
      | Active ->
          if cas_status stream Active Remote_reset then
            Admission.mark_remote_reset t.admission stream.permit
          else mark_remote_reset t stream_id
      | Remote_reset | Complete | Released -> ())

let rec mark_complete t stream =
  match status stream with
  | Active ->
      if cas_status stream Active Complete then
        Admission.mark_complete t.admission stream.permit
      else mark_complete t stream
  | Remote_reset | Complete | Released -> ()

let release_result = function
  | Admission.Queue_rst -> Queue_rst
  | Admission.No_rst -> No_rst

let rec release t stream =
  match status stream with
  | Released -> No_rst
  | Active ->
      if cas_status stream Active Released then (
        Hashtbl.remove t.streams stream.id;
        release_result (Admission.release t.admission stream.permit))
      else release t stream
  | Remote_reset ->
      if cas_status stream Remote_reset Released then (
        Hashtbl.remove t.streams stream.id;
        release_result (Admission.release t.admission stream.permit))
      else release t stream
  | Complete ->
      if cas_status stream Complete Released then (
        Hashtbl.remove t.streams stream.id;
        release_result (Admission.release t.admission stream.permit))
      else release t stream

let close t =
  if not t.closed then (
    t.closed <- true;
    Hashtbl.iter
      (fun _ stream -> P_atomic.set stream.status Released)
      t.streams;
    Hashtbl.clear t.streams;
    Admission.close t.admission)

let stats t =
  let admission = Admission.stats t.admission in
  {
    active = admission.active;
    cancelled = admission.cancelled;
    inflight = admission.inflight;
    live = Hashtbl.length t.streams;
    opened = admission.opened;
    completed = admission.completed;
    local_resets = admission.local_resets;
    remote_resets = admission.remote_resets;
    admission_rejected = admission.admission_rejected;
    max_inflight = admission.max_inflight;
    max_concurrent = admission.max_concurrent;
  }
