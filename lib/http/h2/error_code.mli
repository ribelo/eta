(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 error codes, RFC 9113 section 7. *)

type t =
  | No_error
  | Protocol_error
  | Internal_error
  | Flow_control_error
  | Settings_timeout
  | Stream_closed
  | Frame_size_error
  | Refused_stream
  | Cancel
  | Compression_error
  | Connect_error
  | Enhance_your_calm
  | Inadequate_security
  | Http_1_1_required

val to_int : t -> int
val of_int : int -> t option
val pp_hum : Format.formatter -> t -> unit
