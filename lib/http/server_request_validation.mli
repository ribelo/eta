(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Shared server-side request validation for transport adapters. *)

type authority = {
  value : string;
  scheme : Url.scheme;
  host : string;
  port : int;
}

val connection_scheme : tls:bool -> Url.scheme
val valid_authority : string -> bool
val parse_authority : scheme:Url.scheme -> string -> authority option

val normalize_h1_target :
  connection_scheme:Url.scheme ->
  method_:string ->
  target:string ->
  (string * authority option, string) result

val validate_h1_authority :
  connection_scheme:Url.scheme ->
  version:Version.t ->
  method_:string ->
  target:string ->
  target_authority:authority option ->
  headers:Header.t ->
  (unit, string) result

val validate_h2_request :
  connection_scheme:Url.scheme ->
  method_:string ->
  scheme:string ->
  target:string ->
  authority:string option ->
  (unit, string) result

val validate_response_headers :
  limits:Server_config.limits -> Header.t -> (unit, string) result

val validate_response_trailers :
  limits:Server_config.limits -> Header.t -> (unit, string) result

val validate_h2_request_headers :
  limits:Server_config.limits -> (string * string) list -> (unit, string) result

val h2_request_content_length :
  (string * string) list -> (int option, string) result

val validate_h2_response_headers :
  limits:Server_config.limits -> Header.t -> (unit, string) result

val validate_h2_response_trailers :
  limits:Server_config.limits -> Header.t -> (unit, string) result
