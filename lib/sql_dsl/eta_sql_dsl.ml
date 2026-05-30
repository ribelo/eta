module type BACKEND = sig
  type value
  type row
  type error

  exception Error of error

  type 'a typ = {
    value : 'a -> value;
    decode : value -> 'a option;
    sql_type : string;
  }

  val int : int typ
  val invalid_query : string -> error
  val module_name : string
  val value_to_string : value -> string
  val row_value : int -> row -> value option
end

module Make (Backend : BACKEND) = struct
  type 'a typ = 'a Backend.typ = {
    value : 'a -> Backend.value;
    decode : Backend.value -> 'a option;
    sql_type : string;
  }

  let int = Backend.int

type 'table table = {
  table_name : string;
  quoted_table_name : string;
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
  let returning_sql (query : _ returning) = query.sql
  let returning_params (query : _ returning) = List.map value_of_param query.params
  let change_sql (query : change) = query.sql
  let change_params (query : change) = List.map value_of_param query.params
  let schema_sql (schema : schema) = schema.sql
end

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

let decode_column operation typ index row =
  match Backend.row_value index row with
  | None ->
      failwith
        (operation ^ ": result row does not contain column "
        ^ string_of_int (index + 1))
  | Some value -> (
      match typ.decode value with
      | Some decoded -> decoded
      | None -> failwith (operation ^ ": could not decode value " ^ Backend.value_to_string value))

let params_to_values params = List.map Compiled.value_of_param params

module Table = struct
  type 'table t = 'table table

  module Make (Name : sig
    val name : string
  end) =
  struct
    type table

    let quoted_table_name = quote_ident Name.name
    let table = { table_name = Name.name; quoted_table_name }

    let column name typ =
      let quoted_column_name = quote_ident name in
      {
        table_name = Name.name;
        column_name = name;
        typ;
        quoted_column_name;
        qualified_column_name = quoted_table_name ^ "." ^ quoted_column_name;
      }
  end

  let name (table : _ t) = table.table_name
end

module Column = struct
  type ('table, 'a) t = ('table, 'a) column

  let name column = column.column_name
  let table_name column = column.table_name
end

module Expr = struct
  type 'scope t = {
    sql : string;
    params : param list;
  }

  let true_ = { sql = "1"; params = [] }
  let false_ = { sql = "0"; params = [] }

  let binary op column value =
    {
      sql = String.concat " " [ column_sql column; op; "?" ];
      params = [ Param (column.typ, value) ];
    }

  let eq column value = binary "=" column value
  let ne column value = binary "<>" column value
  let gt column value = binary ">" column value
  let ge column value = binary ">=" column value
  let lt column value = binary "<" column value
  let le column value = binary "<=" column value
  let like column value = binary "LIKE" column value

  let eq_col left right =
    { sql = String.concat " = " [ column_sql left; column_sql right ]; params = [] }

  let is_null column = { sql = column_sql column ^ " IS NULL"; params = [] }
  let is_not_null column = { sql = column_sql column ^ " IS NOT NULL"; params = [] }
  let count_eq value = { sql = "COUNT(*) = ?"; params = [ Param (int, value) ] }
  let count_gt value = { sql = "COUNT(*) > ?"; params = [ Param (int, value) ] }
  let count_ge value = { sql = "COUNT(*) >= ?"; params = [ Param (int, value) ] }

  let in_select column (query : _ Compiled.select) =
    { sql = column_sql column ^ " IN (" ^ query.sql ^ ")"; params = query.params }

  let exists (query : _ Compiled.select) =
    { sql = "EXISTS (" ^ query.sql ^ ")"; params = query.params }

  let join op left right =
    let len = String.length left.sql + String.length op + String.length right.sql + 5 in
    let buf = Buffer.create len in
    Buffer.add_char buf '(';
    Buffer.add_string buf left.sql;
    Buffer.add_char buf ' ';
    Buffer.add_string buf op;
    Buffer.add_char buf ' ';
    Buffer.add_string buf right.sql;
    Buffer.add_char buf ')';
    { sql = Buffer.contents buf; params = left.params @ right.params }

  let and_ left right = join "AND" left right
  let or_ left right = join "OR" left right

  let not_ expr =
    let buf = Buffer.create (String.length expr.sql + 6) in
    Buffer.add_string buf "NOT (";
    Buffer.add_string buf expr.sql;
    Buffer.add_char buf ')';
    { sql = Buffer.contents buf; params = expr.params }
