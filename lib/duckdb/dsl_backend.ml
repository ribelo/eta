(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types

module Dsl = Eta_sql_dsl.Make (struct
  type value = Value.t
  type row = Row.t
  type nonrec error = error

  exception Error = Error

  type nonrec 'a typ = 'a typ = {
    value : 'a -> value;
    decode : row -> int -> 'a;
    sql_type : string;
  }

  let int = int
  let int64 = int64
  let bool = bool
  let float = float
  let text = text
  let invalid_query message = Invalid_value message
  let module_name = "Eta_duckdb"
  let value_to_string = Value.to_string
end)

type 'table table = 'table Dsl.table
type ('table, 'a) column = ('table, 'a) Dsl.column
type param = Dsl.param = Param : 'a typ * 'a -> param

module Compiled = Dsl.Compiled
module Table = Dsl.Table
module Column = Dsl.Column
module Expr = Dsl.Expr
module Projection = Dsl.Projection
module Scope = Dsl.Scope
module Source = Dsl.Source
module Select = Dsl.Select
module Insert = Dsl.Insert
module Update = Dsl.Update
module Delete = Dsl.Delete
module Eta_schema = Dsl.Eta_schema

let quote_ident = Dsl.quote_ident
let params_to_values = Dsl.params_to_values
let column_value = Dsl.column_value
