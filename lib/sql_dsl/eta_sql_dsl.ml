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

  module Compiled : sig
    type 'a select
    type 'a returning
    type change
    type schema

    val value_of_param : param -> value
    val select_sql : 'a select -> string
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
    (** [alias table name] renders [table AS name] in sources and qualifies
        columns created from the alias with [name]. *)

    val column : 'table t -> string -> 'a typ -> ('table, 'a) column
    (** Create a column value bound to a table value, including aliases. *)
  end

  module Column : sig
    type ('table, 'a) t = ('table, 'a) column

    val name : (_, _) t -> string
    val table_name : (_, _) t -> string
  end

  module Expr : sig
    type ('scope, 'a) t
    (** A typed SQL expression visible in ['scope] and decoding/rendering as ['a]. *)

    val true_ : ('scope, bool) t
    (** SQL true predicate. *)
    val false_ : ('scope, bool) t
    (** SQL false predicate. *)
    val lit : 'a typ -> 'a -> ('scope, 'a) t
    (** Parameterized literal with an explicit SQL type. *)
    val int_lit : int -> ('scope, int) t
    (** Parameterized integer literal. *)
    val int64_lit : int64 -> ('scope, int64) t
    (** Parameterized 64-bit integer literal. *)
    val float_lit : float -> ('scope, float) t
    (** Parameterized float literal. *)
    val text_lit : string -> ('scope, string) t
    (** Parameterized text literal. *)
    val bool_lit : bool -> ('scope, bool) t
    (** Parameterized boolean literal. *)
    val col : ('scope, 'a) column -> ('scope, 'a) t
    (** Treat a visible column as a typed expression. *)
    val eq : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column equals literal. *)
    val ne : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column does not equal literal. *)
    val gt : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column is greater than literal. *)
    val ge : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column is greater than or equal to literal. *)
    val lt : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column is less than literal. *)
    val le : ('scope, 'a) column -> 'a -> ('scope, bool) t
    (** Column is less than or equal to literal. *)
    val like : ('scope, string) column -> string -> ('scope, bool) t
    (** Text column matches a SQL LIKE pattern. *)
    val eq_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression equals expression. *)
    val ne_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression does not equal expression. *)
    val gt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression is greater than expression. *)
    val ge_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression is greater than or equal to expression. *)
    val lt_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression is less than expression. *)
    val le_expr : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, bool) t
    (** Expression is less than or equal to expression. *)
    val eq_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    (** Column equals column. *)
    val gt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    (** Column is greater than column. *)
    val ge_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    (** Column is greater than or equal to column. *)
    val lt_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    (** Column is less than column. *)
    val le_col : ('scope, 'a) column -> ('scope, 'a) column -> ('scope, bool) t
    (** Column is less than or equal to column. *)
    val add : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    (** SQL addition over same-typed expressions. *)
    val sub : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    (** SQL subtraction over same-typed expressions. *)
    val mul : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    (** SQL multiplication over same-typed expressions. *)
    val div : ('scope, 'a) t -> ('scope, 'a) t -> ('scope, 'a) t
    (** SQL division over same-typed expressions. *)
    val is_null : ('scope, 'a option) column -> ('scope, bool) t
    (** Nullable column is NULL. *)
    val is_not_null : ('scope, 'a option) column -> ('scope, bool) t
    (** Nullable column is not NULL. *)
    val between : ('scope, 'a) column -> 'a -> 'a -> ('scope, bool) t
    (** Column lies between two literal bounds. *)
    val in_values : ('scope, 'a) column -> 'a list -> ('scope, bool) t
    (** Column is in a non-empty literal list. *)
    val in_select : ('scope, 'a) column -> 'a Compiled.select -> ('scope, bool) t
    (** Column is in a typed subquery result. *)
    val exists : _ Compiled.select -> ('scope, bool) t
    (** SQL EXISTS predicate for a compiled subquery. *)
    val count : unit -> ('scope, int) t
    (** COUNT-star aggregate expression. *)
    val sum_int : ('scope, int) column -> ('scope, int option) t
    (** SUM aggregate over an integer column. SQLite returns NULL for an empty input. *)
    val sum_float : ('scope, float) column -> ('scope, float option) t
    (** SUM aggregate over a float column. SQLite returns NULL for an empty input. *)
    val avg : ('scope, 'a) column -> ('scope, float option) t
    (** AVG aggregate over a numeric SQLite column. SQLite returns NULL for an empty input. *)
    val min : ('scope, 'a) column -> ('scope, 'a option) t
    (** MIN aggregate preserving the column type. SQLite returns NULL for an empty input. *)
    val max : ('scope, 'a) column -> ('scope, 'a option) t
    (** MAX aggregate preserving the column type. SQLite returns NULL for an empty input. *)
    val case :
      (('scope, bool) t * ('scope, 'a) t) list ->
      default:('scope, 'a) t ->
      ('scope, 'a) t
    (** CASE WHEN expression with same-typed result branches. *)
    val and_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
    (** Boolean AND. *)
    val or_ : ('scope, bool) t -> ('scope, bool) t -> ('scope, bool) t
    (** Boolean OR. *)
    val not_ : ('scope, bool) t -> ('scope, bool) t
    (** Boolean NOT. *)
  end

  module Projection : sig
    type ('scope, 'a) t
    (** A SELECT projection visible in ['scope] and decoding one output value ['a]. *)

    val one : ('scope, 'a) column -> ('scope, 'a) t
    (** Project one visible column. *)
    val expr : ?as_:string -> ('scope, 'a) Expr.t -> ('scope, 'a) t
    (** Project any typed expression, optionally assigning a SQL alias. *)
    val t2 : ('scope, 'a) t -> ('scope, 'b) t -> ('scope, 'a * 'b) t
    (** Combine two projections into a pair. *)
    val t3 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'a * 'b * 'c) t
    (** Combine three projections into a tuple. *)
    val count : ?as_:string -> unit -> ('scope, int) t
    (** Project COUNT-star. *)
    val sum_int : ?as_:string -> ('scope, int) column -> ('scope, int option) t
    (** Project SUM over an integer column. *)
    val sum_float : ?as_:string -> ('scope, float) column -> ('scope, float option) t
    (** Project SUM over a float column. *)
    val avg : ?as_:string -> ('scope, 'a) column -> ('scope, float option) t
    (** Project AVG over a numeric SQLite column. *)
    val min : ?as_:string -> ('scope, 'a) column -> ('scope, 'a option) t
    (** Project MIN preserving the column type. *)
    val max : ?as_:string -> ('scope, 'a) column -> ('scope, 'a option) t
    (** Project MAX preserving the column type. *)
    val row_number :
      ?as_:string ->
      ?partition_by:('scope, 'a) column list ->
      ?order_by:('scope, 'b) column ->
      unit ->
      ('scope, int) t
    (** Project ROW_NUMBER() with optional partition and order clauses. *)
    val t4 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'a * 'b * 'c * 'd) t
    (** Combine four projections into a tuple. *)
    val t5 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e) t
    (** Combine five projections into a tuple. *)
    val t6 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'f) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e * 'f) t
    (** Combine six projections into a tuple. *)
    val t7 :
      ('scope, 'a) t ->
      ('scope, 'b) t ->
      ('scope, 'c) t ->
      ('scope, 'd) t ->
      ('scope, 'e) t ->
      ('scope, 'f) t ->
      ('scope, 'g) t ->
      ('scope, 'a * 'b * 'c * 'd * 'e * 'f * 'g) t
    (** Combine seven projections into a tuple. *)
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
    (** Combine eight projections into a tuple. *)
    val map : ('a -> 'b) -> ('scope, 'a) t -> ('scope, 'b) t
    (** Map the decoded value while preserving the SQL projection. *)
  end

  module Scope : sig
    type ('sub, 'super) contains
    (** Evidence that ['super] contains every table visible in ['sub]. *)

    val self : ('scope, 'scope) contains
    (** A scope contains itself. *)
    val left : ('sub, 'super) contains -> ('sub, 'super * 'added) contains
    (** If a scope is contained in the existing side, it is contained after a join. *)
    val right : ('added, 'existing * 'added) contains
    (** The newly joined table is contained on the right side of a join. *)
    val column :
      ('sub, 'super) contains -> ('sub, 'a) column -> ('super, 'a) column
    (** Promote a column only when containment evidence proves it is visible. *)
  end

  module Source : sig
    type 'scope t
    (** A FROM source with the phantom scope of all visible tables. *)

    val from : 'table table -> 'table t
    (** Start a source from one table. *)
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

module Make (Backend : BACKEND) = struct
  type value = Backend.value
  type row = Backend.row
  type error = Backend.error

  type 'a typ = 'a Backend.typ = {
    value : 'a -> Backend.value;
    decode : Backend.row -> int -> 'a;
    sql_type : string;
  }

  let int = Backend.int
  let int64 = Backend.int64
  let bool = Backend.bool
  let float = Backend.float
  let text = Backend.text
  let nullable = Backend.nullable

  type 'table table = {
    table_name : string;
    quoted_table_name : string;
    from_sql : string;
    column_qualifier : string;
  }

  type ('table, 'a) column = {
    table_name : string;
    column_name : string;
    typ : 'a typ;
    quoted_column_name : string;
    qualified_column_name : string;
  }

  type param = Param : 'a typ * 'a -> param

  module Compiled = struct
    type 'a select = {
      sql : string;
      params : param list;
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

    type schema = { sql : string }

    let value_of_param (Param (typ, value)) = typ.value value
    let select_sql (query : _ select) = query.sql
    let select_params (query : _ select) = List.map value_of_param query.params
    let select_decode (query : _ select) = query.decode
    let returning_sql (query : _ returning) = query.sql
    let returning_params (query : _ returning) = List.map value_of_param query.params
    let returning_decode (query : _ returning) = query.decode
    let change_sql (query : change) = query.sql
    let change_params (query : change) = List.map value_of_param query.params
    let schema_sql (schema : schema) = schema.sql
  end

  let params_to_values params = List.map Compiled.value_of_param params

  let quote_ident name =
    if String.equal name "" then
      invalid_arg (Backend.module_name ^ " identifiers must not be empty");
    let len = String.length name in
    let extra_quotes = ref 0 in
    for i = 0 to len - 1 do
      if Char.equal (String.unsafe_get name i) '"' then
        incr extra_quotes
    done;
    let out = Bytes.create (len + !extra_quotes + 2) in
    Bytes.unsafe_set out 0 '"';
    let pos = ref 1 in
    for i = 0 to len - 1 do
      let c = String.unsafe_get name i in
      Bytes.unsafe_set out !pos c;
      incr pos;
      if Char.equal c '"' then begin
        Bytes.unsafe_set out !pos '"';
        incr pos
      end
    done;
    Bytes.unsafe_set out !pos '"';
    Bytes.unsafe_to_string out

  let table_sql (table : _ table) = table.quoted_table_name
  let table_from_sql (table : _ table) = table.from_sql
  let column_ident (column : (_, _) column) = column.quoted_column_name
  let column_sql (column : (_, _) column) = column.qualified_column_name
  let column_value (column : (_, 'a) column) value = column.typ.value value

  let coerce_column column =
    {
      table_name = column.table_name;
      column_name = column.column_name;
      typ = column.typ;
      quoted_column_name = column.quoted_column_name;
      qualified_column_name = column.qualified_column_name;
    }

  module Table = struct
    type 'table t = 'table table

    module Make (Name : sig
      val name : string
    end) =
    struct
      type table

      let quoted_table_name = quote_ident Name.name

      let table : table t =
        {
          table_name = Name.name;
          quoted_table_name;
          from_sql = quoted_table_name;
          column_qualifier = quoted_table_name;
        }

      let column name typ =
        let quoted_column_name = quote_ident name in
        {
          table_name = Name.name;
          column_name = name;
          typ;
          quoted_column_name;
          qualified_column_name = table.column_qualifier ^ "." ^ quoted_column_name;
        }
    end

    let name (table : _ t) = table.table_name

    let alias table alias =
      let quoted_alias = quote_ident alias in
      {
        table with
        from_sql = table.quoted_table_name ^ " AS " ^ quoted_alias;
        column_qualifier = quoted_alias;
      }

    let column (table : _ t) name typ =
      let quoted_column_name = quote_ident name in
      {
        table_name = table.table_name;
        column_name = name;
        typ;
        quoted_column_name;
        qualified_column_name = table.column_qualifier ^ "." ^ quoted_column_name;
      }
  end

  module Column = struct
    type ('table, 'a) t = ('table, 'a) column

    let name column = column.column_name
    let table_name column = column.table_name
  end

  module Expr = struct
    type ('scope, 'a) t = {
      sql : string;
      params : param list;
      typ : 'a typ;
    }

    let true_ = { sql = "1"; params = []; typ = bool }
    let false_ = { sql = "0"; params = []; typ = bool }
    let lit typ value = { sql = "?"; params = [ Param (typ, value) ]; typ }
    let int_lit value = lit int value
    let int64_lit value = lit int64 value
    let float_lit value = lit float value
    let text_lit value = lit text value
    let bool_lit value = lit bool value
    let col column = { sql = column_sql column; params = []; typ = column.typ }

    let render_binary op left right typ =
      {
        sql = "(" ^ left.sql ^ " " ^ op ^ " " ^ right.sql ^ ")";
        params = left.params @ right.params;
        typ;
      }

    let compare op left right = render_binary op left right bool

    let binary op column value =
      compare op (col column) (lit column.typ value)

    let eq column value = binary "=" column value
    let ne column value = binary "<>" column value
    let gt column value = binary ">" column value
    let ge column value = binary ">=" column value
    let lt column value = binary "<" column value
    let le column value = binary "<=" column value
    let like column value = binary "LIKE" column value

    let eq_expr left right = compare "=" left right
    let ne_expr left right = compare "<>" left right
    let gt_expr left right = compare ">" left right
    let ge_expr left right = compare ">=" left right
    let lt_expr left right = compare "<" left right
    let le_expr left right = compare "<=" left right

    let eq_col left right = eq_expr (col left) (col right)
    let gt_col left right = gt_expr (col left) (col right)
    let ge_col left right = ge_expr (col left) (col right)
    let lt_col left right = lt_expr (col left) (col right)
    let le_col left right = le_expr (col left) (col right)

    let add left right = render_binary "+" left right left.typ
    let sub left right = render_binary "-" left right left.typ
    let mul left right = render_binary "*" left right left.typ
    let div left right = render_binary "/" left right left.typ

    let is_null column =
      { sql = column_sql column ^ " IS NULL"; params = []; typ = bool }

    let is_not_null column =
      { sql = column_sql column ^ " IS NOT NULL"; params = []; typ = bool }

    let between column lower upper =
      {
        sql = column_sql column ^ " BETWEEN ? AND ?";
        params = [ Param (column.typ, lower); Param (column.typ, upper) ];
        typ = bool;
      }

    let in_values column values =
      match values with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Expr.in_values: values must not be empty")
      | values ->
          let placeholders =
            values |> List.map (fun _ -> "?") |> String.concat ", "
          in
          {
            sql = column_sql column ^ " IN (" ^ placeholders ^ ")";
            params = List.map (fun value -> Param (column.typ, value)) values;
            typ = bool;
          }

    let in_select column (query : _ Compiled.select) =
      {
        sql = column_sql column ^ " IN (" ^ query.sql ^ ")";
        params = query.params;
        typ = bool;
      }

    let exists (query : _ Compiled.select) =
      { sql = "EXISTS (" ^ query.sql ^ ")"; params = query.params; typ = bool }

    let count () = { sql = "COUNT(*)"; params = []; typ = int }

    let aggregate name typ (column : (_, _) column) =
      { sql = name ^ "(" ^ column_sql column ^ ")"; params = []; typ }

    let sum_int column = aggregate "SUM" (nullable int) column
    let sum_float column = aggregate "SUM" (nullable float) column
    let avg column = aggregate "AVG" (nullable float) column
    let min (column : (_, _) column) = aggregate "MIN" (nullable column.typ) column
    let max (column : (_, _) column) = aggregate "MAX" (nullable column.typ) column

    let case branches ~default =
      match branches with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Expr.case: branches must not be empty")
      | branches ->
          let buf = Buffer.create 96 in
          Buffer.add_string buf "CASE";
          let params = ref [] in
          List.iter
            (fun (condition, value) ->
              Buffer.add_string buf " WHEN ";
              Buffer.add_string buf condition.sql;
              Buffer.add_string buf " THEN ";
              Buffer.add_string buf value.sql;
              params := !params @ condition.params @ value.params)
            branches;
          Buffer.add_string buf " ELSE ";
          Buffer.add_string buf default.sql;
          Buffer.add_string buf " END";
          {
            sql = Buffer.contents buf;
            params = !params @ default.params;
            typ = default.typ;
          }

    let join op left right =
      let len =
        String.length left.sql + String.length op + String.length right.sql + 5
      in
      let buf = Buffer.create len in
      Buffer.add_char buf '(';
      Buffer.add_string buf left.sql;
      Buffer.add_char buf ' ';
      Buffer.add_string buf op;
      Buffer.add_char buf ' ';
      Buffer.add_string buf right.sql;
      Buffer.add_char buf ')';
      { sql = Buffer.contents buf; params = left.params @ right.params; typ = bool }

    let and_ left right = join "AND" left right
    let or_ left right = join "OR" left right
    let not_ expr =
      let buf = Buffer.create (String.length expr.sql + 6) in
      Buffer.add_string buf "NOT (";
      Buffer.add_string buf expr.sql;
      Buffer.add_char buf ')';
      { sql = Buffer.contents buf; params = expr.params; typ = bool }

    let count_eq value = eq_expr (count ()) (int_lit value)
    let count_gt value = gt_expr (count ()) (int_lit value)
    let count_ge value = ge_expr (count ()) (int_lit value)
  end

  module Projection = struct
    type ('scope, 'a) t = {
      columns : string list;
      params : param list;
      width : int;
      decode : Backend.row -> int -> 'a;
    }

    let one column =
      {
        columns = [ column_sql column ];
        params = [];
        width = 1;
        decode = (fun row offset -> column.typ.decode row offset);
      }

    let expr ?as_ expr =
      let sql =
        match as_ with
        | None -> expr.Expr.sql
        | Some alias -> expr.sql ^ " AS " ^ quote_ident alias
      in
      {
        columns = [ sql ];
        params = expr.params;
        width = 1;
        decode = (fun row offset -> expr.typ.decode row offset);
      }

    let map f row =
      { row with decode = (fun stmt offset -> f (row.decode stmt offset)) }

    let combine left right f =
      {
        columns = left.columns @ right.columns;
        params = left.params @ right.params;
        width = left.width + right.width;
        decode =
          (fun row offset ->
            f (left.decode row offset) (right.decode row (offset + left.width)));
      }

    let t2 p1 p2 = combine p1 p2 (fun a b -> (a, b))

    let t3 p1 p2 p3 =
      t2 (t2 p1 p2) p3 |> map (fun ((a, b), c) -> (a, b, c))

    let count ?as_ () = expr ?as_ (Expr.count ())
    let sum_int ?as_ column = expr ?as_ (Expr.sum_int column)
    let sum_float ?as_ column = expr ?as_ (Expr.sum_float column)
    let avg ?as_ column = expr ?as_ (Expr.avg column)
    let min ?as_ column = expr ?as_ (Expr.min column)
    let max ?as_ column = expr ?as_ (Expr.max column)

    let row_number ?as_ ?(partition_by = []) ?order_by () =
      let clauses =
        [
          (match partition_by with
           | [] -> None
           | columns ->
               Some
                 ("PARTITION BY "
                 ^ String.concat ", " (List.map column_sql columns)));
          Option.map (fun column -> "ORDER BY " ^ column_sql column) order_by;
        ]
        |> List.filter_map Fun.id
      in
      let sql = "ROW_NUMBER() OVER (" ^ String.concat " " clauses ^ ")" in
      let sql =
        match as_ with
        | None -> sql
        | Some alias -> sql ^ " AS " ^ quote_ident alias
      in
      {
        columns = [ sql ];
        params = [];
        width = 1;
        decode = (fun row offset -> int.decode row offset);
      }

    let t4 p1 p2 p3 p4 =
      t2 (t3 p1 p2 p3) p4 |> map (fun ((a, b, c), d) -> (a, b, c, d))

    let t5 p1 p2 p3 p4 p5 =
      t2 (t4 p1 p2 p3 p4) p5
      |> map (fun ((a, b, c, d), e) -> (a, b, c, d, e))

    let t6 p1 p2 p3 p4 p5 p6 =
      t2 (t5 p1 p2 p3 p4 p5) p6
      |> map (fun ((a, b, c, d, e), f) -> (a, b, c, d, e, f))

    let t7 p1 p2 p3 p4 p5 p6 p7 =
      t2 (t6 p1 p2 p3 p4 p5 p6) p7
      |> map (fun ((a, b, c, d, e, f), g) -> (a, b, c, d, e, f, g))

    let t8 p1 p2 p3 p4 p5 p6 p7 p8 =
      t2 (t7 p1 p2 p3 p4 p5 p6 p7) p8
      |> map (fun ((a, b, c, d, e, f, g), h) -> (a, b, c, d, e, f, g, h))
  end

  module Scope = struct
    type ('sub, 'super) contains =
      | Self : ('scope, 'scope) contains
      | Left : ('sub, 'super) contains -> ('sub, 'super * 'added) contains
      | Right : ('added, 'existing * 'added) contains

    let self = Self
    let left evidence = Left evidence
    let right = Right
    let column (_ : ('sub, 'super) contains) column = coerce_column column
  end

  module Join = struct
    let left column = Scope.column (Scope.left Scope.self) column
    let right column = Scope.column Scope.right column

    let on_eq left right =
      Expr.eq_col
        (Scope.column (Scope.left Scope.self) left)
        (Scope.column Scope.right right)
  end

  module Source = struct
    type 'scope t = {
      sql : string;
      params : param list;
    }

    let from table = { sql = table_from_sql table; params = [] }
    let table = from

    let join ?(op = `Inner) ~on added existing =
      let kind =
        match op with
        | `Inner -> "INNER"
        | `Left -> "LEFT"
      in
      let buf = Buffer.create 64 in
      Buffer.add_string buf existing.sql;
      Buffer.add_char buf ' ';
      Buffer.add_string buf kind;
      Buffer.add_string buf " JOIN ";
      Buffer.add_string buf (table_from_sql added);
      Buffer.add_string buf " ON ";
      Buffer.add_string buf on.Expr.sql;
      { sql = Buffer.contents buf; params = existing.params @ on.Expr.params }

    let inner_join left right ~on = join ~op:`Inner left right ~on
    let left_join left right ~on = join ~op:`Left left right ~on
  end

  module Select = struct
    type order = {
      sql : string;
      desc : bool;
    }

    type ('scope, 'a) t = {
      ctes : (string * param list) list;
      source : 'scope Source.t;
      row : ('scope, 'a) Projection.t;
      distinct : bool;
      where_ : ('scope, bool) Expr.t option;
      group_by : string list;
      having : ('scope, bool) Expr.t option;
      order_by : order list;
      limit : int option;
    }

    let from table row =
      {
        ctes = [];
        source = Source.from table;
        row;
        distinct = false;
        where_ = None;
        group_by = [];
        having = None;
        order_by = [];
        limit = None;
      }

    let from_source source row =
      {
        ctes = [];
        source;
        row;
        distinct = false;
        where_ = None;
        group_by = [];
        having = None;
        order_by = [];
        limit = None;
      }

    let with_cte ~name (cte : _ Compiled.select) query =
      {
        query with
        ctes = query.ctes @ [ (quote_ident name ^ " AS (" ^ cte.sql ^ ")", cte.params) ];
      }

    let distinct query = { query with distinct = true }
    let where expr query = { query with where_ = Some expr }

    let group_by column query =
      { query with group_by = query.group_by @ [ column_sql column ] }

    let group_by_many columns query =
      match columns with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Select.group_by_many: columns must not be empty")
      | columns ->
          { query with group_by = query.group_by @ List.map column_sql columns }

    let having expr query = { query with having = Some expr }

    let order_by ?(desc = false) column query =
      {
        query with
        order_by = query.order_by @ [ { sql = column_sql column; desc } ];
      }

    let limit count query =
      if count < 0 then
        invalid_arg (Backend.module_name ^ ".Select.limit: count must be non-negative");
      { query with limit = Some count }

    let params query =
      let where_params =
        match query.where_ with
        | None -> []
        | Some expr -> expr.Expr.params
      in
      let having_params =
        match query.having with
        | None -> []
        | Some expr -> expr.Expr.params
      in
      let cte_params = List.concat_map snd query.ctes in
      cte_params @ query.row.Projection.params @ query.source.Source.params
      @ where_params @ having_params

    let to_sql query =
      let buf = Buffer.create 192 in
      (match query.ctes with
       | [] -> ()
       | ctes ->
           Buffer.add_string buf "WITH ";
           List.iteri
             (fun i (sql, _) ->
               if i > 0 then Buffer.add_string buf ", ";
               Buffer.add_string buf sql)
             ctes;
           Buffer.add_char buf ' ');
      Buffer.add_string buf "SELECT ";
      if query.distinct then Buffer.add_string buf "DISTINCT ";
      List.iteri
        (fun i col ->
          if i > 0 then Buffer.add_string buf ", ";
          Buffer.add_string buf col)
        query.row.Projection.columns;
      Buffer.add_string buf " FROM ";
      Buffer.add_string buf query.source.Source.sql;
      (match query.where_ with
       | None -> ()
       | Some expr ->
           Buffer.add_string buf " WHERE ";
           Buffer.add_string buf expr.Expr.sql);
      (match query.group_by with
       | [] -> ()
       | columns ->
           Buffer.add_string buf " GROUP BY ";
           List.iteri
             (fun i col ->
               if i > 0 then Buffer.add_string buf ", ";
               Buffer.add_string buf col)
             columns);
      (match query.having with
       | None -> ()
       | Some expr ->
           Buffer.add_string buf " HAVING ";
           Buffer.add_string buf expr.Expr.sql);
      (match query.order_by with
       | [] -> ()
       | orders ->
           Buffer.add_string buf " ORDER BY ";
           List.iteri
             (fun i { sql; desc } ->
               if i > 0 then Buffer.add_string buf ", ";
               Buffer.add_string buf sql;
               Buffer.add_string buf (if desc then " DESC" else " ASC"))
             orders);
      (match query.limit with
       | None -> ()
       | Some count ->
           Buffer.add_string buf " LIMIT ";
           Buffer.add_string buf (Int.to_string count));
      Buffer.contents buf

    let compile query : _ Compiled.select =
      Compiled.
        {
          sql = to_sql query;
          params = params query;
          decode = (fun row -> query.row.decode row 0);
        }
  end

  module Assignment = struct
    type 'table t = Set : ('table, 'a) column * 'a -> 'table t

    let column_sql (Set (column, _)) = column_ident column
    let set_sql assignment = column_sql assignment ^ " = ?"
    let value (Set (column, value)) = Param (column.typ, value)
  end

  module Insert = struct
    type 'table conflict =
      | Do_nothing of string list
      | Do_update_excluded of string list * string list

    type 'table t = {
      table : 'table table;
      values : 'table Assignment.t list;
      conflict : 'table conflict option;
    }

    let into table = { table; values = []; conflict = None }

    let value column value query =
      { query with values = query.values @ [ Assignment.Set (column, value) ] }

    let render_values values =
      match values with
      | [] -> Result.Error (Backend.invalid_query "INSERT requires at least one value")
      | values ->
          let columns = List.map Assignment.column_sql values |> String.concat ", " in
          let placeholders = List.map (fun _ -> "?") values |> String.concat ", " in
          Ok (columns, placeholders)

    let conflict_target columns =
      match columns with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Insert.on_conflict: target columns must not be empty")
      | columns -> List.map column_ident columns

    let on_conflict_do_nothing columns query =
      { query with conflict = Some (Do_nothing (conflict_target columns)) }

    let on_conflict_update columns ~set query =
      match set with
      | [] ->
          invalid_arg
            (Backend.module_name
           ^ ".Insert.on_conflict_update: set columns must not be empty")
      | set ->
          {
            query with
            conflict =
              Some
                (Do_update_excluded
                   (conflict_target columns, List.map column_ident set));
          }

    let conflict_sql = function
      | None -> ""
      | Some (Do_nothing target) ->
          let buf = Buffer.create 32 in
          Buffer.add_string buf " ON CONFLICT (";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf col)
            target;
          Buffer.add_string buf ") DO NOTHING";
          Buffer.contents buf
      | Some (Do_update_excluded (target, set)) ->
          let buf = Buffer.create 64 in
          Buffer.add_string buf " ON CONFLICT (";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf col)
            target;
          Buffer.add_string buf ") DO UPDATE SET ";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf col;
              Buffer.add_string buf " = excluded.";
              Buffer.add_string buf col)
            set;
          Buffer.contents buf

    let to_sql_precomputed (columns, placeholders) query =
      let buf = Buffer.create 64 in
      Buffer.add_string buf "INSERT INTO ";
      Buffer.add_string buf (table_sql query.table);
      Buffer.add_string buf " (";
      Buffer.add_string buf columns;
      Buffer.add_string buf ") VALUES (";
      Buffer.add_string buf placeholders;
      Buffer.add_char buf ')';
      let conflict = conflict_sql query.conflict in
      if not (String.equal conflict "") then Buffer.add_string buf conflict;
      Buffer.contents buf

    let to_sql query =
      match render_values query.values with
      | Result.Error err -> raise (Backend.Error err)
      | Ok (columns, placeholders) ->
          to_sql_precomputed (columns, placeholders) query

    let params query = List.map Assignment.value query.values

    let compile query =
      match render_values query.values with
      | Result.Error err -> raise (Backend.Error err)
      | Ok cols ->
          Compiled.{ sql = to_sql_precomputed cols query; params = params query }

    let returning projection query =
      match render_values query.values with
      | Result.Error err -> raise (Backend.Error err)
      | Ok cols ->
          let buf = Buffer.create 64 in
          Buffer.add_string buf (to_sql_precomputed cols query);
          Buffer.add_string buf " RETURNING ";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf col)
            projection.Projection.columns;
          Compiled.
            {
              sql = Buffer.contents buf;
              params = params query @ projection.Projection.params;
              decode = (fun row -> projection.decode row 0);
            }
  end

  module Update = struct
    type 'table t = {
      table : 'table table;
      sets : 'table Assignment.t list;
      where_ : ('table, bool) Expr.t option;
    }

    let table table = { table; sets = []; where_ = None }

    let set column value query =
      { query with sets = query.sets @ [ Assignment.Set (column, value) ] }

    let where expr query = { query with where_ = Some expr }

    let params query =
      let set_params = List.map Assignment.value query.sets in
      match query.where_ with
      | None -> set_params
      | Some expr -> set_params @ expr.Expr.params

    let render_sets sets =
      match sets with
      | [] ->
          raise
            (Backend.Error (Backend.invalid_query "UPDATE requires at least one set"))
      | _ ->
          let buf = Buffer.create 64 in
          List.iteri
            (fun i assignment ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf (Assignment.set_sql assignment))
            sets;
          Buffer.contents buf

    let to_sql query =
      let set_sql = render_sets query.sets in
      let buf = Buffer.create 64 in
      Buffer.add_string buf "UPDATE ";
      Buffer.add_string buf (table_sql query.table);
      Buffer.add_string buf " SET ";
      Buffer.add_string buf set_sql;
      (match query.where_ with
       | None -> ()
       | Some expr ->
           Buffer.add_string buf " WHERE ";
           Buffer.add_string buf expr.Expr.sql);
      Buffer.contents buf

    let compile query =
      let _ = render_sets query.sets in
      Compiled.{ sql = to_sql query; params = params query }

    let returning projection query =
      let _ = render_sets query.sets in
      let buf = Buffer.create 64 in
      Buffer.add_string buf (to_sql query);
      Buffer.add_string buf " RETURNING ";
      List.iteri
        (fun i col ->
          if i > 0 then Buffer.add_string buf ", ";
          Buffer.add_string buf col)
        projection.Projection.columns;
      Compiled.
        {
          sql = Buffer.contents buf;
          params = params query @ projection.Projection.params;
          decode = (fun row -> projection.decode row 0);
        }
  end

  module Delete = struct
    type 'table t = {
      table : 'table table;
      where_ : ('table, bool) Expr.t option;
    }

    let from table = { table; where_ = None }
    let where expr query = { query with where_ = Some expr }

    let params query =
      match query.where_ with
      | None -> []
      | Some expr -> expr.Expr.params

    let to_sql query =
      let buf = Buffer.create 32 in
      Buffer.add_string buf "DELETE FROM ";
      Buffer.add_string buf (table_sql query.table);
      (match query.where_ with
       | None -> ()
       | Some expr ->
           Buffer.add_string buf " WHERE ";
           Buffer.add_string buf expr.Expr.sql);
      Buffer.contents buf

    let compile query = Compiled.{ sql = to_sql query; params = params query }

    let returning projection query =
      let buf = Buffer.create 64 in
      Buffer.add_string buf (to_sql query);
      Buffer.add_string buf " RETURNING ";
      List.iteri
        (fun i col ->
          if i > 0 then Buffer.add_string buf ", ";
          Buffer.add_string buf col)
        projection.Projection.columns;
      Compiled.
        {
          sql = Buffer.contents buf;
          params = params query @ projection.Projection.params;
          decode = (fun row -> projection.decode row 0);
        }
  end

  module Eta_schema = struct
    type reference = {
      table_name : string;
      column_name : string option;
      on_delete : string option;
      on_update : string option;
    }

    type column_def = {
      name : string;
      sql_type : string;
      primary_key : bool;
      not_null : bool;
      unique : bool;
      default : string option;
      references : reference option;
    }

    type t =
      | Create_table of {
          if_not_exists : bool;
          table : string;
          columns : column_def list;
        }
      | Drop_table of {
          if_exists : bool;
          table : string;
        }
      | Create_index of {
          unique : bool;
          if_not_exists : bool;
          name : string;
          table : string;
          columns : string list;
        }

    let reference_action label action =
      let normalized = String.uppercase_ascii (String.trim action) in
      match normalized with
      | "CASCADE" | "RESTRICT" | "SET NULL" | "SET DEFAULT" | "NO ACTION" ->
          normalized
      | _ ->
          invalid_arg
            (Backend.module_name ^ ".Eta_schema.references: invalid " ^ label)

    let references ?on_delete ?on_update (column : (_, _) column) =
      {
        table_name = column.table_name;
        column_name = Some column.column_name;
        on_delete = Option.map (reference_action "on_delete") on_delete;
        on_update = Option.map (reference_action "on_update") on_update;
      }

    let column ?(primary_key = false) ?(not_null = false) ?(unique = false)
        ?default ?references (column : (_, _) column) =
      {
        name = column.column_name;
        sql_type = column.typ.sql_type;
        primary_key;
        not_null;
        unique;
        default =
          Option.map
            (fun value -> Backend.value_to_sql_literal (column.typ.value value))
            default;
        references;
      }

    let create_table ?(if_not_exists = false) (table : _ table) columns =
      if columns = [] then
        invalid_arg
          (Backend.module_name ^ ".Eta_schema.create_table: columns must not be empty");
      Create_table { if_not_exists; table = table.table_name; columns }

    let drop_table ?(if_exists = false) (table : _ table) =
      Drop_table { if_exists; table = table.table_name }

    let create_index ?(unique = false) ?(if_not_exists = false) ~name
        (table : _ table) columns =
      if columns = [] then
        invalid_arg
          (Backend.module_name ^ ".Eta_schema.create_index: columns must not be empty");
      Create_index
        {
          unique;
          if_not_exists;
          name;
          table = table.table_name;
          columns = List.map (fun (column : (_, _) column) -> column.column_name) columns;
        }

    let reference_sql reference =
      let buf = Buffer.create 48 in
      Buffer.add_string buf " REFERENCES ";
      Buffer.add_string buf (quote_ident reference.table_name);
      (match reference.column_name with
       | None -> ()
       | Some column ->
           Buffer.add_string buf " (";
           Buffer.add_string buf (quote_ident column);
           Buffer.add_char buf ')');
      (match reference.on_delete with
       | None -> ()
       | Some action -> Buffer.add_string buf " ON DELETE "; Buffer.add_string buf action);
      (match reference.on_update with
       | None -> ()
       | Some action -> Buffer.add_string buf " ON UPDATE "; Buffer.add_string buf action);
      Buffer.contents buf

    let column_sql def =
      let buf = Buffer.create 64 in
      Buffer.add_string buf (quote_ident def.name);
      Buffer.add_char buf ' ';
      Buffer.add_string buf def.sql_type;
      if def.primary_key then Buffer.add_string buf " PRIMARY KEY";
      if def.not_null then Buffer.add_string buf " NOT NULL";
      if def.unique then Buffer.add_string buf " UNIQUE";
      (match def.default with
       | None -> ()
       | Some value -> Buffer.add_string buf " DEFAULT "; Buffer.add_string buf value);
      (match def.references with
       | None -> ()
       | Some ref -> Buffer.add_string buf (reference_sql ref));
      Buffer.contents buf

    let to_sql = function
      | Create_table { if_not_exists; table; columns } ->
          let buf = Buffer.create 128 in
          Buffer.add_string buf "CREATE TABLE ";
          if if_not_exists then Buffer.add_string buf "IF NOT EXISTS ";
          Buffer.add_string buf (quote_ident table);
          Buffer.add_string buf " (";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf (column_sql col))
            columns;
          Buffer.add_char buf ')';
          Buffer.contents buf
      | Drop_table { if_exists; table } ->
          let buf = Buffer.create 32 in
          Buffer.add_string buf "DROP TABLE ";
          if if_exists then Buffer.add_string buf "IF EXISTS ";
          Buffer.add_string buf (quote_ident table);
          Buffer.contents buf
      | Create_index { unique; if_not_exists; name; table; columns } ->
          let buf = Buffer.create 64 in
          Buffer.add_string buf "CREATE ";
          if unique then Buffer.add_string buf "UNIQUE ";
          Buffer.add_string buf "INDEX ";
          if if_not_exists then Buffer.add_string buf "IF NOT EXISTS ";
          Buffer.add_string buf (quote_ident name);
          Buffer.add_string buf " ON ";
          Buffer.add_string buf (quote_ident table);
          Buffer.add_string buf " (";
          List.iteri
            (fun i col ->
              if i > 0 then Buffer.add_string buf ", ";
              Buffer.add_string buf (quote_ident col))
            columns;
          Buffer.add_char buf ')';
          Buffer.contents buf

    let compile schema = Compiled.{ sql = to_sql schema }
  end
end
