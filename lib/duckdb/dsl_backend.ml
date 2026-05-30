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
  let nullable = nullable
  let invalid_query message = Invalid_value message
  let module_name = "Eta_duckdb"
  let value_to_string = Value.to_string

  let quote_text value =
    let len = String.length value in
    let extra_quotes = ref 0 in
    for i = 0 to len - 1 do
      if Char.equal (String.unsafe_get value i) '\'' then incr extra_quotes
    done;
    let out = Bytes.create (len + !extra_quotes + 2) in
    Bytes.unsafe_set out 0 '\'';
    let j = ref 1 in
    for i = 0 to len - 1 do
      let ch = String.unsafe_get value i in
      Bytes.unsafe_set out !j ch;
      incr j;
      if Char.equal ch '\'' then (
        Bytes.unsafe_set out !j '\'';
        incr j)
    done;
    Bytes.unsafe_set out !j '\'';
    Bytes.unsafe_to_string out

  let quote_blob value =
    let hex = "0123456789ABCDEF" in
    let len = Bytes.length value in
    let out = Bytes.create ((len * 2) + 3) in
    Bytes.unsafe_set out 0 'X';
    Bytes.unsafe_set out 1 '\'';
    for i = 0 to len - 1 do
      let byte = Char.code (Bytes.unsafe_get value i) in
      Bytes.unsafe_set out ((i * 2) + 2) (String.unsafe_get hex (byte lsr 4));
      Bytes.unsafe_set out ((i * 2) + 3) (String.unsafe_get hex (byte land 0xF))
    done;
    Bytes.unsafe_set out ((len * 2) + 2) '\'';
    Bytes.unsafe_to_string out

  let value_to_sql_literal = function
    | Value.Null -> "NULL"
    | Value.Bool true -> "TRUE"
    | Value.Bool false -> "FALSE"
    | Value.Int value -> string_of_int value
    | Value.Int64 value -> Int64.to_string value
    | Value.Float value -> string_of_float value
    | Value.String value
    | Value.Decimal value
    | Value.Date value
    | Value.Time value
    | Value.Timestamp value
    | Value.Uuid value
    | Value.Json value
    | Value.Enum value ->
        quote_text value
    | Value.Bytes value -> quote_blob value
    | Value.List _ | Value.Struct _ ->
        invalid_arg "Eta_duckdb.Eta_schema.column: default cannot be list or struct"
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
