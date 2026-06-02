(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Dsl_backend

type t = { rev_values : Value.t list }

let empty = { rev_values = [] }
let value column value row = { rev_values = column_value column value :: row.rev_values }
let null _column row = { rev_values = Value.Null :: row.rev_values }
let to_values row = List.rev row.rev_values