end

module Projection = struct
  type ('scope, 'a) t = {
    columns : string list;
    decode : Backend.row -> 'a;
  }

  let one column =
    { columns = [ column_sql column ]; decode = (fun row -> decode_column "projection" column.typ 0 row) }

  let t2 c1 c2 =
    {
      columns = [ column_sql c1; column_sql c2 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row ));
    }

  let t3 c1 c2 c3 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row ));
    }

  let count ?as_ () =
    let sql =
      match as_ with
      | None -> "COUNT(*)"
      | Some alias -> "COUNT(*) AS " ^ quote_ident alias
    in
    { columns = [ sql ]; decode = (fun row -> decode_column "count" int 0 row) }

  let sum_int ?as_ column =
    let sql = "SUM(" ^ column_sql column ^ ")" in
    let sql =
      match as_ with
      | None -> sql
      | Some alias -> sql ^ " AS " ^ quote_ident alias
    in
    { columns = [ sql ]; decode = (fun row -> decode_column "sum_int" int 0 row) }

  let row_number ?as_ ?(partition_by = []) ?order_by () =
    let clauses =
      [
        (match partition_by with
         | [] -> None
         | columns ->
             Some ("PARTITION BY " ^ String.concat ", " (List.map column_sql columns)));
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
    { columns = [ sql ]; decode = (fun row -> decode_column "row_number" int 0 row) }

  let t4 c1 c2 c3 c4 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row,
            decode_column "projection" c4.typ 3 row ));
    }

  let t5 c1 c2 c3 c4 c5 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row,
            decode_column "projection" c4.typ 3 row,
            decode_column "projection" c5.typ 4 row ));
    }

  let t6 c1 c2 c3 c4 c5 c6 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5; column_sql c6 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row,
            decode_column "projection" c4.typ 3 row,
            decode_column "projection" c5.typ 4 row,
            decode_column "projection" c6.typ 5 row ));
    }

  let t7 c1 c2 c3 c4 c5 c6 c7 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5; column_sql c6; column_sql c7 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row,
            decode_column "projection" c4.typ 3 row,
            decode_column "projection" c5.typ 4 row,
            decode_column "projection" c6.typ 5 row,
            decode_column "projection" c7.typ 6 row ));
    }

  let t8 c1 c2 c3 c4 c5 c6 c7 c8 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5; column_sql c6; column_sql c7; column_sql c8 ];
      decode =
        (fun row ->
          ( decode_column "projection" c1.typ 0 row,
            decode_column "projection" c2.typ 1 row,
            decode_column "projection" c3.typ 2 row,
            decode_column "projection" c4.typ 3 row,
            decode_column "projection" c5.typ 4 row,
            decode_column "projection" c6.typ 5 row,
            decode_column "projection" c7.typ 6 row,
            decode_column "projection" c8.typ 7 row ));
    }

  let map f row = { row with decode = (fun db_row -> f (row.decode db_row)) }
end

module Join = struct
  let left column = coerce_column column
  let right column = coerce_column column
  let on_eq left right = Expr.eq_col (coerce_column left) (coerce_column right)
end

