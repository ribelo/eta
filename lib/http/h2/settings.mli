(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** HTTP/2 SETTINGS and flow-control defaults, matching RFC 9113 and H2O's host
    defaults where applicable. *)

type t = private {
  header_table_size : int;
  enable_push : bool;
  max_concurrent_streams : int;
  initial_window_size : int;
  max_frame_size : int;
  max_header_list_size : int option;
}

val default : t

(** Host/server defaults. *)
val host_default : t

(** Build a settings value. *)
val create :
  ?header_table_size:int ->
  ?enable_push:bool ->
  ?max_concurrent_streams:int ->
  ?initial_window_size:int ->
  ?max_frame_size:int ->
  ?max_header_list_size:int option ->
  unit ->
  t

val validate : t -> (unit, Error_code.t) result
val is_valid_max_frame_size : int -> bool
val is_valid_initial_window_size : int -> bool

(** Apply a single decoded SETTINGS parameter, returning the updated settings. *)
val apply_setting : t -> Frame.Settings.setting -> t

(** Serialize a SETTINGS payload (not including the frame header). *)
val encode : t -> string
