(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Eta_http_error.Error

type read_result = Chunk of bytes | Last of bytes | End

type t = {
  read_next : unit -> (read_result, Error.t) Effect.t;
  release : unit -> (unit, Error.t) Effect.t;
  mutable released : bool;
}

let release_once t =
  if t.released then Effect.unit
  else (
    t.released <- true;
    t.release ())

let empty () =
  {
    read_next = (fun () -> Effect.pure End);
    release = (fun () -> Effect.unit);
    released = false;
  }

let of_reader ?(release = fun () -> Effect.unit) read_next =
  { read_next; release; released = false }

let of_bytes ?(release = fun () -> Effect.unit) chunks =
  let chunks = Array.of_list chunks in
  let next = ref 0 in
  let read_next () =
    if !next >= Array.length chunks then Effect.pure End
    else
      let chunk = Bytes.copy chunks.(!next) in
      incr next;
      if !next >= Array.length chunks then Effect.pure (Last chunk)
      else Effect.pure (Chunk chunk)
  in
  of_reader ~release read_next

let default_max_bytes = 1_048_576

let read t =
  if t.released then Effect.pure None
  else
    t.read_next ()
    |> Effect.catch (fun error ->
           release_once t |> Effect.bind (fun () -> Effect.fail error))
    |> Effect.bind (function
         | End -> release_once t |> Effect.map (fun () -> None)
         | Chunk chunk -> Effect.pure (Some chunk)
         | Last chunk -> release_once t |> Effect.map (fun () -> Some chunk))

let body_too_large ~limit ~length =
  Error.make ~method_:"*" ~uri:"*" (Body_too_large { limit; length })

let read_all ?(max_bytes = default_max_bytes) t =
  if max_bytes < 0 then
    invalid_arg "Eta_http.Body.Stream.read_all: max_bytes must be >= 0";
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
         | Some chunk ->
             let length = total + Bytes.length chunk in
             if length < total || length > max_bytes then
               Effect.fail (body_too_large ~limit:max_bytes ~length)
             else loop (chunk :: acc) length)
  in
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit ~release:(fun () -> release_once t)
    |> Effect.bind (fun () -> loop [] 0))

let discard = release_once
