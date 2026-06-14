(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 flow-control windows. *)

type t = private { mutable avail : int }

val create : initial:int -> t
val available : t -> int
val consume : t -> int -> (unit, Error_code.t) result
val update : t -> int -> (unit, Error_code.t) result
