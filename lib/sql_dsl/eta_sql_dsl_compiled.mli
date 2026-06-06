module Make
    (Backend : sig
      type value
      type row
    end)
    (Param : sig
      type t

      val value : t -> Backend.value
    end) : sig
  (** Generated SQL artifacts produced by the typed DSL.

      These values are intentionally inspectable so backend packages can bind
      parameters and decode rows without depending on the query-builder AST.
      They are not a sealed relational-algebra boundary: code with access to
      record constructors or raw execution APIs can bypass DSL construction and
      then owns SQL validity, parameter ordering, and decoder correctness. *)

  type param = Param.t

  type 'a select = {
    sql : string;
    params : param list;
    width : int;
    decode : Backend.row -> 'a;
  }

  type 'a returning = {
    sql : string;
    params : param list;
    decode : Backend.row -> 'a;
  }

  type change = {
    sql : string;
    params : param list;
  }

  type schema = { sql : string } [@@unboxed]

  val value_of_param : param -> Backend.value
  val select_sql : 'a select -> string
  val select_width : 'a select -> int
  (** Number of SQL columns projected by this select. *)

  val select_params : 'a select -> Backend.value list
  val select_decode : 'a select -> Backend.row -> 'a
  val returning_sql : 'a returning -> string
  val returning_params : 'a returning -> Backend.value list
  val returning_decode : 'a returning -> Backend.row -> 'a
  val change_sql : change -> string
  val change_params : change -> Backend.value list
  val schema_sql : schema -> string
end
