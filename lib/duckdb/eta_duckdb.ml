module Value = struct
  type t =
    | Null
    | Bool of bool
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bytes of bytes
    | Decimal of string
    | Date of string
    | Time of string
    | Timestamp of string
    | Uuid of string
    | Json of string
    | Enum of string
    | List of t list
    | Struct of (string * t) list

  let rec to_string = function
    | Null -> "NULL"
    | Bool true -> "true"
    | Bool false -> "false"
    | Int value -> string_of_int value
    | Int64 value -> Int64.to_string value
    | Float value -> string_of_float value
    | String value -> value
    | Bytes value -> Bytes.to_string value
    | Decimal value | Date value | Time value | Timestamp value | Uuid value
    | Json value | Enum value -> value
    | List values -> "[" ^ String.concat ", " (List.map to_string values) ^ "]"
    | Struct fields ->
        fields
        |> List.map (fun (name, value) -> name ^ "=" ^ to_string value)
        |> String.concat ", "
end

module Row = struct
  type t = (string * Value.t) list

  let get field row = List.assoc_opt field row
  let fields row = List.map fst row

  let int field row =
    match get field row with
    | Some (Value.Int value) -> Some value
    | Some (Int64 value) ->
        let min = Int64.of_int min_int in
        let max = Int64.of_int max_int in
        if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
          Some (Int64.to_int value)
        else
          None
    | _ -> None

  let int64 field row =
    match get field row with
    | Some (Value.Int value) -> Some (Int64.of_int value)
    | Some (Int64 value) -> Some value
    | _ -> None

  let string field row =
    match get field row with
    | Some (Value.String value | Decimal value | Date value | Time value
           | Timestamp value | Uuid value | Json value | Enum value) -> Some value
    | _ -> None

  let bool field row = match get field row with Some (Value.Bool value) -> Some value | _ -> None
  let float field row = match get field row with Some (Value.Float value) -> Some value | _ -> None
  let bytes field row = match get field row with Some (Value.Bytes value) -> Some value | _ -> None
end

type raw_database
type raw_connection
type raw_appender

type database = {
  raw : raw_database;
  mutable closed : bool;
}

type connection = {
  database : database;
  raw : raw_connection;
  mutable closed : bool;
}

type appender = {
  connection : connection;
  raw : raw_appender;
  mutable closed : bool;
}

type config = {
  path : string option;
  threads : int option;
}

type transaction_mode =
  | Deferred
  | Immediate

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      message : string;
    }
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

external raw_available : unit -> string option = "eta_duckdb_available"
external raw_version : unit -> string = "eta_duckdb_version"
external raw_open : string -> raw_database = "eta_duckdb_open"
external raw_close_database : raw_database -> unit = "eta_duckdb_close_database"
external raw_connect : raw_database -> raw_connection = "eta_duckdb_connect"
external raw_disconnect : raw_connection -> unit = "eta_duckdb_disconnect"
external raw_interrupt : raw_connection -> unit = "eta_duckdb_interrupt"
external raw_query : raw_connection -> string -> Value.t list -> Row.t list = "eta_duckdb_query"
external raw_execute : raw_connection -> string -> Value.t list -> int = "eta_duckdb_execute"
external raw_exec_script : raw_connection -> string -> unit = "eta_duckdb_exec_script"
external raw_appender_create : raw_connection -> string option -> string -> raw_appender = "eta_duckdb_appender_create"
external raw_appender_append_row : raw_appender -> Value.t list -> unit = "eta_duckdb_appender_append_row"
external raw_appender_flush : raw_appender -> unit = "eta_duckdb_appender_flush"
external raw_appender_close : raw_appender -> unit = "eta_duckdb_appender_close"

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "duckdb library unavailable: %s" message
  | Driver_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Decode_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Invalid_value message -> Format.fprintf ppf "invalid DuckDB value: %s" message
  | Closed -> Format.pp_print_string ppf "DuckDB handle is closed"

let show_error err = Format.asprintf "%a" pp_error err
let pp_duckdb_error = pp_error

let available () =
  match raw_available () with
  | None -> Ok ()
  | Some message -> Result.Error (Library_unavailable message)

let wrap operation f =
  match available () with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f () with
      | value -> Ok value
      | exception Failure message -> Result.Error (Driver_error { operation; message }))

