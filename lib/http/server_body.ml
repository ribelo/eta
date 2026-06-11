(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Server_error

type t = {
  read_next : unit -> (bytes option, Error.t) Effect.t;
  release : unit -> (unit, Error.t) Effect.t;
  discard_unread : drain:bool -> (unit, Error.t) Effect.t;
  mutable released : bool;
  active : bool Atomic.t;
}

let concurrent_use () =
  Error.make ~method_:"*" ~target:"*"
    (Protocol_error
       {
         kind = "body_concurrent_use";
         message = "concurrent server body operation";
       })

let with_operation t eff =
  if not (Atomic.compare_and_set t.active false true) then
    Effect.fail (concurrent_use ())
  else
    eff |> Effect.finally (Effect.sync (fun () -> Atomic.set t.active false))

let release_once t =
  if t.released then Effect.unit
  else (
    t.released <- true;
    t.release ())

let empty () =
  {
    read_next = (fun () -> Effect.pure None);
    release = (fun () -> Effect.unit);
    discard_unread = (fun ~drain:_ -> Effect.unit);
    released = false;
    active = Atomic.make false;
  }

let of_reader ?(release = fun () -> Effect.unit)
    ?(discard = fun ~drain:_ -> Effect.unit) read_next =
  {
    read_next;
    release;
    discard_unread = discard;
    released = false;
    active = Atomic.make false;
  }

let read_unlocked t =
  if t.released then Effect.pure None
  else
    t.read_next ()
    |> Effect.bind (function
         | None -> release_once t |> Effect.map (fun () -> None)
         | Some chunk -> Effect.pure (Some chunk))

let read t = with_operation t (read_unlocked t)

let body_too_large ~limit ~length =
  Error.make ~method_:"*" ~target:"*"
    (Request_body_too_large { limit; length })

let read_all ?(max_bytes = Stream.default_max_bytes) t =
  if max_bytes < 0 then
    invalid_arg "Eta_http.Server.Body.read_all: max_bytes must be >= 0";
  let rec loop acc total =
    read_unlocked t
    |> Effect.bind (function
         | None ->
             let out = Bytes.create total in
             let _ =
               List.fold_left
                 (fun off chunk ->
                   let len = Bytes.length chunk in
                   Bytes.blit chunk 0 out off len;
                   off + len)
                 0 (List.rev acc)
             in
             Effect.pure out
         | Some chunk ->
             let length = total + Bytes.length chunk in
             if length < total || length > max_bytes then
               Effect.fail (body_too_large ~limit:max_bytes ~length)
             else loop (chunk :: acc) length)
  in
  with_operation t
    (Effect.scoped
       (Effect.acquire_release ~acquire:Effect.unit
          ~release:(fun () -> release_once t)
       |> Effect.bind (fun () -> loop [] 0)))

let discard ?(drain = false) t =
  with_operation t
    (if t.released then Effect.unit
     else (
       t.released <- true;
       t.discard_unread ~drain))
