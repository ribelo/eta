(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type replayability = Replayable | Rewindable | One_shot

type t =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Stream.t;
    }

let empty = Empty
let fixed chunks = Fixed chunks
let stream body = Stream body
let rewindable ?length make = Rewindable_stream { length; make }

let replayability = function
  | Empty | Fixed _ -> Replayable
  | Rewindable_stream _ -> Rewindable
  | Stream _ -> One_shot

let content_length = function
  | Empty -> Some 0
  | Fixed chunks ->
      Some
        (List.fold_left
           (fun total chunk -> total + Bytes.length chunk)
           0 chunks)
  | Rewindable_stream { length; _ } -> length
  | Stream _ -> None

let to_stream = function
  | Empty -> Stream.empty ()
  | Fixed chunks -> Stream.of_bytes chunks
  | Stream stream -> stream
  | Rewindable_stream { make; _ } -> make ()
