(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Response_idle_timeout = struct
  type t = Disabled | Enabled of int

  let disabled = Disabled
  let default = Enabled 300_000

  let of_ms milliseconds =
    if milliseconds <= 0 then
      invalid_arg
        "Eta_http.Request.Response_idle_timeout.of_ms: milliseconds must be > 0";
    Enabled milliseconds

  let to_ms = function Disabled -> None | Enabled milliseconds -> Some milliseconds
end

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
  response_idle_timeout : Response_idle_timeout.t;
}

let make ?(headers = Header.empty) ?(body = Empty)
    ?(response_idle_timeout = Response_idle_timeout.default) method_ uri =
  { method_; uri; headers; body; response_idle_timeout }

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
