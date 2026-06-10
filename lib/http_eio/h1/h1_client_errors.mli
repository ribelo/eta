(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta
open H1_client_types

val uri : request -> string
val make_error : request -> Error.kind -> Error.t
val protocol_violation : request -> string -> string -> Error.t
val io_closed : request -> Error.layer -> Error.t
val pool_context_error : method_:string -> uri:string -> pool_error -> Error.t

val map_http_error :
  ('a, Error.t) Effect.t -> ('a, [> `Http of Error.t ]) Effect.t

val close_flow :
  request ->
  [> Eio.Flow.two_way_ty | Eio.Resource.close_ty] Eio.Resource.t ->
  (unit, Error.t) Effect.t
val close_conn : conn -> (unit, 'err) Effect.t
val parse_error : request -> Parse.parse_error -> Error.t
val body_too_large : request -> limit:int -> length:int -> Error.t