module Source = struct
  type 'scope t = {
    sql : string;
    params : param list;
  }

  let table table = { sql = table_sql table; params = [] }

  let join kind left right ~on =
    let buf = Buffer.create 64 in
    Buffer.add_string buf (table_sql left);
    Buffer.add_char buf ' ';
    Buffer.add_string buf kind;
    Buffer.add_string buf " JOIN ";
    Buffer.add_string buf (table_sql right);
    Buffer.add_string buf " ON ";
    Buffer.add_string buf on.Expr.sql;
    { sql = Buffer.contents buf; params = on.Expr.params }

  let inner_join left right ~on = join "INNER" left right ~on
  let left_join left right ~on = join "LEFT" left right ~on
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
    where_ : 'scope Expr.t option;
    group_by : string list;
    having : 'scope Expr.t option;
    order_by : order list;
    limit : int option;
  }

  let from table row =
    { ctes = []; source = Source.table table; row; distinct = false; where_ = None; group_by = []; having = None; order_by = []; limit = None }

  let from_source source row =
    { ctes = []; source; row; distinct = false; where_ = None; group_by = []; having = None; order_by = []; limit = None }

  let with_cte ~name (cte : _ Compiled.select) query =
    { query with ctes = query.ctes @ [ (quote_ident name ^ " AS (" ^ cte.sql ^ ")", cte.params) ] }

  let distinct query = { query with distinct = true }
  let where expr query = { query with where_ = Some expr }
  let group_by column query = { query with group_by = query.group_by @ [ column_sql column ] }

  let group_by_many columns query =
    match columns with
    | [] -> invalid_arg (Backend.module_name ^ ".Select.group_by_many: columns must not be empty")
    | columns -> { query with group_by = query.group_by @ List.map column_sql columns }

  let having expr query = { query with having = Some expr }
  let order_by ?(desc = false) column query = { query with order_by = query.order_by @ [ { sql = column_sql column; desc } ] }

  let limit count query =
    if count < 0 then invalid_arg (Backend.module_name ^ ".Select.limit: count must be non-negative");
    { query with limit = Some count }

  let params query =
    let where_params = match query.where_ with None -> [] | Some expr -> expr.Expr.params in
    let having_params = match query.having with None -> [] | Some expr -> expr.Expr.params in
    let cte_params = List.concat_map snd query.ctes in
    cte_params @ query.source.Source.params @ where_params @ having_params

  let to_sql query =
    let buf = Buffer.create 192 in
    begin match query.ctes with
    | [] -> ()
    | ctes ->
        Buffer.add_string buf "WITH ";
        List.iteri (fun i (sql, _) -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf sql) ctes;
        Buffer.add_char buf ' '
    end;
    Buffer.add_string buf "SELECT ";
    if query.distinct then Buffer.add_string buf "DISTINCT ";
    List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) query.row.Projection.columns;
    Buffer.add_string buf " FROM ";
    Buffer.add_string buf query.source.Source.sql;
    begin match query.where_ with None -> () | Some expr -> Buffer.add_string buf " WHERE "; Buffer.add_string buf expr.Expr.sql end;
    begin match query.group_by with
    | [] -> ()
    | columns ->
        Buffer.add_string buf " GROUP BY ";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) columns
    end;
    begin match query.having with None -> () | Some expr -> Buffer.add_string buf " HAVING "; Buffer.add_string buf expr.Expr.sql end;
    begin match query.order_by with
    | [] -> ()
    | orders ->
        Buffer.add_string buf " ORDER BY ";
        List.iteri (fun i { sql; desc } -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf sql; Buffer.add_string buf (if desc then " DESC" else " ASC")) orders
    end;
    begin match query.limit with None -> () | Some count -> Buffer.add_string buf " LIMIT "; Buffer.add_string buf (Int.to_string count) end;
    Buffer.contents buf

  let compile query : _ Compiled.select =
    Compiled.{ sql = to_sql query; params = params query; decode = query.row.decode }
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
  let value column value query = { query with values = query.values @ [ Assignment.Set (column, value) ] }

  let render_values values =
    match values with
    | [] -> Result.Error (Backend.invalid_query "INSERT requires at least one value")
    | values ->
        let columns = List.map Assignment.column_sql values |> String.concat ", " in
        let placeholders = List.map (fun _ -> "?") values |> String.concat ", " in
        Ok (columns, placeholders)

  let conflict_target columns =
    match columns with
    | [] -> invalid_arg (Backend.module_name ^ ".Insert.on_conflict: target columns must not be empty")
    | columns -> List.map column_ident columns

  let on_conflict_do_nothing columns query = { query with conflict = Some (Do_nothing (conflict_target columns)) }

  let on_conflict_update columns ~set query =
    match set with
    | [] -> invalid_arg (Backend.module_name ^ ".Insert.on_conflict_update: set columns must not be empty")
    | set -> { query with conflict = Some (Do_update_excluded (conflict_target columns, List.map column_ident set)) }

  let conflict_sql = function
    | None -> ""
    | Some (Do_nothing target) ->
        let buf = Buffer.create 32 in
        Buffer.add_string buf " ON CONFLICT (";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) target;
        Buffer.add_string buf ") DO NOTHING";
        Buffer.contents buf
    | Some (Do_update_excluded (target, set)) ->
        let buf = Buffer.create 64 in
        Buffer.add_string buf " ON CONFLICT (";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) target;
        Buffer.add_string buf ") DO UPDATE SET ";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col; Buffer.add_string buf " = excluded."; Buffer.add_string buf col) set;
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
    | Ok values -> to_sql_precomputed values query

  let params query = List.map Assignment.value query.values

  let compile query =
    match render_values query.values with
    | Result.Error err -> raise (Backend.Error err)
    | Ok values -> Compiled.{ sql = to_sql_precomputed values query; params = params query }

  let returning projection query =
    match render_values query.values with
    | Result.Error err -> raise (Backend.Error err)
    | Ok values ->
        let buf = Buffer.create 64 in
        Buffer.add_string buf (to_sql_precomputed values query);
        Buffer.add_string buf " RETURNING ";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) projection.Projection.columns;
        Compiled.{ sql = Buffer.contents buf; params = params query; decode = projection.decode }
