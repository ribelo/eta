(** Typed SQL query builder and SQLite-oriented SQL utilities for Eta.

    This is not an ORM. Applications define tables, columns, queries, and
    migrations explicitly; Eta owns rendering, binding, execution, and result
    decoding. *)

module Sqlite = Sqlite

type error = Types.error =
  | Sqlite of Sqlite.error
  | Pool_error of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string

type sql_error = error

exception Error of error

type 'a typ = 'a Dsl.typ

val int : int typ
val int64 : int64 typ
val text : string typ
val bool : bool typ
val float : float typ
val blob : bytes typ
val nullable : 'a typ -> 'a option typ

module Value = Value
module Row = Row

type 'table table = 'table Dsl.table
type ('table, 'a) column = ('table, 'a) Dsl.column

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

module Pool = Pool
module Migrate = Migrate