let version () = wrap "version" raw_version
let if_database_open (db : database) f = if db.closed then Result.Error Closed else f ()

let if_connection_open (conn : connection) f =
  if conn.closed || conn.database.closed then Result.Error Closed else f ()

let if_appender_open (appender : appender) f =
  if appender.closed || appender.connection.closed then Result.Error Closed else f ()

type 'a typ = {
  value : 'a -> Value.t;
  decode : Value.t -> 'a option;
  sql_type : string;
}

let int =
  {
    value = (fun value -> Value.Int value);
    decode =
      (function
      | Value.Int value -> Some value
      | Int64 value ->
          let min = Int64.of_int min_int in
          let max = Int64.of_int max_int in
          if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
            Some (Int64.to_int value)
          else
            None
      | _ -> None);
    sql_type = "INTEGER";
  }

let int64 =
  {
    value = (fun value -> Value.Int64 value);
    decode =
      (function
      | Value.Int value -> Some (Int64.of_int value)
      | Int64 value -> Some value
      | _ -> None);
    sql_type = "BIGINT";
  }

let bool =
  {
    value = (fun value -> Value.Bool value);
    decode =
      (function
      | Value.Bool value -> Some value
      | Int 0 -> Some false
      | Int 1 -> Some true
      | Int64 0L -> Some false
      | Int64 1L -> Some true
      | _ -> None);
    sql_type = "BOOLEAN";
  }

let float =
  {
    value = (fun value -> Value.Float value);
    decode = (function Value.Float value -> Some value | _ -> None);
    sql_type = "DOUBLE";
  }

let text =
  {
    value = (fun value -> Value.String value);
    decode =
      (function
      | Value.String value | Decimal value | Date value | Time value | Timestamp value
      | Uuid value | Json value | Enum value -> Some value
      | _ -> None);
    sql_type = "VARCHAR";
  }

let blob =
  {
    value = (fun value -> Value.Bytes value);
    decode = (function Value.Bytes value -> Some value | _ -> None);
    sql_type = "BLOB";
  }

let decimal =
  {
    value = (fun value -> Value.Decimal value);
    decode = (function Value.Decimal value | String value -> Some value | _ -> None);
    sql_type = "DECIMAL";
  }

let date =
  {
    value = (fun value -> Value.Date value);
    decode = (function Value.Date value | String value -> Some value | _ -> None);
    sql_type = "DATE";
  }

let time =
  {
    value = (fun value -> Value.Time value);
    decode = (function Value.Time value | String value -> Some value | _ -> None);
    sql_type = "TIME";
  }

let timestamp =
  {
    value = (fun value -> Value.Timestamp value);
    decode = (function Value.Timestamp value | String value -> Some value | _ -> None);
    sql_type = "TIMESTAMP";
  }

let uuid =
  {
    value = (fun value -> Value.Uuid value);
    decode = (function Value.Uuid value | String value -> Some value | _ -> None);
    sql_type = "UUID";
  }

let json =
  {
    value = (fun value -> Value.Json value);
    decode = (function Value.Json value | String value -> Some value | _ -> None);
    sql_type = "JSON";
  }

let enum ?(sql_type = "VARCHAR") () =
  {
    value = (fun value -> Value.Enum value);
    decode = (function Value.Enum value | String value -> Some value | _ -> None);
    sql_type;
  }

let list typ =
  {
    value = (fun values -> Value.List (List.map typ.value values));
    decode =
      (function
      | Value.List values ->
          let rec loop acc = function
            | [] -> Some (List.rev acc)
            | value :: rest -> (
                match typ.decode value with
                | Some decoded -> loop (decoded :: acc) rest
                | None -> None)
          in
          loop [] values
      | _ -> None);
    sql_type = typ.sql_type ^ "[]";
  }

let value =
  {
    value = Fun.id;
    decode = (fun value -> Some value);
    sql_type = "ANY";
  }

let nullable typ =
  {
    value =
      (function
      | None -> Value.Null
      | Some value -> typ.value value);
    decode =
      (function
      | Value.Null -> Some None
      | value -> Option.map (fun value -> Some value) (typ.decode value));
    sql_type = typ.sql_type;
  }

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
    decode : Row.t -> 'a;
  }

  type 'a returning = {
    sql : string;
    params : param list;
    decode : Row.t -> 'a;
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
    invalid_arg "DuckDB identifiers must not be empty";
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

