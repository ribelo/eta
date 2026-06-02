(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Dsl_backend

type 'table t = Appender.t

let create ?schema connection table =
  Appender.create ?schema connection ~table:(Table.name table)

let append_row appender row = Appender.append_row appender (Bulk_row.to_values row)
let flush = Appender.flush
let close = Appender.close

let with_appender ?schema connection table f =
  Appender.with_appender ?schema connection ~table:(Table.name table) f
