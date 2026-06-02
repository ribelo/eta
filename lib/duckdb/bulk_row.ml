(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Dsl_backend

type t = Value.t list

let empty = []
let value column value row = row @ [ column_value column value ]
let null _column row = row @ [ Value.Null ]
