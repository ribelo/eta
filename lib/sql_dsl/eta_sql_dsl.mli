(** SQL literal quoting helpers used by backend renderers for DDL/default
    values. Query values should stay parameterized through compiled statements;
    these helpers are not an escape hatch for hand-built predicates. *)
val quote_text : string -> string

val quote_blob : bytes -> string

val transaction :
  begin_:('resource -> (unit, 'error) result) ->
  commit:('resource -> (unit, 'error) result) ->
  rollback:('resource -> (unit, 'error) result) ->
  'resource ->
  ('resource -> ('a, 'error) result) ->
  ('a, 'error) result
(** Shared transaction state machine for SQL backends: begin, run the body,
    commit on success, rollback on body failure, rollback and re-raise on body
    exception, and rollback after commit failure before returning that commit
    error. Backend modules still own their begin/commit/rollback semantics. *)

module Row : sig
  module type VALUE = sig
    type t

    val to_int : t -> int option
    val to_int64 : t -> int64 option
    val to_string_value : t -> string option
    val to_bool : t -> bool option
    val to_float : t -> float option
    val to_bytes : t -> bytes option
    val to_string : t -> string
    val equal : t -> t -> bool
  end

  module Make (Value : VALUE) : sig
    type value = Value.t
    type t = (string * value) list

    val get : string -> t -> value option
    val fields : t -> string list
    val int : string -> t -> int option
    val int64 : string -> t -> int64 option
    val string : string -> t -> string option
    val bool : string -> t -> bool option
    val float : string -> t -> float option
    val bytes : string -> t -> bytes option
    val to_string : t -> string
    val equal : t -> t -> bool
  end
end

module type BACKEND = sig
  type value
  type row
  type error

  exception Error of error

  type 'a typ = {
    value : 'a -> value;
    decode : row -> int -> 'a;
    sql_type : string;
  }
  (** Primitive codecs are a backend-owned invariant, not a shared Eta_sql_dsl
      implementation detail. The common DSL requires these names so queries can
      be built uniformly, but each connector owns the SQL type names, row
      representation, NULL detection, and coercions. SQLite decodes from a live
      sqlite3_stmt cursor; row-materialized backends decode their own Value.t
      rows and may expose different SQL affinities. *)

  val int : int typ
  val int64 : int64 typ
  val bool : bool typ
  val float : float typ
  val text : string typ
  val nullable : 'a typ -> 'a option typ
  val invalid_query : string -> error
  val module_name : string
  val value_to_string : value -> string
  val value_to_sql_literal : value -> string
end