let coerce_column column =
  {
    table_name = column.table_name;
    column_name = column.column_name;
    typ = column.typ;
    quoted_column_name = column.quoted_column_name;
    qualified_column_name = column.qualified_column_name;
  }

let row_value index row =
  let rec loop current = function
    | [] -> None
    | (_, value) :: _ when current = index -> Some value
    | _ :: rest -> loop (current + 1) rest
  in
  loop 0 row

let decode_column operation typ index row =
  match row_value index row with
  | None ->
      failwith
        (operation ^ ": result row does not contain column "
        ^ string_of_int (index + 1))
  | Some value -> (
      match typ.decode value with
      | Some decoded -> decoded
      | None ->
          failwith
            (operation ^ ": could not decode value " ^ Value.to_string value))

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
    decode : Row.t -> 'a;
  }

  let one column =
    {
      columns = [ column_sql column ];
      decode = (fun row -> decode_column "projection" column.typ 0 row);
    }

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
      columns =
        [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5 ];
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
      columns =
        [
          column_sql c1;
          column_sql c2;
          column_sql c3;
          column_sql c4;
          column_sql c5;
          column_sql c6;
        ];
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
      columns =
        [
          column_sql c1;
          column_sql c2;
          column_sql c3;
          column_sql c4;
          column_sql c5;
          column_sql c6;
          column_sql c7;
        ];
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
      columns =
        [
          column_sql c1;
          column_sql c2;
          column_sql c3;
          column_sql c4;
          column_sql c5;
          column_sql c6;
          column_sql c7;
          column_sql c8;
        ];
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
    {
      ctes = [];
      source = Source.table table;
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
  let group_by column query = { query with group_by = query.group_by @ [ column_sql column ] }

  let group_by_many columns query =
    match columns with
    | [] -> invalid_arg "Eta_duckdb.Select.group_by_many: columns must not be empty"
    | columns -> { query with group_by = query.group_by @ List.map column_sql columns }

  let having expr query = { query with having = Some expr }

  let order_by ?(desc = false) column query =
    { query with order_by = query.order_by @ [ { sql = column_sql column; desc } ] }

  let limit count query =
    if count < 0 then invalid_arg "Eta_duckdb.Select.limit: count must be non-negative";
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
    cte_params @ query.source.Source.params @ where_params @ having_params

  let to_sql query =
    let buf = Buffer.create 192 in
    begin match query.ctes with
    | [] -> ()
    | ctes ->
        Buffer.add_string buf "WITH ";
        List.iteri
          (fun i (sql, _) ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf sql)
          ctes;
        Buffer.add_char buf ' '
    end;
    Buffer.add_string buf "SELECT ";
    if query.distinct then Buffer.add_string buf "DISTINCT ";
    List.iteri
      (fun i col ->
        if i > 0 then Buffer.add_string buf ", ";
        Buffer.add_string buf col)
      query.row.Projection.columns;
    Buffer.add_string buf " FROM ";
    Buffer.add_string buf query.source.Source.sql;
    begin match query.where_ with
    | None -> ()
    | Some expr ->
        Buffer.add_string buf " WHERE ";
        Buffer.add_string buf expr.Expr.sql
    end;
    begin match query.group_by with
    | [] -> ()
    | columns ->
        Buffer.add_string buf " GROUP BY ";
        List.iteri
          (fun i col ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf col)
          columns
    end;
    begin match query.having with
    | None -> ()
    | Some expr ->
        Buffer.add_string buf " HAVING ";
        Buffer.add_string buf expr.Expr.sql
    end;
    begin match query.order_by with
    | [] -> ()
    | orders ->
        Buffer.add_string buf " ORDER BY ";
        List.iteri
          (fun i { sql; desc } ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf sql;
            Buffer.add_string buf (if desc then " DESC" else " ASC"))
          orders
    end;
    begin match query.limit with
    | None -> ()
    | Some count ->
        Buffer.add_string buf " LIMIT ";
        Buffer.add_string buf (Int.to_string count)
    end;
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
    | [] -> Result.Error (Invalid_value "INSERT requires at least one value")
    | values ->
        let columns = List.map Assignment.column_sql values |> String.concat ", " in
        let placeholders = List.map (fun _ -> "?") values |> String.concat ", " in
        Ok (columns, placeholders)

  let conflict_target columns =
    match columns with
    | [] -> invalid_arg "Eta_duckdb.Insert.on_conflict: target columns must not be empty"
    | columns -> List.map column_ident columns

  let on_conflict_do_nothing columns query =
    { query with conflict = Some (Do_nothing (conflict_target columns)) }

  let on_conflict_update columns ~set query =
    match set with
    | [] -> invalid_arg "Eta_duckdb.Insert.on_conflict_update: set columns must not be empty"
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
    | Result.Error err -> raise (Error err)
    | Ok values -> to_sql_precomputed values query

  let params query = List.map Assignment.value query.values

  let compile query =
    match render_values query.values with
    | Result.Error err -> raise (Error err)
    | Ok values -> Compiled.{ sql = to_sql_precomputed values query; params = params query }

  let returning projection query =
    match render_values query.values with
    | Result.Error err -> raise (Error err)
    | Ok values ->
        let buf = Buffer.create 64 in
        Buffer.add_string buf (to_sql_precomputed values query);
        Buffer.add_string buf " RETURNING ";
        List.iteri
          (fun i col ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf col)
          projection.Projection.columns;
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
    match query.where_ with
    | None -> set_params
    | Some expr -> set_params @ expr.Expr.params

  let render_sets sets =
    match sets with
    | [] -> raise (Error (Invalid_value "UPDATE requires at least one set"))
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
    begin match query.where_ with
    | None -> ()
    | Some expr ->
        Buffer.add_string buf " WHERE ";
        Buffer.add_string buf expr.Expr.sql
    end;
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
    begin match query.where_ with
    | None -> ()
    | Some expr ->
        Buffer.add_string buf " WHERE ";
        Buffer.add_string buf expr.Expr.sql
    end;
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

  let column ?(primary_key = false) ?(not_null = false) ?(unique = false) ?default
      ?references (column : (_, _) column) =
    {
      name = column.column_name;
      sql_type = column.typ.sql_type;
      primary_key;
      not_null;
      unique;
      default;
      references;
    }

  let create_table ?(if_not_exists = false) (table : _ table) columns =
    if columns = [] then
      invalid_arg "Eta_duckdb.Eta_schema.create_table: columns must not be empty";
    Create_table { if_not_exists; table = table.table_name; columns }

  let drop_table ?(if_exists = false) (table : _ table) =
    Drop_table { if_exists; table = table.table_name }

  let create_index ?(unique = false) ?(if_not_exists = false) ~name (table : _ table)
      columns =
    if columns = [] then
      invalid_arg "Eta_duckdb.Eta_schema.create_index: columns must not be empty";
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
    begin match reference.column_name with
    | None -> ()
    | Some column ->
        Buffer.add_string buf " (";
        Buffer.add_string buf (quote_ident column);
        Buffer.add_char buf ')'
    end;
    begin match reference.on_delete with
    | None -> ()
    | Some action ->
        Buffer.add_string buf " ON DELETE ";
        Buffer.add_string buf action
    end;
    begin match reference.on_update with
    | None -> ()
    | Some action ->
        Buffer.add_string buf " ON UPDATE ";
        Buffer.add_string buf action
    end;
    Buffer.contents buf

  let column_sql def =
    let buf = Buffer.create 64 in
    Buffer.add_string buf (quote_ident def.name);
    Buffer.add_char buf ' ';
    Buffer.add_string buf def.sql_type;
    if def.primary_key then Buffer.add_string buf " PRIMARY KEY";
    if def.not_null then Buffer.add_string buf " NOT NULL";
    if def.unique then Buffer.add_string buf " UNIQUE";
    begin match def.default with
    | None -> ()
    | Some value ->
        Buffer.add_string buf " DEFAULT ";
        Buffer.add_string buf value
    end;
    begin match def.references with
    | None -> ()
    | Some reference -> Buffer.add_string buf (reference_sql reference)
    end;
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

module Database = struct
  type t = database

  let open_ config =
    wrap "open" @@ fun () ->
    let path = Option.value config.path ~default:"" in
    let db = { raw = raw_open path; closed = false } in
    (match config.threads with
     | None -> ()
     | Some threads ->
         if threads <= 0 then invalid_arg "Eta_duckdb.Database.open_: threads must be positive";
         let conn = { database = db; raw = raw_connect db.raw; closed = false } in
         Fun.protect
           ~finally:(fun () ->
             conn.closed <- true;
             raw_disconnect conn.raw)
           (fun () ->
             raw_exec_script conn.raw ("PRAGMA threads=" ^ string_of_int threads)));
    db

  let open_memory () = open_ { path = None; threads = None }

  let close db =
    if_database_open db @@ fun () ->
    db.closed <- true;
    wrap "close database" (fun () -> raw_close_database db.raw)
end

module Connection = struct
  type t = connection

  let connect database =
    if_database_open database @@ fun () ->
    wrap "connect" (fun () ->
        { database; raw = raw_connect database.raw; closed = false })

  let close (conn : connection) =
    if_connection_open conn @@ fun () ->
    conn.closed <- true;
    wrap "disconnect" (fun () -> raw_disconnect conn.raw)

  let interrupt (conn : connection) = if not conn.closed then raw_interrupt conn.raw

  let query (conn : connection) sql params =
    if_connection_open conn @@ fun () ->
    wrap "query" (fun () -> raw_query conn.raw sql params)

  let select conn (compiled : _ Compiled.select) =
    match query conn compiled.sql (params_to_values compiled.params) with
    | Result.Error _ as err -> err
    | Ok rows -> (
        match List.map compiled.decode rows with
        | values -> Ok values
        | exception Failure message ->
            Result.Error (Decode_error { operation = "select"; message }))

  let returning conn (compiled : _ Compiled.returning) =
    match query conn compiled.sql (params_to_values compiled.params) with
    | Result.Error _ as err -> err
    | Ok rows -> (
        match List.map compiled.decode rows with
        | values -> Ok values
        | exception Failure message ->
            Result.Error (Decode_error { operation = "returning"; message }))

  let execute (conn : connection) sql params =
    if_connection_open conn @@ fun () ->
    wrap "execute" (fun () -> raw_execute conn.raw sql params)

  let execute_compiled (conn : connection) (query : Compiled.change) =
    execute conn query.sql (params_to_values query.params)

  let exec_script (conn : connection) sql =
    if_connection_open conn @@ fun () ->
    wrap "exec script" (fun () -> raw_exec_script conn.raw sql)

  let run_schema conn (schema : Compiled.schema) = exec_script conn schema.sql

  let begin_transaction ?(mode = Deferred) conn =
    let sql =
      match mode with
      | Deferred -> "BEGIN TRANSACTION"
      | Immediate -> "BEGIN IMMEDIATE TRANSACTION"
    in
    exec_script conn sql

  let commit conn = exec_script conn "COMMIT"
  let rollback conn = exec_script conn "ROLLBACK"

  let transaction ?mode conn f =
    match begin_transaction ?mode conn with
    | Result.Error _ as err -> err
    | Ok () -> (
        match f conn with
        | Ok value -> (
            match commit conn with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (rollback conn);
            err
        | exception exn ->
            ignore (rollback conn);
            raise exn)
end

module Appender = struct
  type t = appender

  let create ?schema connection ~table =
    if_connection_open connection @@ fun () ->
    wrap "appender create" (fun () ->
        { connection; raw = raw_appender_create connection.raw schema table; closed = false })

  let append_row appender values =
    if_appender_open appender @@ fun () ->
    wrap "appender append row" (fun () -> raw_appender_append_row appender.raw values)

  let flush appender =
    if_appender_open appender @@ fun () ->
    wrap "appender flush" (fun () -> raw_appender_flush appender.raw)

  let close appender =
    if_appender_open appender @@ fun () ->
    appender.closed <- true;
    wrap "appender close" (fun () -> raw_appender_close appender.raw)

  let with_appender ?schema connection ~table f =
    match create ?schema connection ~table with
    | Result.Error _ as err -> err
    | Ok appender -> (
        match f appender with
        | Ok value -> (
            match close appender with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (close appender);
            err
        | exception exn ->
            ignore (close appender);
            raise exn)
end

module Bulk_row = struct
  type 'table t = Value.t list

  let empty = []
  let value column value row = row @ [ column.typ.value value ]
  let null _column row = row @ [ Value.Null ]
end

module Bulk = struct
  type 'table t = Appender.t

  let create ?schema connection table =
    Appender.create ?schema connection ~table:(Table.name table)

  let append_row appender row = Appender.append_row appender row
  let flush = Appender.flush
  let close = Appender.close

  let with_appender ?schema connection table f =
    match create ?schema connection table with
    | Result.Error _ as err -> err
    | Ok appender -> (
        match f appender with
        | Ok value -> (
            match close appender with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (close appender);
            err
        | exception exn ->
            ignore (close appender);
            raise exn)
end

module Pool = struct
  type raw_error = [ `Duckdb of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]

  type t = {
    database : database;
    pool : (connection, raw_error) Eta.Pool.t;
  }

  type nonrec error =
    | Duckdb of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let to_public_error = function
    | `Duckdb err -> Duckdb err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let to_raw_error = function
    | Duckdb err -> `Duckdb err
    | Pool_shutdown -> `Pool_shutdown
    | Pool_shutdown_timeout -> `Pool_shutdown_timeout
    | Timeout -> `Timeout

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Duckdb err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
    let query =
      Eta.Effect.blocking ?pool:blocking_pool ~name ~on_cancel:(fun () ->
          Connection.interrupt conn)
        f
      |> Eta.Effect.map (function
           | Ok value -> `Query_ok value
           | Result.Error err -> `Query_error err)
    in
    let timeout =
      Eta.Effect.delay timeout
        (Eta.Effect.sync (fun () -> Connection.interrupt conn)
         |> Eta.Effect.map (fun () -> `Timed_out))
    in
    Eta.Effect.race [ query; timeout ]
    |> Eta.Effect.bind (function
         | `Query_ok value -> Eta.Effect.pure value
         | `Query_error err -> Eta.Effect.fail (`Duckdb err)
         | `Timed_out -> Eta.Effect.fail `Timeout)

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime config =
    blocking_result ?blocking_pool ~name:"duckdb.open" (fun () ->
        Database.open_ config)
    |> Eta.Effect.bind (fun database ->
           Eta.Pool.create ?name ~kind:"duckdb" ~max_size ?max_idle
             ?idle_lifetime ?max_lifetime
             ~acquire:
               (blocking_result ?blocking_pool ~name:"duckdb.connect" (fun () ->
                    Connection.connect database))
             ~release:(fun conn ->
               Eta.Effect.blocking ?pool:blocking_pool ~name:"duckdb.disconnect"
                 (fun () -> ignore (Connection.close conn)))
             ~health_check:(fun conn ->
               blocking_result ?blocking_pool ~name:"duckdb.ping" (fun () ->
                   match Connection.query conn "SELECT 1" [] with
                   | Ok _ -> Ok ()
                   | Result.Error _ as err -> err))
             ()
           |> Eta.Effect.map (fun pool -> { database; pool }))
    |> public

  let with_connection t f =
    Eta.Pool.with_resource t.pool (fun conn ->
        f conn |> Eta.Effect.map_error to_raw_error)
    |> public

  let query ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.query"
          (fun () -> Connection.query conn sql params)
        |> public)

  let select ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.select"
          (fun () -> Connection.select conn query)
        |> public)

  let returning ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.returning"
          (fun () -> Connection.returning conn query)
        |> public)

  let execute ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.execute"
          (fun () -> Connection.execute conn sql params)
        |> public)

  let execute_compiled ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn
          ~name:"duckdb.execute_compiled" (fun () ->
            Connection.execute_compiled conn query)
        |> public)

  let run_schema ?blocking_pool ~timeout t schema =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.schema"
          (fun () -> Connection.run_schema conn schema)
        |> public)

  let shutdown ?deadline t =
    Eta.Pool.shutdown ?deadline t.pool
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.blocking ~name:"duckdb.close_database" (fun () ->
               ignore (Database.close t.database)))
    |> public

  let stats t = Eta.Pool.stats t.pool
end
