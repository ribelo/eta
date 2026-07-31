(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type replayability = Replayable | Rewindable | One_shot

type t =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | One_shot_stream of {
      length : int;
      stream : Stream.t;
    }
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t);
    }

type owned_stream = {
  length : int option;
  stream : Stream.t;
}

let empty = Empty
let fixed chunks = Fixed chunks
let stream body = Stream body
let one_shot_stream ~length stream =
  if length < 0 then
    invalid_arg "Eta_http.Body.Source.one_shot_stream: length must be >= 0";
  One_shot_stream { length; stream }
let rewindable ?length (make) = Rewindable_stream { length; make }

let replayability = function
  | Empty | Fixed _ -> Replayable
  | Rewindable_stream _ -> Rewindable
  | Stream _ | One_shot_stream _ -> One_shot

let content_length = function
  | Empty -> Some 0
  | Fixed chunks ->
      Some
        (List.fold_left
           (fun total chunk -> total + Bytes.length chunk)
           0 chunks)
  | Rewindable_stream { length; _ } -> length
  | One_shot_stream { length; _ } -> Some length
  | Stream _ -> None

let to_stream = function
  | Empty -> Stream.empty ()
  | Fixed chunks -> Stream.of_bytes chunks
  | Stream stream -> stream
  | One_shot_stream { stream; _ } -> stream
  | Rewindable_stream { make; _ } -> make ()

let negative_length_error length =
  Error.make ~method_:"*" ~uri:"*"
    (Connection_protocol_violation
       {
         kind = "request_body_length";
         message =
           Printf.sprintf "request body length must be nonnegative (got %d)"
             length;
       })

let with_owned_stream t (f) =
  match t with
  | Empty | Fixed _ -> f None
  | Stream stream ->
      let owned = { length = None; stream } in
      Eta.Effect.with_scope
        (Eta.Effect.acquire_release ~acquire:(Eta.Effect.pure owned)
           ~release:(fun owned -> Stream.discard owned.stream)
        |> Eta.Effect.bind (fun owned -> f (Some owned)))
  | One_shot_stream { length; stream } ->
      Eta.Effect.with_scope
        (Eta.Effect.acquire_release ~acquire:(Eta.Effect.pure stream)
           ~release:Stream.discard
        |> Eta.Effect.bind (fun stream ->
               if length < 0 then
                 Eta.Effect.fail (negative_length_error length)
               else
                 let owned =
                   {
                     length = Some length;
                     stream = Stream.enforce_exact_length ~length stream;
                   }
                 in
                 f (Some owned)))
  | Rewindable_stream { length; make } ->
      let owned = { length; stream = make () } in
      Eta.Effect.with_scope
        (Eta.Effect.acquire_release ~acquire:(Eta.Effect.pure owned)
           ~release:(fun owned -> Stream.discard owned.stream)
        |> Eta.Effect.bind (fun owned -> f (Some owned)))