module type S = sig
  type value
  type row
  type error

  type 'a typ

  val int : int typ
  val int64 : int64 typ
  val bool : bool typ
  val float : float typ
  val text : string typ
  val nullable : 'a typ -> 'a option typ
  type param = Param : 'a typ * 'a -> param

  module Numeric : sig
    type 'a t

    val int : int t
    val int64 : int64 t
    val float : float t
  end

  module Compiled : sig
    (** Generated SQL artifacts produced by the typed DSL.

        These values are intentionally inspectable for drivers and diagnostics.
        They preserve generated SQL, parameters, projection width, and decoders;
        they do not make the DSL a closed safety boundary. Code that constructs
        compiled records directly or routes through raw execution APIs owns SQL
        validity and decoder correctness outside the builder's type checks. *)

    type 'a select
    type 'a returning
    type change
    type schema

    val value_of_param : param -> value
    val select_sql : 'a select -> string
    val select_width : 'a select -> int
    (** Number of SQL columns projected by this select. *)

    val select_params : 'a select -> value list
    val select_decode : 'a select -> row -> 'a
    val returning_sql : 'a returning -> string
    val returning_params : 'a returning -> value list
    val returning_decode : 'a returning -> row -> 'a
    val change_sql : change -> string
    val change_params : change -> value list
    val schema_sql : schema -> string
  end

  type 'table table
  type ('table, 'a) column

  module Table : sig
    type 'table t = 'table table

    module Make (_ : sig
      val name : string
    end) : sig
      type table

      val table : table t
      val column : string -> 'a typ -> (table, 'a) column
    end

    val name : 'table t -> string
    val alias : 'table t -> string -> 'table t
    (** Aliases change SQL qualification only; the phantom table identity is
        unchanged, so aliases do not create a second independent scope. *)

    val column : 'table t -> string -> 'a typ -> ('table, 'a) column
  end

  module Column : sig
    type ('table, 'a) t = ('table, 'a) column

    val name : (_, _) t -> string
    val table_name : (_, _) t -> string
  end

  module Expr : sig
    type ('scope, 'a) t
    (** A SQL expression that may reference only columns visible in ['scope] and
        produces values decoded as ['a].

        Scope evidence is intentionally narrow: it tracks table visibility across
        [Source] joins, not every SQL validity rule. It does not prove GROUP BY
        correctness, cardinality, correlation legality, uniqueness of aliases, or
        backend-specific coercion behavior. Typed DSL values also do not make raw
        execution impossible; callers can still bypass this layer through the
        execution package's raw SQL APIs.

        Arithmetic and [avg] require an explicit [Numeric.t] witness. That keeps
        text/blob/bool expressions out of numeric operators, but operands must
        still have the same OCaml type and backend overflow, precision, and
        division semantics remain backend-defined. *)

    val true_ : ('scope, bool) t
    val false_ : ('scope, bool) t
    val lit : 'a typ -> 'a -> ('scope, 'a) t
    (** Parameterized literal with an explicit backend type. *)
    val int_lit : int -> ('scope, int) t
    val int64_lit : int64 -> ('scope, int64) t
    val float_lit : float -> ('scope, float) t
    val text_lit : string -> ('scope, string) t
    val bool_lit : bool -> ('scope, bool) t
    val col : ('scope, 'a) column -> ('scope, 'a) t

    val eq : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val ne : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val gt : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val ge : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val lt : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val le : ('scope, 'a) column -> 'a -> ('scope, bool) t
    val like : ('scope, string) column -> string -> ('scope, bool) t
    (** [like column pattern] binds [pattern] as a parameter; wildcard escaping is
        the caller's responsibility. *)

    val eq_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    val ne_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    val gt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    val ge_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    val lt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    val le_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t

    val eq_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    val gt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    val ge_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    val lt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    val le_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t

    val add : 'a Numeric.t -> ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    val sub : 'a Numeric.t -> ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    val mul : 'a Numeric.t -> ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    val div : 'a Numeric.t -> ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t

    val is_null : ('scope, 'a option) column -> ('scope, bool) t
    val is_not_null : ('scope, 'a option) column -> ('scope, bool) t
    val between : ('scope, 'a) column -> 'a -> 'a -> ('scope, bool) t
    val in_values : ('scope, 'a) column -> 'a list -> ('scope, bool) t
    (** Empty lists are rendered as a false predicate instead of invalid SQL. *)
    val in_select : ('scope, 'a) column -> 'a Compiled.select -> ('scope, bool) t
    val exists : _ Compiled.select -> ('scope, bool) t

    (** Aggregate expressions other than [count] are nullable because SQL
        backends return NULL for empty aggregate inputs. *)
    val count : unit -> ('scope, int) t
    val sum_int : ('scope, int) column -> ('scope, int option) t
    val sum_float : ('scope, float) column -> ('scope, float option) t
    val avg : 'a Numeric.t -> ('scope, 'a) column -> ('scope, float option) t
    val min : ('scope, 'a) column -> ('scope, 'a option) t
    val max : ('scope, 'a) column -> ('scope, 'a option) t

    val case :
      (('scope, bool) t * ('scope, 'a) t) list ->
      default:('scope, 'a) t ->
      ('scope, 'a) t
    val and_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
    val or_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
    val not_ : ('scope, bool) t -> ('scope, bool) t
  end

  module Projection : sig
    type ('scope, 'a) t
    (** A SELECT projection visible in ['scope] with a decoder for the projected
        row shape ['a].

        Projections pair SQL fragments with decoders. Tuple combinators preserve
        SQL column order and decoded tuple order; [map] changes only the decoded
        value, not the SQL. [expr ?as_] aliases affect rendered SQL names but do
        not create extra type evidence or prevent backend-specific name clashes. *)

    val one : ('scope, 'a) column -> ('scope, 'a) t
    val expr : ?as_:string -> ('scope, 'a) Expr.t -> ('scope, 'a) t
    val t2 : ('scope, 'a) t -> ('scope, 'b) t -> ('scope, 'a * 'b) t
    val t3 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'a * 'b * 'c) t
    val count : ?as_:string -> unit -> ('scope, int) t
    val sum_int : ?as_:string -> ('scope, int) column -> ('scope, int option) t
    val sum_float : ?as_:string -> ('scope, float) column -> ('scope, float option) t
    val avg :
      ?as_:string ->
      'a Numeric.t ->
      ('scope, 'a) column ->
      ('scope, float option) t
    val min : ?as_:string -> ('scope, 'a) column -> ('scope, 'a option) t
    val max : ?as_:string -> ('scope, 'a) column -> ('scope, 'a option) t
    val row_number :
      ?as_:string ->
      ?partition_by:('scope, 'a) column list ->
      ?order_by:('scope, 'b) column ->
      unit ->
      ('scope, int) t
    (** [ROW_NUMBER()] supports at most one [order_by] expression here; use raw SQL
        when backend-specific window syntax is required. *)
    val t4 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'a * 'b * 'c * 'd) t
    val t5 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e) t
    val t6 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'f) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e * 'f) t
    val t7 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'f) t ->
      ('scope, 'g) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g) t
    val t8 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'f) t ->
      ('scope, 'g) t ->
      ('scope, 'h) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g * 'h) t
    val map : ('a -> 'b) -> ('scope, 'a) t -> ('scope, 'b) t
  end

  module Scope : sig
    type ('sub, 'super) contains
    (** Explicit scope-widening evidence for joins.

        This is intentionally not inferred automatically: callers must state
        which side of a joined source makes a column visible. The evidence only
        tracks table visibility, not SQL name ambiguity or backend join rules. *)

    val self : ('scope, 'scope) contains
    val left : ('sub, 'super) contains -> ('sub, 'super * 'added) contains
    val right : ('added, 'existing * 'added) contains
    val column :
      ('sub, 'super) contains -> ('sub, 'a) column -> ('super, 'a) column
    val nullable_column :
      ('sub, 'super) contains -> ('sub, 'a) column -> ('super, 'a option) column
    (** Promote a column through scope evidence and decode SQL NULL as [None].
        Use this for columns from the nullable side of an outer join. *)
  end

  module Source : sig
    type 'scope t
    (** A FROM source carries the phantom scope used by expressions and
        projections. Left joins widen the scope, but callers must project or
        filter nullable-side columns with {!Scope.nullable_column}; plain
        {!Scope.column} preserves the table declaration's type and will fail
        loudly if the database returns SQL NULL for a non-nullable decoder. *)

    val from : 'table table -> 'table t
    val join :
      ?op:[ `Inner | `Left ] ->
      on:('existing * 'added, bool) Expr.t ->
      'added table ->
      'existing t ->
      ('existing * 'added) t
    (** Join one table onto an existing source. [on] is checked against the
        enlarged scope and can reference both existing columns and the new table. *)
  end

  module Select : sig
    type ('scope, 'a) t

    val from : 'table table -> ('table, 'a) Projection.t -> ('table, 'a) t
    val from_source : 'scope Source.t -> ('scope, 'a) Projection.t -> ('scope, 'a) t
    val with_cte :
      name:string -> _ Compiled.select -> ('scope, 'a) t -> ('scope, 'a) t
    val distinct : ('scope, 'a) t -> ('scope, 'a) t
    val where : ('scope, bool) Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
    val group_by : ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
    val group_by_many :
      ('scope, 'b) column list -> ('scope, 'a) t -> ('scope, 'a) t
    val having : ('scope, bool) Expr.t -> ('scope, 'a) t -> ('scope, 'a) t
    val order_by : ?desc:bool -> ('scope, 'b) column -> ('scope, 'a) t -> ('scope, 'a) t
    val limit : int -> ('scope, 'a) t -> ('scope, 'a) t
    val to_sql : (_, _) t -> string
    val compile : (_, 'a) t -> 'a Compiled.select
  end

  module Insert : sig
    type 'table t

    val into : 'table table -> 'table t
    val value : ('table, 'a) column -> 'a -> 'table t -> 'table t
    val on_conflict_do_nothing :
      ('table, 'a) column list -> 'table t -> 'table t
    val on_conflict_update :
      ('table, 'a) column list ->
      set:('table, 'b) column list ->
      'table t ->
      'table t
    val to_sql : _ t -> string
    val compile : _ t -> Compiled.change
    val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
  end

  module Update : sig
    type 'table t

    val table : 'table table -> 'table t
    val set : ('table, 'a) column -> 'a -> 'table t -> 'table t
    val where : ('table, bool) Expr.t -> 'table t -> 'table t
    val to_sql : _ t -> string
    val compile : _ t -> Compiled.change
    val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
  end

  module Delete : sig
    type 'table t

    val from : 'table table -> 'table t
    val where : ('table, bool) Expr.t -> 'table t -> 'table t
    val to_sql : _ t -> string
    val compile : _ t -> Compiled.change
    val returning : ('table, 'a) Projection.t -> 'table t -> 'a Compiled.returning
  end

  module Eta_schema : sig
    type reference
    type column_def
    type t

    val references :
      ?on_delete:string -> ?on_update:string -> (_, _) column -> reference
    val column :
      ?primary_key:bool ->
      ?not_null:bool ->
      ?unique:bool ->
      ?default:'a ->
      ?references:reference ->
      (_, 'a) column ->
      column_def
    val create_table : ?if_not_exists:bool -> 'table table -> column_def list -> t
    val drop_table : ?if_exists:bool -> 'table table -> t
    val create_index :
      ?unique:bool ->
      ?if_not_exists:bool ->
      name:string ->
      'table table ->
      (_, _) column list ->
      t
    val to_sql : t -> string
    val compile : t -> Compiled.schema
  end

  val quote_ident : string -> string
  val params_to_values : param list -> value list
end

module Make (Backend : BACKEND) :
  sig
    include
      S
        with type value = Backend.value
         and type row = Backend.row
         and type error = Backend.error
         and type 'a typ = 'a Backend.typ

    val column_value : ('table, 'a) column -> 'a -> value
  end
