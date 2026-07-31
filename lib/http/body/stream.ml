(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Error

type read_result = Chunk of bytes | Last of bytes | End

type 'a operation_result = Completed of 'a | Concurrent

type t = {
  read_next : (unit -> (read_result operation_result, Error.t) Effect.t);
  release : (unit -> (unit operation_result, Error.t) Effect.t);
  mutable released : bool;
  active : bool Atomic.t;
}

let concurrent_use () =
  Error.make ~method_:"*" ~uri:"*"
    (Decode_error
       {
         codec = "body-stream";
         message = "concurrent body stream operation";
       })

let defer operation = Effect.sync operation |> Effect.bind Fun.id

let with_operation t operation =
  Effect.sync (fun () -> Atomic.compare_and_set t.active false true)
  |> Effect.bind (fun acquired ->
         if not acquired then Effect.pure Concurrent
         else
           defer operation
           |> Effect.finally (Effect.sync (fun () -> Atomic.set t.active false)))

let release_once t =
  if t.released then Effect.pure (Completed ())
  else (
    t.released <- true;
    defer t.release
    |> Effect.map (function
         | Concurrent ->
             t.released <- false;
             Concurrent
         | Completed () -> Completed ()))

let make ~release read_next =
  {
    read_next;
    release;
    released = false;
    active = Atomic.make false;
  }

let empty () =
  make
    ~release:(fun () -> Effect.pure (Completed ()))
    (fun () -> Effect.pure (Completed End))

let of_reader ?(release = fun () -> Effect.unit) (read_next) =
  make
    ~release:(fun () -> defer release |> Effect.map (fun () -> Completed ()))
    (fun () -> defer read_next |> Effect.map (fun result -> Completed result))

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

let exact_length_error ~declared ~observed =
  Error.make ~method_:"*" ~uri:"*"
    (Connection_protocol_violation
       {
         kind = "request_body_length";
         message =
           Printf.sprintf
             "declared request body length %d does not match emitted byte count \
              %d"
             declared observed;
       })

let enforce_exact_length ~length t =
  if length < 0 then
    invalid_arg "Eta_http.Body.Stream.enforce_exact_length: length must be >= 0";
  let remaining = ref length in
  let observed = ref 0 in
  let mismatch next_observed =
    Effect.fail
      (exact_length_error ~declared:length ~observed:next_observed)
  in
  let add_observed chunk_length =
    if chunk_length > max_int - !observed then max_int
    else !observed + chunk_length
  in
  let read_next () =
    with_operation t
      (fun () ->
        if t.released then
          if !remaining = 0 then Effect.pure (Completed End)
          else mismatch !observed
        else
          t.read_next ()
          |> Effect.bind (function
               | Concurrent -> Effect.pure Concurrent
               | Completed End ->
                   if !remaining = 0 then Effect.pure (Completed End)
                   else mismatch !observed
               | Completed (Chunk chunk) ->
                   let chunk_length = Bytes.length chunk in
                   let next_observed = add_observed chunk_length in
                   if chunk_length > !remaining then mismatch next_observed
                   else (
                     observed := next_observed;
                     remaining := !remaining - chunk_length;
                     Effect.pure (Completed (Chunk chunk)))
               | Completed (Last chunk) ->
                   let chunk_length = Bytes.length chunk in
                   let next_observed = add_observed chunk_length in
                   if chunk_length <> !remaining then mismatch next_observed
                   else (
                     observed := next_observed;
                     remaining := 0;
                     Effect.pure (Completed (Last chunk)))))
  in
  make
    ~release:(fun () -> with_operation t (fun () -> release_once t))
    read_next

let default_max_bytes = 1_048_576

let read_unlocked t =
  if t.released then Effect.pure (Completed None)
  else
    Effect.sync (fun () -> ref true)
    |> Effect.bind (fun release_needed ->
           let release_if_needed =
             Effect.sync (fun () -> !release_needed)
             |> Effect.bind (fun needed ->
                    if needed then
                      release_once t |> Effect.map (fun _ -> ())
                    else Effect.unit)
           in
           defer t.read_next
           |> Effect.bind (function
                | Concurrent -> Effect.pure Concurrent
                | Completed End -> Effect.pure (Completed None)
                | Completed (Chunk chunk) ->
                    release_needed := false;
                    Effect.pure (Completed (Some chunk))
                | Completed (Last chunk) ->
                    Effect.pure (Completed (Some chunk)))
           |> Effect.on_exit (function
                | Exit.Ok Concurrent -> Effect.unit
                | Exit.Ok (Completed _) | Exit.Error _ -> release_if_needed))

let expose_operation result =
  result
  |> Effect.bind (function
       | Completed value -> Effect.pure value
       | Concurrent -> Effect.fail (concurrent_use ()))

let read t =
  with_operation t (fun () -> read_unlocked t) |> expose_operation

let body_too_large ~limit ~length =
  Error.make ~method_:"*" ~uri:"*" (Body_too_large { limit; length })

let read_all ?(max_bytes = default_max_bytes) t =
  if max_bytes < 0 then
    invalid_arg "Eta_http.Body.Stream.read_all: max_bytes must be >= 0";
  let rec loop acc total =
    read_unlocked t
    |> Effect.bind (function
         | Concurrent -> Effect.pure Concurrent
         | Completed None ->
             let out = Bytes.create total in
             let _ =
               List.fold_left
                 (fun off chunk ->
                   let len = Bytes.length chunk in
                   Bytes.blit chunk 0 out off len;
                   off + len)
                 0 (List.rev acc)
             in
             Effect.pure (Completed out)
         | Completed (Some chunk) ->
             let length = total + Bytes.length chunk in
             if length < total || length > max_bytes then
               Effect.fail (body_too_large ~limit:max_bytes ~length)
             else loop (chunk :: acc) length)
  in
  with_operation t
    (fun () ->
      loop [] 0
      |> Effect.on_exit (function
           | Exit.Ok Concurrent -> Effect.unit
           | Exit.Ok (Completed _) | Exit.Error _ ->
               release_once t |> Effect.map (fun _ -> ())))
  |> expose_operation

let discard t =
  with_operation t (fun () -> release_once t) |> expose_operation
