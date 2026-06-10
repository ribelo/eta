(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

val error : Request.t -> Error.kind -> Error.t
val protocol_violation : Request.t -> string -> string -> Error.t
val closed : Request.t -> Error.layer -> Error.t
val pp_client_error : H2.Client_connection.error -> string
