module type BACKEND = sig
  type value
  type row
  type error

  exception Error of error

  type 'a typ = {
    value : ('a -> value);
    decode : (row -> int -> 'a);
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


module Make (Backend : BACKEND) = struct
  (* The backend contract owns rendering and row decoding for compiled queries. *)
  type value = Backend.value
  type row = Backend.row
  type error = Backend.error

  type 'a typ = 'a Backend.typ = {
    value : ('a -> Backend.value);
    decode : (Backend.row -> int -> 'a);
    sql_type : string;
  }

  let int = Backend.int
  let int64 = Backend.int64
  let bool = Backend.bool
  let float = Backend.float
  let text = Backend.text
  let nullable = Backend.nullable

  module Numeric = struct
    type 'a t = unit

    let int = ()
    let int64 = ()
    let float = ()
  end

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

  module Compiled = Eta_sql_dsl_compiled.Make (Backend) (struct
    type t = param
    let value_of_param (Param (typ, value)) = typ.value value

    let value = value_of_param
  end)

  let append_params left right =
    match (left, right) with
    | [], params | params, [] -> params
    | _ -> left @ right

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

  let coerce_nullable_column column =
    {
      table_name = column.table_name;
      column_name = column.column_name;
      typ = nullable column.typ;
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
        params = append_params left.params right.params;
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

    let add _ left right = render_binary "+" left right left.typ
    let sub _ left right = render_binary "-" left right left.typ
    let mul _ left right = render_binary "*" left right left.typ
    let div _ left right = render_binary "/" left right left.typ

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

    let placeholders count =
      let buf = Buffer.create ((count * 3) - 2) in
      for index = 1 to count do
        if index > 1 then Buffer.add_string buf ", ";
        Buffer.add_char buf '?'
      done;
      Buffer.contents buf

    let in_values column values =
      match values with
      | [] -> false_
      | values ->
          let placeholders = placeholders (List.length values) in
          {
            sql = column_sql column ^ " IN (" ^ placeholders ^ ")";
            params = List.map (fun value -> Param (column.typ, value)) values;
            typ = bool;
          }

    let in_select column (query : _ Compiled.select) =
      if query.width <> 1 then
        raise
          (Backend.Error
             (Backend.invalid_query
                "Expr.in_select requires a one-column subquery"));
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
    let avg _ column = aggregate "AVG" (nullable float) column
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
              params :=
                List.rev_append value.params
                  (List.rev_append condition.params !params))
            branches;
          Buffer.add_string buf " ELSE ";
          Buffer.add_string buf default.sql;
          Buffer.add_string buf " END";
          {
            sql = Buffer.contents buf;
            params = List.rev_append !params default.params;
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
      {
        sql = Buffer.contents buf;
        params = append_params left.params right.params;
        typ = bool;
      }

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
        columns = append_params left.columns right.columns;
        params = append_params left.params right.params;
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
    let avg ?as_ numeric column = expr ?as_ (Expr.avg numeric column)
    let min ?as_ column = expr ?as_ (Expr.min column)
    let max ?as_ column = expr ?as_ (Expr.max column)

    let row_number ?as_ ?(partition_by = []) ?order_by () =
      let buf = Buffer.create 32 in
      Buffer.add_string buf "ROW_NUMBER() OVER (";
      (match partition_by with
       | [] -> ()
       | columns ->
           Buffer.add_string buf "PARTITION BY ";
           List.iteri
             (fun index column ->
               if index > 0 then Buffer.add_string buf ", ";
               Buffer.add_string buf (column_sql column))
             columns);
      (match order_by with
       | None -> ()
       | Some column ->
           if partition_by <> [] then Buffer.add_char buf ' ';
           Buffer.add_string buf "ORDER BY ";
           Buffer.add_string buf (column_sql column));
      Buffer.add_char buf ')';
      let sql = Buffer.contents buf in
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
    let nullable_column (_ : ('sub, 'super) contains) column =
      coerce_nullable_column column
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
      rev_params : param list;
    }

    let from table = { sql = table_from_sql table; rev_params = [] }
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
      {
        sql = Buffer.contents buf;
        rev_params = List.rev_append on.Expr.params existing.rev_params;
      }

    let inner_join left right ~on = join ~op:`Inner left right ~on
    let left_join left right ~on = join ~op:`Left left right ~on
  end

  module Select = struct
    type order = {
      sql : string;
      desc : bool;
    }

    type ('scope, 'a) t = {
      rev_ctes : (string * param list) list;
      source : 'scope Source.t;
      row : ('scope, 'a) Projection.t;
      distinct : bool;
      where_ : ('scope, bool) Expr.t option;
      rev_group_by : string list;
      having : ('scope, bool) Expr.t option;
      rev_order_by : order list;
      limit : int option;
    }

    let from table row =
      {
        rev_ctes = [];
        source = Source.from table;
        row;
        distinct = false;
        where_ = None;
        rev_group_by = [];
        having = None;
        rev_order_by = [];
        limit = None;
      }

    let from_source source row =
      {
        rev_ctes = [];
        source;
        row;
        distinct = false;
        where_ = None;
        rev_group_by = [];
        having = None;
        rev_order_by = [];
        limit = None;
      }

    let with_cte ~name (cte : _ Compiled.select) query =
      {
        query with
        rev_ctes = (quote_ident name ^ " AS (" ^ cte.sql ^ ")", cte.params) :: query.rev_ctes;
      }

    let distinct query = { query with distinct = true }
    let where expr query = { query with where_ = Some expr }

    let group_by column query =
      { query with rev_group_by = column_sql column :: query.rev_group_by }

    let group_by_many columns query =
      match columns with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Select.group_by_many: columns must not be empty")
      | columns ->
          {
            query with
            rev_group_by =
              List.fold_left
                (fun acc column -> column_sql column :: acc)
                query.rev_group_by columns;
          }

    let having expr query = { query with having = Some expr }

    let order_by ?(desc = false) column query =
      {
        query with
        rev_order_by = { sql = column_sql column; desc } :: query.rev_order_by;
      }

    let limit count query =
      if count < 0 then
        invalid_arg (Backend.module_name ^ ".Select.limit: count must be non-negative");
      { query with limit = Some count }

    let rec add_cte_params acc = function
      | [] -> acc
      | (_, params) :: rest ->
          let acc = add_cte_params acc rest in
          List.rev_append params acc

    let add_expr_params opt acc =
      match opt with
      | None -> acc
      | Some expr -> List.rev_append expr.Expr.params acc

    let rec prepend_all values acc =
      match values with
      | [] -> acc
      | value :: rest -> value :: prepend_all rest acc

    let params query =
      add_cte_params [] query.rev_ctes
      |> List.rev_append query.row.Projection.params
      |> prepend_all query.source.Source.rev_params
      |> add_expr_params query.where_
      |> add_expr_params query.having
      |> List.rev

    let to_sql query =
      let buf = Buffer.create 192 in
      (match List.rev query.rev_ctes with
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
      (match List.rev query.rev_group_by with
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
      (match List.rev query.rev_order_by with
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
          width = query.row.Projection.width;
          decode = (fun row -> query.row.decode row 0);
        }
  end

  module Assignment = struct
    type 'table t = Set : ('table, 'a) column * 'a -> 'table t

    let column_sql (Set (column, _)) = column_ident column
    let set_sql assignment = column_sql assignment ^ " = ?"
    let value (Set (column, value)) = Param (column.typ, value)
  end

  let[@inline always] render_returning_sql sql columns =
    let buf = Buffer.create 64 in
    Buffer.add_string buf sql;
    Buffer.add_string buf " RETURNING ";
    List.iteri
      (fun i column ->
        if i > 0 then Buffer.add_string buf ", ";
        Buffer.add_string buf column)
      columns;
    Buffer.contents buf

  module Insert = struct
    type 'table conflict =
      | Do_nothing of string list
      | Do_update_excluded of string list * string list

    type 'table t = {
      table : 'table table;
      rev_values : 'table Assignment.t list;
      conflict : 'table conflict option;
    }

    let into table = { table; rev_values = []; conflict = None }

    let value column value query =
      { query with rev_values = Assignment.Set (column, value) :: query.rev_values }

    let concat3_sep sep a b c =
      let sep_len = String.length sep in
      let a_len = String.length a
      and b_len = String.length b
      and c_len = String.length c in
      let out = Bytes.create (a_len + b_len + c_len + (2 * sep_len)) in
      Bytes.blit_string a 0 out 0 a_len;
      Bytes.blit_string sep 0 out a_len sep_len;
      Bytes.blit_string b 0 out (a_len + sep_len) b_len;
      Bytes.blit_string sep 0 out (a_len + sep_len + b_len) sep_len;
      Bytes.blit_string c 0 out (a_len + (2 * sep_len) + b_len) c_len;
      Bytes.unsafe_to_string out

    let render_values values =
      match values with
      | [] -> Result.Error (Backend.invalid_query "INSERT requires at least one value")
      | [ a; b; c ] ->
          Ok
            ( concat3_sep ", " (Assignment.column_sql a) (Assignment.column_sql b)
                (Assignment.column_sql c),
              "?, ?, ?" )
      | values ->
          let columns = Buffer.create 64 in
          let placeholders = Buffer.create 32 in
          let rec add_values first = function
            | [] -> ()
            | value :: rest ->
                if not first then (
                  Buffer.add_string columns ", ";
                  Buffer.add_string placeholders ", ");
                Buffer.add_string columns (Assignment.column_sql value);
                Buffer.add_char placeholders '?';
                add_values false rest
          in
          add_values true values;
          Ok (Buffer.contents columns, Buffer.contents placeholders)

    let column_idents columns =
      List.map column_ident columns

    let conflict_target columns =
      match columns with
      | [] ->
          invalid_arg
            (Backend.module_name ^ ".Insert.on_conflict: target columns must not be empty")
      | columns -> column_idents columns

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
                   (conflict_target columns, column_idents set));
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
      match render_values (List.rev query.rev_values) with
      | Result.Error err -> raise (Backend.Error err)
      | Ok (columns, placeholders) ->
          to_sql_precomputed (columns, placeholders) query

    let rec prepend_values values acc =
      match values with
      | [] -> acc
      | value :: rest -> prepend_values rest (Assignment.value value :: acc)

    let params query = prepend_values query.rev_values []

    let compile query =
      match render_values (List.rev query.rev_values) with
      | Result.Error err -> raise (Backend.Error err)
      | Ok cols ->
          Compiled.{ sql = to_sql_precomputed cols query; params = params query }

    let returning projection query =
      match render_values (List.rev query.rev_values) with
      | Result.Error err -> raise (Backend.Error err)
      | Ok cols ->
          Compiled.
            {
              sql =
                render_returning_sql (to_sql_precomputed cols query)
                  projection.Projection.columns;
              params = prepend_values query.rev_values projection.Projection.params;
              decode = (fun row -> projection.decode row 0);
            }
  end

  module Update = struct
    type 'table t = {
      table : 'table table;
      rev_sets : 'table Assignment.t list;
      where_ : ('table, bool) Expr.t option;
    }

    let table table = { table; rev_sets = []; where_ = None }

    let set column value query =
      { query with rev_sets = Assignment.Set (column, value) :: query.rev_sets }

    let where expr query = { query with where_ = Some expr }

    let rec prepend_sets sets acc =
      match sets with
      | [] -> acc
      | set :: rest -> prepend_sets rest (Assignment.value set :: acc)

    let params query =
      let tail =
        match query.where_ with
        | None -> []
        | Some expr -> expr.Expr.params
      in
      prepend_sets query.rev_sets tail

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
      let set_sql = render_sets (List.rev query.rev_sets) in
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
      let _ = render_sets (List.rev query.rev_sets) in
      Compiled.{ sql = to_sql query; params = params query }

    let returning projection query =
      let _ = render_sets (List.rev query.rev_sets) in
      Compiled.
        {
          sql = render_returning_sql (to_sql query) projection.Projection.columns;
          params =
            prepend_sets query.rev_sets
              (match query.where_ with
               | None -> projection.Projection.params
               | Some expr -> append_params expr.Expr.params projection.Projection.params);
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
      Compiled.
        {
          sql = render_returning_sql (to_sql query) projection.Projection.columns;
          params =
            (match query.where_ with
             | None -> projection.Projection.params
             | Some expr -> append_params expr.Expr.params projection.Projection.params);
          decode = (fun row -> projection.decode row 0);
        }
  end

  module Schema_backend = struct
    type 'a typ = 'a Backend.typ

    let module_name = Backend.module_name
    let sql_type typ = typ.sql_type
    let literal typ value = Backend.value_to_sql_literal (typ.value value)
  end

  module Eta_schema = Eta_sql_dsl_schema.Make (Schema_backend) (struct
    type nonrec 'table table = 'table table = {
      table_name : string;
      quoted_table_name : string;
      from_sql : string;
      column_qualifier : string;
    }

    type nonrec ('table, 'a) column = ('table, 'a) column = {
      table_name : string;
      column_name : string;
      typ : 'a typ;
      quoted_column_name : string;
      qualified_column_name : string;
    }

    type compiled_schema = Compiled.schema

    let quote_ident = quote_ident
    let compiled_schema sql = Compiled.{ sql }
  end)
end