end

module Update = struct
  type 'table t = {
    table : 'table table;
    sets : 'table Assignment.t list;
    where_ : 'table Expr.t option;
  }

  let table table = { table; sets = []; where_ = None }
  let set column value query = { query with sets = query.sets @ [ Assignment.Set (column, value) ] }
  let where expr query = { query with where_ = Some expr }

  let params query =
    let set_params = List.map Assignment.value query.sets in
    match query.where_ with None -> set_params | Some expr -> set_params @ expr.Expr.params

  let render_sets sets =
    match sets with
    | [] -> raise (Backend.Error (Backend.invalid_query "UPDATE requires at least one set"))
    | _ ->
        let buf = Buffer.create 64 in
        List.iteri (fun i assignment -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf (Assignment.set_sql assignment)) sets;
        Buffer.contents buf

  let to_sql query =
    let set_sql = render_sets query.sets in
    let buf = Buffer.create 64 in
    Buffer.add_string buf "UPDATE ";
    Buffer.add_string buf (table_sql query.table);
    Buffer.add_string buf " SET ";
    Buffer.add_string buf set_sql;
    begin match query.where_ with None -> () | Some expr -> Buffer.add_string buf " WHERE "; Buffer.add_string buf expr.Expr.sql end;
    Buffer.contents buf

  let compile query =
    let _ = render_sets query.sets in
    Compiled.{ sql = to_sql query; params = params query }

  let returning projection query =
    let _ = render_sets query.sets in
    let buf = Buffer.create 64 in
    Buffer.add_string buf (to_sql query);
    Buffer.add_string buf " RETURNING ";
    List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) projection.Projection.columns;
    Compiled.{ sql = Buffer.contents buf; params = params query; decode = projection.decode }
end

