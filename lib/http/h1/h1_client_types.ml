(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Error = Error
module Header = Header
module Url = Url

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

module type EIO_FLOW = Eta.Host_eio.FLOW

type request_body =
  | Empty
  | Fixed of bytes list
  | Stream of Body.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Body.t) @@ many;
    }

type request = {
  method_ : string;
  url : Url.t;
  headers : Header.t;
  body : request_body;
}

type response = {
  status : int;
  headers : Header.t;
  body : Body.t;
  trailers : (unit -> (Header.t, Error.t) Eta.Effect.t) @@ many;
}

type conn = {
  flow : flow;
  mutable used : bool;
  mutable reusable : bool;
  mutable last_used_ms : int;
}

type pool_error : immutable_data =
  [ `Http of Error.t
  | `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Health_probe_timeout
  ]

type pool = {
  origin : string;
  target : Connect.target;
  max_response_body_bytes : int;
  pool : (conn, pool_error) Eta.Pool.t;
}
