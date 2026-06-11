(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type peer = {
  address : string option;
  port : int option;
}

type t = {
  id : string;
  version : Version.t;
  scheme : string;
  authority : string option;
  method_ : string;
  target : string;
  path : string;
  query : string option;
  headers : Header.t;
  body : Server_body.t;
  trailers : unit -> (Header.t, Server_error.t) Eta.Effect.t;
  peer : peer;
  tls : bool;
  alpn_protocol : string option;
  stream_id : int option;
  connection_id : string;
}

let split_target target =
  match String.index_opt target '?' with
  | None -> (target, None)
  | Some query_start ->
      let path = String.sub target 0 query_start in
      let query =
        String.sub target (query_start + 1)
          (String.length target - query_start - 1)
      in
      (path, Some query)

let header name t = Header.get name t.headers
let body t = t.body
let trailers t = t.trailers ()
let trace_context t = Eta.Trace_context.extract (Header.to_list t.headers)
