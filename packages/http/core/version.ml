(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = H1_0 | H1_1 | H2

let to_string = function H1_0 -> "http/1.0" | H1_1 -> "http/1.1" | H2 -> "h2"
let pp fmt t = Format.pp_print_string fmt (to_string t)
