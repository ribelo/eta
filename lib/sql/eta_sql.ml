module Sqlite = Sqlite

(* Error types and primitive type constructors. *)
type error = Types.error =
  | Sqlite of Sqlite.error
  | Pool_error of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }

let pp_error = Types.pp_error
let show_error = Types.show_error

type sql_error = Types.sql_error

exception Error = Types.Error

type 'a typ = 'a Types.typ

let int = Types.int
let int64 = Types.int64
let text = Types.text
let bool = Types.bool
let float = Types.float
let blob = Types.blob
let nullable = Types.nullable

(* Phantom types for tables and columns; instantiated in [Dsl]. *)
type 'table table = 'table Dsl.table
type ('table, 'a) column = ('table, 'a) Dsl.column

(* Runtime modules. *)
module Value = Value
module Row = Row

(* DSL modules. *)
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

(* Execution surfaces. *)
module Pool = Pool
module Migrate = Migrate
