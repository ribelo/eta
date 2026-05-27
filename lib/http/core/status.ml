(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = int

let of_int status = if status >= 100 && status <= 599 then Some status else None

let unsafe_of_int status =
  match of_int status with
  | Some status -> status
  | None -> invalid_arg "Eta_http.Status.unsafe_of_int"

let to_int status = status
let class_ status = string_of_int (status / 100) ^ "xx"
let is_informational status = status >= 100 && status <= 199
let is_success status = status >= 200 && status <= 299
let is_redirection status = status >= 300 && status <= 399
let is_client_error status = status >= 400 && status <= 499
let is_server_error status = status >= 500 && status <= 599