module Delete = struct
  type 'table t = {
    table : 'table table;
    where_ : 'table Expr.t option;
  }

  let from table = { table; where_ = None }
  let where expr query = { query with where_ = Some expr }
  let params query = match query.where_ with None -> [] | Some expr -> expr.Expr.params

  let to_sql query =
    let buf = Buffer.create 32 in
    Buffer.add_string buf "DELETE FROM ";
    Buffer.add_string buf (table_sql query.table);
    begin match query.where_ with None -> () | Some expr -> Buffer.add_string buf " WHERE "; Buffer.add_string buf expr.Expr.sql end;
    Buffer.contents buf

  let compile query = Compiled.{ sql = to_sql query; params = params query }

  let returning projection query =
    let buf = Buffer.create 64 in
    Buffer.add_string buf (to_sql query);
    Buffer.add_string buf " RETURNING ";
    List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf col) projection.Projection.columns;
    Compiled.{ sql = Buffer.contents buf; params = params query; decode = projection.decode }
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

  let references ?on_delete ?on_update (column : (_, _) column) =
    { table_name = column.table_name; column_name = Some column.column_name; on_delete; on_update }

  let column ?(primary_key = false) ?(not_null = false) ?(unique = false) ?default ?references (column : (_, _) column) =
    { name = column.column_name; sql_type = column.typ.sql_type; primary_key; not_null; unique; default; references }

  let create_table ?(if_not_exists = false) (table : _ table) columns =
    if columns = [] then invalid_arg (Backend.module_name ^ ".Eta_schema.create_table: columns must not be empty");
    Create_table { if_not_exists; table = table.table_name; columns }

  let drop_table ?(if_exists = false) (table : _ table) = Drop_table { if_exists; table = table.table_name }

  let create_index ?(unique = false) ?(if_not_exists = false) ~name (table : _ table) columns =
    if columns = [] then invalid_arg (Backend.module_name ^ ".Eta_schema.create_index: columns must not be empty");
    Create_index { unique; if_not_exists; name; table = table.table_name; columns = List.map (fun (column : (_, _) column) -> column.column_name) columns }

  let reference_sql reference =
    let buf = Buffer.create 48 in
    Buffer.add_string buf " REFERENCES ";
    Buffer.add_string buf (quote_ident reference.table_name);
    begin match reference.column_name with None -> () | Some column -> Buffer.add_string buf " ("; Buffer.add_string buf (quote_ident column); Buffer.add_char buf ')' end;
    begin match reference.on_delete with None -> () | Some action -> Buffer.add_string buf " ON DELETE "; Buffer.add_string buf action end;
    begin match reference.on_update with None -> () | Some action -> Buffer.add_string buf " ON UPDATE "; Buffer.add_string buf action end;
    Buffer.contents buf

  let column_sql def =
    let buf = Buffer.create 64 in
    Buffer.add_string buf (quote_ident def.name);
    Buffer.add_char buf ' ';
    Buffer.add_string buf def.sql_type;
    if def.primary_key then Buffer.add_string buf " PRIMARY KEY";
    if def.not_null then Buffer.add_string buf " NOT NULL";
    if def.unique then Buffer.add_string buf " UNIQUE";
    begin match def.default with None -> () | Some value -> Buffer.add_string buf " DEFAULT "; Buffer.add_string buf value end;
    begin match def.references with None -> () | Some reference -> Buffer.add_string buf (reference_sql reference) end;
    Buffer.contents buf

  let to_sql = function
    | Create_table { if_not_exists; table; columns } ->
        let buf = Buffer.create 128 in
        Buffer.add_string buf "CREATE TABLE ";
        if if_not_exists then Buffer.add_string buf "IF NOT EXISTS ";
        Buffer.add_string buf (quote_ident table);
        Buffer.add_string buf " (";
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf (column_sql col)) columns;
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
        List.iteri (fun i col -> if i > 0 then Buffer.add_string buf ", "; Buffer.add_string buf (quote_ident col)) columns;
        Buffer.add_char buf ')';
        Buffer.contents buf

  let compile schema = Compiled.{ sql = to_sql schema }
end

end
