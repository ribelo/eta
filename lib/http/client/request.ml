(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t);
    }

type t = {
  method_ : string;
  uri : string;
  headers : Header.t;
  body : body;
  response_idle_timeout_ms : int;
}

let default_response_idle_timeout_ms = 300_000

let validate_response_idle_timeout_ms value =
  if value < 0 then
    invalid_arg
      "Eta_http.Request.make: response_idle_timeout_ms must be >= 0"

let make ?(headers = Header.empty) ?(body = Empty)
    ?(response_idle_timeout_ms = default_response_idle_timeout_ms) method_ uri =
  validate_response_idle_timeout_ms response_idle_timeout_ms;
  { method_; uri; headers; body; response_idle_timeout_ms }

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
