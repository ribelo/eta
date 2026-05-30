(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Connection

type 'a typ = {
  value : 'a -> Value.t;
  decode : Row.t -> int -> 'a;
  sql_type : string;
}

let int =
  {
    value = (fun value -> Value.Int value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_int value with
      | Some value -> value
      | None -> decode_fail index "int" value);
    sql_type = "INTEGER";
  }

let int64 =
  {
    value = (fun value -> Value.Int64 value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_int64 value with
      | Some value -> value
      | None -> decode_fail index "int64" value);
    sql_type = "INTEGER";
  }

let text =
  {
    value = (fun value -> Value.String value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_string_value value with
      | Some value -> value
      | None -> decode_fail index "text" value);
    sql_type = "TEXT";
  }

let bool =
  {
    value = (fun value -> Value.Bool value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_bool value with
      | Some value -> value
      | None -> decode_fail index "bool" value);
    sql_type = "INTEGER";
  }

let float =
  {
    value = (fun value -> Value.Float value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_float value with
      | Some value -> value
      | None -> decode_fail index "float" value);
    sql_type = "REAL";
  }

let blob =
  {
    value = (fun value -> Value.Bytes value);
    decode = (fun row index ->
      let value = row_nth_value index row in
      match Value.to_bytes value with
      | Some value -> value
      | None -> decode_fail index "blob" value);
    sql_type = "BLOB";
  }

let nullable typ =
  {
    value = (function None -> Value.Null | Some value -> typ.value value);
    decode =
      (fun row index ->
        match row_nth_value index row with
        | Value.Null -> None
        | _ -> Some (typ.decode row index));
    sql_type = typ.sql_type;
  }

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
  let invalid_query message = Invalid_query message
  let module_name = "Eta_turso"
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
