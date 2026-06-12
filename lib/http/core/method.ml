(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t =
  [ `GET
  | `HEAD
  | `POST
  | `PUT
  | `DELETE
  | `CONNECT
  | `OPTIONS
  | `TRACE
  | `PATCH
  | `Other of string ]

let of_string method_ =
  match method_ with
  | "GET" -> `GET
  | "HEAD" -> `HEAD
  | "POST" -> `POST
  | "PUT" -> `PUT
  | "DELETE" -> `DELETE
  | "CONNECT" -> `CONNECT
  | "OPTIONS" -> `OPTIONS
  | "TRACE" -> `TRACE
  | "PATCH" -> `PATCH
  | other -> `Other other

let to_string = function
  | `GET -> "GET"
  | `HEAD -> "HEAD"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `DELETE -> "DELETE"
  | `CONNECT -> "CONNECT"
  | `OPTIONS -> "OPTIONS"
  | `TRACE -> "TRACE"
  | `PATCH -> "PATCH"
  | `Other method_ -> method_

let pp fmt t = Format.pp_print_string fmt (to_string t)

let is_idempotent = function
  | `GET | `HEAD | `PUT | `DELETE | `OPTIONS | `TRACE -> true
  | `POST | `PATCH | `CONNECT | `Other _ -> false
