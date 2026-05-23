(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Eta_http_error.Error

type t = {
  chunks : bytes array;
  release : unit -> (unit, Error.t) Effect.t;
  mutable next : int;
  mutable released : bool;
}

let empty () = { chunks = [||]; release = (fun () -> Effect.unit); next = 0; released = false }

let of_bytes ?(release = fun () -> Effect.unit) chunks =
  { chunks = Array.of_list chunks; release; next = 0; released = false }

let release_once t =
  if t.released then Effect.unit
  else (
    t.released <- true;
    t.release ())

let read t =
  Effect.sync (fun () ->
      if t.released || t.next >= Array.length t.chunks then None
      else
        let chunk = Bytes.copy t.chunks.(t.next) in
        t.next <- t.next + 1;
        Some (chunk, t.next >= Array.length t.chunks))
  |> Effect.bind (function
       | None -> release_once t |> Effect.map (fun () -> None)
       | Some (chunk, last) ->
           (if last then release_once t else Effect.unit)
           |> Effect.map (fun () -> Some chunk))

let read_all t =
  let rec loop acc total =
    read t
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
         | Some chunk -> loop (chunk :: acc) (total + Bytes.length chunk))
  in
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () -> release_once t)
    |> Effect.bind (fun () -> loop [] 0))

let discard = release_once
