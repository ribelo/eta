(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Stream.t;
    }

type t = {
  method_ : string;
  uri : string;
  headers : Header.t;
  body : body;
}

let make ?(headers = Header.empty) ?(body = Empty) method_ uri =
  { method_; uri; headers; body }

let body_chunks t =
  match t.body with
  | Empty -> 0
  | Fixed chunks -> List.length chunks
  | Stream _ | Rewindable_stream _ -> -1

let body_source = function
  | Empty -> Source.Empty
  | Fixed chunks -> Source.Fixed chunks
  | Stream body -> Source.Stream body
  | Rewindable_stream { length; make } ->
      Source.Rewindable_stream { length; make }

let method_value t = Method.of_string t.method_
let url t = Url.of_string t.uri
