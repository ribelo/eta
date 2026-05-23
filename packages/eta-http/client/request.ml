(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body = Empty | Fixed of bytes list

type t = {
  method_ : string;
  uri : string;
  headers : Eta_http_core.Header.t;
  body : body;
}

let make ?(headers = Eta_http_core.Header.empty) ?(body = Empty) method_ uri =
  { method_; uri; headers; body }

let body_chunks t = match t.body with Empty -> 0 | Fixed chunks -> List.length chunks
let method_value t = Eta_http_core.Method.of_string t.method_
let url t = Eta_http_core.Url.of_string t.uri
