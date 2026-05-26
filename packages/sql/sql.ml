module Eta_runtime = Eta

type error =
  | Sqlite of Sqlite.error
  | Pool_error of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }

let pp_error ppf = function
  | Sqlite err -> Sqlite.pp_error ppf err
  | Pool_error message -> Format.fprintf ppf "pool error: %s" message
  | Invalid_query message -> Format.fprintf ppf "invalid query: %s" message
  | Decode_error { operation; message } ->
      Format.fprintf ppf "%s: %s" operation message

let show_error err = Format.asprintf "%a" pp_error err

type sql_error = error

let raise_error err = raise (Failure (show_error err))

module Value = struct
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes

  let null = Null
  let int value = Int value
  let int64 value = Int64 value
  let float value = Float value
  let string value = String value
  let bool value = Bool value
  let bytes value = Bytes value

  let int64_to_int_opt value =
    let min = Int64.of_int min_int in
    let max = Int64.of_int max_int in
    if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
      Some (Int64.to_int value)
    else
      None

  let to_int = function
    | Int value -> Some value
    | Int64 value -> int64_to_int_opt value
    | _ -> None

  let to_int64 = function
    | Int value -> Some (Int64.of_int value)
    | Int64 value -> Some value
    | _ -> None

  let to_float = function
    | Float value -> Some value
    | _ -> None

  let to_string_value = function
    | String value -> Some value
    | _ -> None

  let to_bool = function
    | Bool value -> Some value
    | Int 0 -> Some false
    | Int 1 -> Some true
    | Int64 0L -> Some false
    | Int64 1L -> Some true
    | _ -> None

  let to_bytes = function
    | Bytes value -> Some value
    | _ -> None

  let is_null = function
    | Null -> true
    | _ -> false

  let to_string = function
    | Null -> "NULL"
    | Int value -> string_of_int value
    | Int64 value -> Int64.to_string value
    | Float value -> string_of_float value
    | String value -> value
    | Bool true -> "true"
    | Bool false -> "false"
    | Bytes value -> Bytes.to_string value

  let compare = Stdlib.compare
  let equal left right = compare left right = 0
end

module Row = struct
  type t = (string * Value.t) list

  let get field row =
    let rec loop = function
      | [] -> None
      | (name, value) :: rest ->
          if String.equal name field then Some value else loop rest
    in
    loop row

  let fields row = List.map fst row
  let int field row = Option.bind (get field row) Value.to_int
  let int64 field row = Option.bind (get field row) Value.to_int64
  let string field row = Option.bind (get field row) Value.to_string_value
  let bool field row = Option.bind (get field row) Value.to_bool
  let float field row = Option.bind (get field row) Value.to_float
  let bytes field row = Option.bind (get field row) Value.to_bytes

  let to_string row =
    row
    |> List.map (fun (field, value) -> field ^ "=" ^ Value.to_string value)
    |> String.concat ", "

  let equal left right =
    List.length left = List.length right
    && List.for_all2
         (fun (left_field, left_value) (right_field, right_value) ->
           String.equal left_field right_field && Value.equal left_value right_value)
         left right
end

type 'a typ = {
  bind : Sqlite.stmt -> int -> 'a -> Sqlite.rc;
  read : Sqlite.stmt -> int -> 'a;
  value : 'a -> Value.t;
  sql_type : string;
}

let int =
  {
    bind = Sqlite.bind_int;
    read = Sqlite.column_int;
    value = (fun value -> Value.Int value);
    sql_type = "INTEGER";
  }

let int64 =
  {
    bind = Sqlite.bind_int64;
    read = Sqlite.column_int64;
    value = (fun value -> Value.Int64 value);
    sql_type = "INTEGER";
  }

let text =
  {
    bind = Sqlite.bind_text;
    read = Sqlite.column_text;
    value = (fun value -> Value.String value);
    sql_type = "TEXT";
  }

let float =
  {
    bind = Sqlite.bind_float;
    read = Sqlite.column_float;
    value = (fun value -> Value.Float value);
    sql_type = "REAL";
  }

let blob =
  {
    bind = Sqlite.bind_blob;
    read = Sqlite.column_blob;
    value = (fun value -> Value.Bytes value);
    sql_type = "BLOB";
  }

let bool =
  {
    bind = (fun stmt index value -> Sqlite.bind_int stmt index (if value then 1 else 0));
    read = (fun stmt index -> Sqlite.column_int stmt index <> 0);
    value = (fun value -> Value.Bool value);
    sql_type = "INTEGER";
  }

let nullable typ =
  {
    bind =
      (fun stmt index -> function
        | None -> Sqlite.bind_null stmt index
        | Some value -> typ.bind stmt index value);
    read =
      (fun stmt index ->
        if Sqlite.column_is_null stmt index then
          None
        else
          Some (typ.read stmt index));
    value =
      (function
      | None -> Value.Null
      | Some value -> typ.value value);
    sql_type = typ.sql_type;
  }

type 'table table = { table_name : string }

type ('table, 'a) column = {
  table_name : string;
  column_name : string;
  typ : 'a typ;
}

type param = Param : 'a typ * 'a -> param

module Compiled = struct
  type 'a select = {
    sql : string;
    params : param list;
    decode : Sqlite.stmt -> 'a;
  }

  type 'a returning = {
    sql : string;
    params : param list;
    decode : Sqlite.stmt -> 'a;
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
  if name = "" then
    invalid_arg "SQL identifiers must not be empty";
  let buffer = Buffer.create (String.length name + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      if Char.equal c '"' then
        Buffer.add_string buffer "\"\""
      else
        Buffer.add_char buffer c)
    name;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let table_sql (table : _ table) = quote_ident table.table_name
let column_ident (column : (_, _) column) = quote_ident column.column_name

let column_sql (column : (_, _) column) =
  quote_ident column.table_name ^ "." ^ quote_ident column.column_name

let coerce_column column =
  { table_name = column.table_name; column_name = column.column_name; typ = column.typ }

let sqlite_result = function
  | Ok value -> Ok value
  | Result.Error err -> Result.Error (Sqlite err)

let check_sqlite db ~operation rc =
  match Sqlite.check db ~operation rc with
  | Ok () -> Ok ()
  | Result.Error err -> Result.Error (Sqlite err)

let bind_params db stmt params =
  let rec loop index = function
    | [] -> Ok ()
    | Param (typ, value) :: rest -> (
        match check_sqlite db ~operation:"bind" (typ.bind stmt index value) with
        | Ok () -> loop (index + 1) rest
        | Result.Error _ as err -> err)
  in
  loop 1 params

let finalize_result db stmt result =
  let finalize_rc = Sqlite.finalize stmt in
  match result with
  | Result.Error _ -> result
  | Ok _ -> (
      match check_sqlite db ~operation:"finalize" finalize_rc with
      | Ok () -> result
      | Result.Error _ as err -> err)

let with_statement db sql params f =
  match sqlite_result (Sqlite.prepare_result db sql) with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match bind_params db stmt params with
      | Result.Error err ->
          ignore (Sqlite.finalize stmt);
          Result.Error err
      | Ok () ->
          let result =
            match f stmt with
            | value -> value
            | exception exn ->
                Result.Error
                  (Decode_error
                     { operation = "execute"; message = Printexc.to_string exn })
          in
          finalize_result db stmt result)

let bind_value stmt index = function
  | Value.Null -> Sqlite.bind_null stmt index
  | Int value -> Sqlite.bind_int stmt index value
  | Int64 value -> Sqlite.bind_int64 stmt index value
  | Float value -> Sqlite.bind_float stmt index value
  | String value -> Sqlite.bind_text stmt index value
  | Bool value -> Sqlite.bind_int stmt index (if value then 1 else 0)
  | Bytes value -> Sqlite.bind_blob stmt index value

let bind_dynamic_values db stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest -> (
        match check_sqlite db ~operation:"bind" (bind_value stmt index value) with
        | Ok () -> loop (index + 1) rest
        | Result.Error _ as err -> err)
  in
  loop 1 values

let with_dynamic_statement db sql params f =
  match sqlite_result (Sqlite.prepare_result db sql) with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match bind_dynamic_values db stmt params with
      | Result.Error err ->
          ignore (Sqlite.finalize stmt);
          Result.Error err
      | Ok () ->
          let result =
            match f stmt with
            | value -> value
            | exception exn ->
                Result.Error
                  (Decode_error
                     { operation = "execute"; message = Printexc.to_string exn })
          in
          finalize_result db stmt result)

let read_dynamic_value stmt index =
  match Sqlite.column_type_code stmt index with
  | 1 ->
      let value = Sqlite.column_int64 stmt index in
      (match Value.int64_to_int_opt value with
       | Some value -> Value.Int value
       | None -> Int64 value)
  | 2 -> Float (Sqlite.column_float stmt index)
  | 3 -> String (Sqlite.column_text stmt index)
  | 4 -> Bytes (Sqlite.column_blob stmt index)
  | 5 -> Null
  | _ -> Null

let materialize_row stmt =
  let count = Sqlite.column_count stmt in
  let rec loop index acc =
    if index < 0 then
      acc
    else
      loop (index - 1)
        ((Sqlite.column_name stmt index, read_dynamic_value stmt index) :: acc)
  in
  loop (count - 1) []

module Table = struct
  type 'table t = 'table table

  module Make (Name : sig
    val name : string
  end) =
  struct
    type table

    let table = { table_name = Name.name }
    let column name typ = { table_name = Name.name; column_name = name; typ }
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
  let param column value = { sql = "?"; params = [ Param (column.typ, value) ] }

  let binary op column value =
    let rhs = param column value in
    { sql = column_sql column ^ " " ^ op ^ " " ^ rhs.sql; params = rhs.params }

  let eq column value = binary "=" column value
  let ne column value = binary "<>" column value
  let gt column value = binary ">" column value
  let ge column value = binary ">=" column value
  let lt column value = binary "<" column value
  let le column value = binary "<=" column value
  let like column value = binary "LIKE" column value

  let eq_col left right =
    { sql = column_sql left ^ " = " ^ column_sql right; params = [] }

  let is_null column = { sql = column_sql column ^ " IS NULL"; params = [] }
  let is_not_null column = { sql = column_sql column ^ " IS NOT NULL"; params = [] }
  let count_eq value = { sql = "COUNT(*) = ?"; params = [ Param (int, value) ] }
  let count_gt value = { sql = "COUNT(*) > ?"; params = [ Param (int, value) ] }
  let count_ge value = { sql = "COUNT(*) >= ?"; params = [ Param (int, value) ] }

  let in_select column (query : _ Compiled.select) =
    {
      sql = column_sql column ^ " IN (" ^ query.sql ^ ")";
      params = query.params;
    }

  let exists (query : _ Compiled.select) =
    { sql = "EXISTS (" ^ query.sql ^ ")"; params = query.params }

  let join op left right =
    {
      sql = "(" ^ left.sql ^ " " ^ op ^ " " ^ right.sql ^ ")";
      params = left.params @ right.params;
    }

  let and_ left right = join "AND" left right
  let or_ left right = join "OR" left right
  let not_ expr = { sql = "NOT (" ^ expr.sql ^ ")"; params = expr.params }
end

module Projection = struct
  type ('scope, 'a) t = {
    columns : string list;
    decode : Sqlite.stmt -> 'a;
  }

  let one column =
    { columns = [ column_sql column ]; decode = (fun stmt -> column.typ.read stmt 0) }

  let t2 c1 c2 =
    {
      columns = [ column_sql c1; column_sql c2 ];
      decode = (fun stmt -> (c1.typ.read stmt 0, c2.typ.read stmt 1));
    }

  let t3 c1 c2 c3 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3 ];
      decode =
        (fun stmt ->
          (c1.typ.read stmt 0, c2.typ.read stmt 1, c3.typ.read stmt 2));
    }

  let count ?as_ () =
    let sql =
      match as_ with
      | None -> "COUNT(*)"
      | Some alias -> "COUNT(*) AS " ^ quote_ident alias
    in
    { columns = [ sql ]; decode = (fun stmt -> Sqlite.column_int stmt 0) }

  let sum_int ?as_ column =
    let sql = "SUM(" ^ column_sql column ^ ")" in
    let sql =
      match as_ with
      | None -> sql
      | Some alias -> sql ^ " AS " ^ quote_ident alias
    in
    { columns = [ sql ]; decode = (fun stmt -> Sqlite.column_int stmt 0) }

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
    { columns = [ sql ]; decode = (fun stmt -> Sqlite.column_int stmt 0) }

  let t4 c1 c2 c3 c4 =
    {
      columns = [ column_sql c1; column_sql c2; column_sql c3; column_sql c4 ];
      decode =
        (fun stmt ->
          ( c1.typ.read stmt 0,
            c2.typ.read stmt 1,
            c3.typ.read stmt 2,
            c4.typ.read stmt 3 ));
    }

  let t5 c1 c2 c3 c4 c5 =
    {
      columns =
        [ column_sql c1; column_sql c2; column_sql c3; column_sql c4; column_sql c5 ];
      decode =
        (fun stmt ->
          ( c1.typ.read stmt 0,
            c2.typ.read stmt 1,
            c3.typ.read stmt 2,
            c4.typ.read stmt 3,
            c5.typ.read stmt 4 ));
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
        (fun stmt ->
          ( c1.typ.read stmt 0,
            c2.typ.read stmt 1,
            c3.typ.read stmt 2,
            c4.typ.read stmt 3,
            c5.typ.read stmt 4,
            c6.typ.read stmt 5 ));
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
        (fun stmt ->
          ( c1.typ.read stmt 0,
            c2.typ.read stmt 1,
            c3.typ.read stmt 2,
            c4.typ.read stmt 3,
            c5.typ.read stmt 4,
            c6.typ.read stmt 5,
            c7.typ.read stmt 6 ));
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
        (fun stmt ->
          ( c1.typ.read stmt 0,
            c2.typ.read stmt 1,
            c3.typ.read stmt 2,
            c4.typ.read stmt 3,
            c5.typ.read stmt 4,
            c6.typ.read stmt 5,
            c7.typ.read stmt 6,
            c8.typ.read stmt 7 ));
    }

  let map f row = { row with decode = (fun stmt -> f (row.decode stmt)) }
end

module Join = struct
  let left column = coerce_column column
  let right column = coerce_column column

  let on_eq left right =
    Expr.eq_col (coerce_column left) (coerce_column right)
end

module Source = struct
  type 'scope t = {
    sql : string;
    params : param list;
  }

  let table table = { sql = table_sql table; params = [] }

  let join kind left right ~on =
    {
      sql =
        table_sql left ^ " " ^ kind ^ " JOIN " ^ table_sql right ^ " ON "
        ^ on.Expr.sql;
      params = on.Expr.params;
    }

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
    { query with ctes = query.ctes @ [ (quote_ident name ^ " AS (" ^ cte.sql ^ ")", cte.params) ] }

  let distinct query = { query with distinct = true }
  let where expr query = { query with where_ = Some expr }
  let group_by column query =
    { query with group_by = query.group_by @ [ column_sql column ] }

  let group_by_many columns query =
    match columns with
    | [] -> invalid_arg "Sql.Select.group_by_many: columns must not be empty"
    | columns ->
        { query with group_by = query.group_by @ List.map column_sql columns }

  let having expr query = { query with having = Some expr }

  let order_by ?(desc = false) column query =
    { query with order_by = query.order_by @ [ { sql = column_sql column; desc } ] }

  let limit count query =
    if count < 0 then
      invalid_arg "Sql.Select.limit: count must be non-negative";
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
    let with_ =
      match query.ctes with
      | [] -> ""
      | ctes ->
          "WITH " ^ String.concat ", " (List.map fst ctes) ^ " "
    in
    let select =
      "SELECT "
      ^ (if query.distinct then "DISTINCT " else "")
      ^ String.concat ", " query.row.Projection.columns
    in
    let from = " FROM " ^ query.source.Source.sql in
    let where =
      match query.where_ with
      | None -> ""
      | Some expr -> " WHERE " ^ expr.Expr.sql
    in
    let group =
      match query.group_by with
      | [] -> ""
      | columns -> " GROUP BY " ^ String.concat ", " columns
    in
    let having =
      match query.having with
      | None -> ""
      | Some expr -> " HAVING " ^ expr.Expr.sql
    in
    let order =
      match query.order_by with
      | [] -> ""
      | orders ->
          let render { sql; desc } = sql ^ if desc then " DESC" else " ASC" in
          " ORDER BY " ^ String.concat ", " (List.map render orders)
    in
    let limit =
      match query.limit with
      | None -> ""
      | Some count -> " LIMIT " ^ string_of_int count
    in
    with_ ^ select ^ from ^ where ^ group ^ having ^ order ^ limit

  let compile query : _ Compiled.select =
    Compiled.{ sql = to_sql query; params = params query; decode = query.row.decode }

  let all_result db query =
    let compiled = compile query in
    with_statement db compiled.sql compiled.params @@ fun stmt ->
    let rec loop acc =
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (compiled.decode stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then
        Ok (List.rev acc)
      else
        match Sqlite.check db ~operation:"select" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error (Sqlite err)
    in
    loop []

  let all db query =
    match all_result db query with
    | Ok rows -> rows
    | Result.Error err -> raise_error err

  let find_opt_result db query =
    match all_result db query with
    | Result.Error _ as err -> err
    | Ok [] -> Ok None
    | Ok [ row ] -> Ok (Some row)
    | Ok _ ->
        Result.Error
          (Decode_error
             { operation = "find_opt"; message = "query returned more than one row" })

  let find_opt db query =
    match find_opt_result db query with
    | Ok row -> row
    | Result.Error err -> raise_error err
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
    | [] -> Result.Error (Invalid_query "INSERT requires at least one value")
    | values ->
        let columns = List.map Assignment.column_sql values |> String.concat ", " in
        let placeholders = List.map (fun _ -> "?") values |> String.concat ", " in
        Ok (columns, placeholders)

  let conflict_target columns =
    match columns with
    | [] -> invalid_arg "Sql.Insert.on_conflict: target columns must not be empty"
    | columns -> List.map column_ident columns

  let on_conflict_do_nothing columns query =
    { query with conflict = Some (Do_nothing (conflict_target columns)) }

  let on_conflict_update columns ~set query =
    match set with
    | [] -> invalid_arg "Sql.Insert.on_conflict_update: set columns must not be empty"
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
        " ON CONFLICT (" ^ String.concat ", " target ^ ") DO NOTHING"
    | Some (Do_update_excluded (target, set)) ->
        let assignments =
          set
          |> List.map (fun column -> column ^ " = excluded." ^ column)
          |> String.concat ", "
        in
        " ON CONFLICT (" ^ String.concat ", " target ^ ") DO UPDATE SET "
        ^ assignments

  let to_sql query =
    match render_values query.values with
    | Result.Error err -> raise_error err
    | Ok (columns, placeholders) ->
        "INSERT INTO " ^ table_sql query.table ^ " (" ^ columns ^ ") VALUES ("
        ^ placeholders ^ ")"
        ^ conflict_sql query.conflict

  let params query = List.map Assignment.value query.values

  let compile query =
    match render_values query.values with
    | Result.Error err -> raise_error err
    | Ok _ -> Compiled.{ sql = to_sql query; params = params query }

  let returning projection query =
    match render_values query.values with
    | Result.Error err -> raise_error err
    | Ok _ ->
        Compiled.
          {
            sql =
              to_sql query ^ " RETURNING "
              ^ String.concat ", " projection.Projection.columns;
            params = params query;
            decode = projection.decode;
          }

  let run_result db query =
    match render_values query.values with
    | Result.Error _ as err -> err
    | Ok _ ->
        with_statement db (to_sql query) (params query) @@ fun stmt ->
        let rc = Sqlite.step stmt in
        if Sqlite.rc_equal rc Sqlite.done_ then
          Ok (Sqlite.changes db)
        else
          match Sqlite.check db ~operation:"insert" rc with
          | Ok () -> assert false
          | Result.Error err -> Result.Error (Sqlite err)

  let run db query =
    match run_result db query with
    | Ok count -> count
    | Result.Error err -> raise_error err
end

module Update = struct
  type 'table t = {
    table : 'table table;
    sets : 'table Assignment.t list;
    where_ : 'table Expr.t option;
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

  let to_sql query =
    match query.sets with
    | [] -> raise_error (Invalid_query "UPDATE requires at least one set")
    | sets ->
        let set_sql = List.map Assignment.set_sql sets |> String.concat ", " in
        let where =
          match query.where_ with
          | None -> ""
          | Some expr -> " WHERE " ^ expr.Expr.sql
        in
        "UPDATE " ^ table_sql query.table ^ " SET " ^ set_sql ^ where

  let compile query =
    match query.sets with
    | [] -> raise_error (Invalid_query "UPDATE requires at least one set")
    | _ -> Compiled.{ sql = to_sql query; params = params query }

  let returning projection query =
    match query.sets with
    | [] -> raise_error (Invalid_query "UPDATE requires at least one set")
    | _ ->
        Compiled.
          {
            sql =
              to_sql query ^ " RETURNING "
              ^ String.concat ", " projection.Projection.columns;
            params = params query;
            decode = projection.decode;
          }

  let run_result db query =
    match query.sets with
    | [] -> Result.Error (Invalid_query "UPDATE requires at least one set")
    | _ ->
        with_statement db (to_sql query) (params query) @@ fun stmt ->
        let rc = Sqlite.step stmt in
        if Sqlite.rc_equal rc Sqlite.done_ then
          Ok (Sqlite.changes db)
        else
          match Sqlite.check db ~operation:"update" rc with
          | Ok () -> assert false
          | Result.Error err -> Result.Error (Sqlite err)

  let run db query =
    match run_result db query with
    | Ok count -> count
    | Result.Error err -> raise_error err
end

module Delete = struct
  type 'table t = {
    table : 'table table;
    where_ : 'table Expr.t option;
  }

  let from table = { table; where_ = None }
  let where expr query = { query with where_ = Some expr }

  let params query =
    match query.where_ with
    | None -> []
    | Some expr -> expr.Expr.params

  let to_sql query =
    let where =
      match query.where_ with
      | None -> ""
      | Some expr -> " WHERE " ^ expr.Expr.sql
    in
    "DELETE FROM " ^ table_sql query.table ^ where

  let compile query = Compiled.{ sql = to_sql query; params = params query }

  let returning projection query =
    Compiled.
      {
        sql =
          to_sql query ^ " RETURNING "
          ^ String.concat ", " projection.Projection.columns;
        params = params query;
        decode = projection.decode;
      }

  let run_result db query =
    with_statement db (to_sql query) (params query) @@ fun stmt ->
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (Sqlite.changes db)
    else
      match Sqlite.check db ~operation:"delete" rc with
      | Ok () -> assert false
      | Result.Error err -> Result.Error (Sqlite err)

  let run db query =
    match run_result db query with
    | Ok count -> count
    | Result.Error err -> raise_error err
end

module Schema = struct
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
    {
      table_name = column.table_name;
      column_name = Some column.column_name;
      on_delete;
      on_update;
    }

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
      invalid_arg "Sql.Schema.create_table: columns must not be empty";
    Create_table { if_not_exists; table = table.table_name; columns }

  let drop_table ?(if_exists = false) (table : _ table) =
    Drop_table { if_exists; table = table.table_name }

  let create_index ?(unique = false) ?(if_not_exists = false) ~name
      (table : _ table) columns =
    if columns = [] then
      invalid_arg "Sql.Schema.create_index: columns must not be empty";
    Create_index
      {
        unique;
        if_not_exists;
        name;
        table = table.table_name;
        columns = List.map (fun (column : (_, _) column) -> column.column_name) columns;
      }

  let reference_sql reference =
    let column =
      match reference.column_name with
      | None -> ""
      | Some column -> " (" ^ quote_ident column ^ ")"
    in
    let on_delete =
      match reference.on_delete with
      | None -> ""
      | Some action -> " ON DELETE " ^ action
    in
    let on_update =
      match reference.on_update with
      | None -> ""
      | Some action -> " ON UPDATE " ^ action
    in
    " REFERENCES " ^ quote_ident reference.table_name ^ column ^ on_delete ^ on_update

  let column_sql def =
    let constraints =
      [
        (if def.primary_key then Some "PRIMARY KEY" else None);
        (if def.not_null then Some "NOT NULL" else None);
        (if def.unique then Some "UNIQUE" else None);
        Option.map (fun value -> "DEFAULT " ^ value) def.default;
        Option.map reference_sql def.references;
      ]
      |> List.filter_map Fun.id
    in
    String.concat " " (quote_ident def.name :: def.sql_type :: constraints)

  let to_sql = function
    | Create_table { if_not_exists; table; columns } ->
        "CREATE TABLE "
        ^ (if if_not_exists then "IF NOT EXISTS " else "")
        ^ quote_ident table ^ " ("
        ^ String.concat ", " (List.map column_sql columns)
        ^ ")"
    | Drop_table { if_exists; table } ->
        "DROP TABLE " ^ (if if_exists then "IF EXISTS " else "") ^ quote_ident table
    | Create_index { unique; if_not_exists; name; table; columns } ->
        "CREATE " ^ (if unique then "UNIQUE " else "") ^ "INDEX "
        ^ (if if_not_exists then "IF NOT EXISTS " else "")
        ^ quote_ident name ^ " ON " ^ quote_ident table ^ " ("
        ^ String.concat ", " (List.map quote_ident columns)
        ^ ")"

  let compile schema = Compiled.{ sql = to_sql schema }

  let run_result db schema =
    match Sqlite.exec_result db (to_sql schema) with
    | Ok () -> Ok ()
    | Result.Error err -> Result.Error (Sqlite err)

  let run db schema =
    match run_result db schema with
    | Ok () -> ()
    | Result.Error err -> raise_error err
end

module Connection = struct
  type t = {
    db : Sqlite.db;
    id : string;
    created_at : float;
    mutable last_used : float;
    mutable closed : bool;
    mutable in_transaction : bool;
    mutable pool_lease : int;
  }

  let next_id = Atomic.make 0

  let fresh_id () =
    let value = Atomic.fetch_and_add next_id 1 + 1 in
    "eta-sql-" ^ string_of_int value

  let now = Unix.gettimeofday

  let create config =
    match Sqlite.open_with_config config with
    | db ->
        let created_at = now () in
        Ok
          {
            db;
            id = fresh_id ();
            created_at;
            last_used = created_at;
            closed = false;
            in_transaction = false;
            pool_lease = 0;
          }
    | exception Sqlite.Error err -> Result.Error (Sqlite err)
    | exception exn ->
        Result.Error
          (Invalid_query ("open connection failed: " ^ Printexc.to_string exn))

  let sqlite t = t.db
  let touch t = t.last_used <- now ()
  let closed_error = Invalid_query "connection is closed"
  let already_in_transaction = Invalid_query "transaction already in progress"
  let no_transaction = Invalid_query "no transaction in progress"

  let if_open t f =
    if t.closed then
      Result.Error closed_error
    else
      f ()

  let query t sql params =
    if_open t @@ fun () ->
    touch t;
    with_dynamic_statement t.db sql params @@ fun stmt ->
    let rec loop acc =
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (materialize_row stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then
        Ok (List.rev acc)
      else
        match Sqlite.check t.db ~operation:"query" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error (Sqlite err)
    in
    loop []

  let select t (query : _ Compiled.select) =
    if_open t @@ fun () ->
    touch t;
    with_statement t.db query.sql query.params @@ fun stmt ->
    let rec loop acc =
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (query.decode stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then
        Ok (List.rev acc)
      else
        match Sqlite.check t.db ~operation:"select" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error (Sqlite err)
    in
    loop []

  let returning t (query : _ Compiled.returning) =
    if_open t @@ fun () ->
    touch t;
    with_statement t.db query.sql query.params @@ fun stmt ->
    let rec loop acc =
      let rc = Sqlite.step stmt in
      if Sqlite.rc_equal rc Sqlite.row then
        loop (query.decode stmt :: acc)
      else if Sqlite.rc_equal rc Sqlite.done_ then
        Ok (List.rev acc)
      else
        match Sqlite.check t.db ~operation:"returning" rc with
        | Ok () -> assert false
        | Result.Error err -> Result.Error (Sqlite err)
    in
    loop []

  let execute t sql params =
    if_open t @@ fun () ->
    touch t;
    with_dynamic_statement t.db sql params @@ fun stmt ->
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (Sqlite.changes t.db)
    else
          match Sqlite.check t.db ~operation:"execute" rc with
          | Ok () -> assert false
          | Result.Error err -> Result.Error (Sqlite err)

  let execute_compiled t (query : Compiled.change) =
    if_open t @@ fun () ->
    touch t;
    with_statement t.db query.sql query.params @@ fun stmt ->
    let rc = Sqlite.step stmt in
    if Sqlite.rc_equal rc Sqlite.done_ then
      Ok (Sqlite.changes t.db)
    else
      match Sqlite.check t.db ~operation:"execute" rc with
      | Ok () -> assert false
      | Result.Error err -> Result.Error (Sqlite err)

  let execute_script t sql =
    if_open t @@ fun () ->
    touch t;
    match Sqlite.exec_script_result t.db sql with
    | Ok () -> Ok ()
    | Result.Error err -> Result.Error (Sqlite err)

  let run_schema t (schema : Compiled.schema) = execute_script t schema.sql

  let prepare_migration t sql = if_open t @@ fun () -> Ok [ sql ]

  let ping t =
    (not t.closed)
    &&
    match query t "SELECT 1" [] with
    | Ok [ row ] -> Row.int "1" row = Some 1
    | _ -> false

  let close t =
    if not t.closed then (
      t.closed <- true;
      t.in_transaction <- false;
      ignore (Sqlite.close t.db))

  let begin_transaction t =
    if_open t @@ fun () ->
    if t.in_transaction then
      Result.Error already_in_transaction
    else
      match Sqlite.begin_transaction_result t.db with
      | Ok () ->
          t.in_transaction <- true;
          Ok ()
      | Result.Error err -> Result.Error (Sqlite err)

  let commit t =
    if_open t @@ fun () ->
    if not t.in_transaction then
      Result.Error no_transaction
    else
      match Sqlite.commit_result t.db with
      | Ok () ->
          t.in_transaction <- false;
          Ok ()
      | Result.Error err -> Result.Error (Sqlite err)

  let rollback t =
    if_open t @@ fun () ->
    if not t.in_transaction then
      Result.Error no_transaction
    else
      match Sqlite.rollback_result t.db with
      | Ok () ->
          t.in_transaction <- false;
          Ok ()
      | Result.Error err -> Result.Error (Sqlite err)

  let with_transaction t f =
    match begin_transaction t with
    | Result.Error _ as err -> err
    | Ok () -> (
        match f t with
        | Ok value -> (
            match commit t with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (rollback t);
            err
        | exception exn ->
            ignore (rollback t);
            raise exn)

  let id t = t.id
  let created_at t = t.created_at
  let last_used t = t.last_used
  let pool_lease t = t.pool_lease
  let set_pool_lease t lease = t.pool_lease <- lease
end

module Transaction = struct
  type t = Connection.t

  let begin_transaction conn =
    match Connection.begin_transaction conn with
    | Ok () -> Ok conn
    | Result.Error _ as err -> err

  let commit = Connection.commit
  let rollback = Connection.rollback
  let with_transaction = Connection.with_transaction
end

module Pool = struct
  type clock = Clock : _ Eio.Time.clock -> clock

  type config = {
    sqlite : Sqlite.config;
    min_connections : int;
    max_connections : int;
    acquire_timeout_ms : int option;
    idle_timeout_ms : int option;
    max_lifetime_ms : int option;
  }

  type idle_entry = {
    conn : Connection.t;
    mutable idle_since_ms : int;
  }

  type lease = {
    leased_conn : Connection.t;
    lease_id : int;
  }

  type t = {
    config : config;
    clock : clock option;
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
    mutable idle : idle_entry list;
    mutable in_use : lease list;
    mutable total : int;
    mutable waiting : int;
    mutable next_lease : int;
    mutable shutdown : bool;
  }

  type stat =
    | Total_connections of int
    | Available_connections of int
    | In_use_connections of int
    | Waiting_requests of int

  let config ?(min_connections = 0) ?(max_connections = 10) ?acquire_timeout_ms
      ?idle_timeout_ms ?max_lifetime_ms sqlite =
    { sqlite; min_connections; max_connections; acquire_timeout_ms; idle_timeout_ms; max_lifetime_ms }

  let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

  let with_lock t f =
    Eio.Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

  let validate_config config =
    if config.min_connections < 0 then
      Result.Error (Invalid_query "pool min_connections must be non-negative")
    else if config.max_connections <= 0 then
      Result.Error (Invalid_query "pool max_connections must be positive")
    else if config.min_connections > config.max_connections then
      Result.Error (Invalid_query "pool min_connections exceeds max_connections")
    else if
      (match config.acquire_timeout_ms with Some value -> value < 0 | None -> false)
      || (match config.idle_timeout_ms with Some value -> value < 0 | None -> false)
      || (match config.max_lifetime_ms with Some value -> value < 0 | None -> false)
    then
      Result.Error (Invalid_query "pool timeout values must be non-negative")
    else
      Ok ()

  let elapsed_ms now started = max 0 (now - started)

  let connection_expired config ~now entry =
    (match config.idle_timeout_ms with
     | Some timeout -> elapsed_ms now entry.idle_since_ms > timeout
     | None -> false)
    ||
    match config.max_lifetime_ms with
    | Some lifetime ->
        elapsed_ms now
          (int_of_float (Connection.created_at entry.conn *. 1000.0))
        > lifetime
    | None -> false

  let close_entry t entry =
    t.total <- max 0 (t.total - 1);
    Connection.close entry.conn

  let rec take_valid_idle_locked t now kept =
    match t.idle with
    | [] ->
        t.idle <- List.rev kept;
        None
    | entry :: rest ->
        t.idle <- rest;
        if connection_expired t.config ~now entry || not (Connection.ping entry.conn)
        then (
          close_entry t entry;
          take_valid_idle_locked t now kept)
        else (
          t.idle <- List.rev_append kept rest;
          Some entry.conn)

  let next_lease_locked t =
    t.next_lease <- t.next_lease + 1;
    t.next_lease

  let mark_in_use_locked t conn =
    let lease_id = next_lease_locked t in
    Connection.set_pool_lease conn lease_id;
    t.in_use <- { leased_conn = conn; lease_id } :: t.in_use

  type reservation =
    | Use of Connection.t
    | Open of int
    | Wait
    | Shutdown

  let reserve_locked t =
    if t.shutdown then
      Shutdown
    else
      let now = now_ms () in
      match take_valid_idle_locked t now [] with
      | Some conn ->
          mark_in_use_locked t conn;
          Use conn
      | None when t.total < t.config.max_connections ->
          t.total <- t.total + 1;
          let lease_id = next_lease_locked t in
          Open lease_id
      | None -> Wait

  let seconds_of_ms ms = float_of_int ms /. 1000.0

  let await_capacity_locked t =
    t.waiting <- t.waiting + 1;
    Fun.protect
      ~finally:(fun () -> t.waiting <- max 0 (t.waiting - 1))
      (fun () ->
        match (t.clock, t.config.acquire_timeout_ms) with
        | _, Some 0 -> `Timeout
        | Some (Clock clock), Some timeout_ms -> (
            match
              Eio.Time.with_timeout clock (seconds_of_ms timeout_ms) (fun () ->
                  Eio.Condition.await t.condition t.mutex;
                  Ok ())
            with
            | Ok () -> `Woke
            | Error `Timeout -> `Timeout)
        | None, Some _ -> `No_clock
        | _, None ->
            Eio.Condition.await t.condition t.mutex;
            `Woke)

  let create ?clock config =
    match validate_config config with
    | Result.Error _ as err -> err
    | Ok () ->
        let rec open_min remaining acc =
          if remaining = 0 then
            Ok acc
          else
            match Connection.create config.sqlite with
            | Ok conn ->
                open_min (remaining - 1) ({ conn; idle_since_ms = now_ms () } :: acc)
            | Result.Error err ->
                List.iter (fun entry -> Connection.close entry.conn) acc;
                Result.Error err
        in
        (match open_min config.min_connections [] with
         | Result.Error _ as err -> err
         | Ok idle ->
             Ok
               {
                 config;
                 clock = Option.map (fun clock -> Clock clock) clock;
                 mutex = Eio.Mutex.create ();
                 condition = Eio.Condition.create ();
                 idle;
                 in_use = [];
                 total = List.length idle;
                 waiting = 0;
                 next_lease = 0;
                 shutdown = false;
               })

  let open_reserved t lease_id =
    match Connection.create t.config.sqlite with
    | Ok conn ->
        with_lock t @@ fun () ->
        if t.shutdown then (
          t.total <- max 0 (t.total - 1);
          Connection.close conn;
          Eio.Condition.broadcast t.condition;
          Result.Error (Pool_error "pool is shut down"))
        else (
          Connection.set_pool_lease conn lease_id;
          t.in_use <- { leased_conn = conn; lease_id } :: t.in_use;
          Ok conn)
    | Result.Error err ->
        with_lock t @@ fun () ->
        t.total <- max 0 (t.total - 1);
        Eio.Condition.broadcast t.condition;
        Result.Error err

  let exhausted_message t =
    "pool exhausted: max_connections=" ^ string_of_int t.config.max_connections
    ^ ", waiting=" ^ string_of_int t.waiting

  let acquire t =
    let rec loop () =
      let decision =
        Eio.Mutex.lock t.mutex;
        match reserve_locked t with
        | Use conn ->
            Eio.Mutex.unlock t.mutex;
            `Use conn
        | Open lease_id ->
            Eio.Mutex.unlock t.mutex;
            `Open lease_id
        | Shutdown ->
            Eio.Mutex.unlock t.mutex;
            `Error (Pool_error "pool is shut down")
        | Wait -> (
            match await_capacity_locked t with
            | `Woke ->
                Eio.Mutex.unlock t.mutex;
                `Retry
            | `Timeout ->
                let message = exhausted_message t in
                Eio.Mutex.unlock t.mutex;
                `Error (Pool_error message)
            | `No_clock ->
                let message =
                  exhausted_message t ^ "; pass ~clock to Pool.create for timed waits"
                in
                Eio.Mutex.unlock t.mutex;
                `Error (Pool_error message))
      in
      match decision with
      | `Use conn -> Ok conn
      | `Open lease_id -> open_reserved t lease_id
      | `Retry -> loop ()
      | `Error err -> Result.Error err
    in
    loop ()

  let same_connection left right =
    String.equal (Connection.id left) (Connection.id right)

  let release t conn =
    let close_now =
      with_lock t @@ fun () ->
      let expected_lease = Connection.pool_lease conn in
      let rec remove found acc = function
        | [] -> (found, List.rev acc)
        | lease :: rest ->
            if same_connection lease.leased_conn conn then
              if lease.lease_id = expected_lease then
                (true, List.rev_append acc rest)
              else
                (false, List.rev_append acc (lease :: rest))
            else
              remove found (lease :: acc) rest
      in
      let found, in_use = remove false [] t.in_use in
      t.in_use <- in_use;
      if not found then
        false
      else if t.shutdown then (
        t.total <- max 0 (t.total - 1);
        Eio.Condition.broadcast t.condition;
        true)
      else if
        not (Connection.ping conn)
        || connection_expired t.config ~now:(now_ms ())
             { conn; idle_since_ms = now_ms () }
      then (
        t.total <- max 0 (t.total - 1);
        Eio.Condition.broadcast t.condition;
        true)
      else (
        t.idle <- { conn; idle_since_ms = now_ms () } :: t.idle;
        Eio.Condition.broadcast t.condition;
        false)
    in
    if close_now then
      Connection.close conn

  let with_connection t f =
    match acquire t with
    | Result.Error _ as err -> err
    | Ok conn ->
        Fun.protect ~finally:(fun () -> release t conn) (fun () -> f conn)

  let shutdown t =
    let idle =
      with_lock t @@ fun () ->
      t.shutdown <- true;
      let idle = t.idle in
      t.idle <- [];
      t.total <- t.total - List.length idle;
      Eio.Condition.broadcast t.condition;
      idle
    in
    List.iter (fun entry -> Connection.close entry.conn) idle

  let stats t =
    with_lock t @@ fun () ->
    [
      Total_connections t.total;
      Available_connections (List.length t.idle);
      In_use_connections (List.length t.in_use);
      Waiting_requests t.waiting;
    ]
end

module Eta_pool = struct
  type error = [ `Sql of sql_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (Connection.t, error) Eta_runtime.Pool.t
  type tx = Connection.t

  let lift_sql_result = function
    | Ok value -> Eta_runtime.Effect.pure value
    | Result.Error err -> Eta_runtime.Effect.fail (`Sql err)

  let blocking_result ?blocking_pool ?name f =
    Eta_runtime.Effect.blocking ?pool:blocking_pool ?name f
    |> Eta_runtime.Effect.bind lift_sql_result

  let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
    let interrupt () = Sqlite.interrupt (Connection.sqlite conn) in
    let check_not_cancelled =
      Eta_runtime.Effect.sync Eio.Fiber.check
    in
    let query =
      Eta_runtime.Effect.blocking ?pool:blocking_pool ~name ~on_cancel:interrupt f
      |> Eta_runtime.Effect.map (function
           | Ok value -> `Query_ok value
           | Result.Error err -> `Query_error err)
    in
    let interrupt =
      Eta_runtime.Effect.delay timeout
        (Eta_runtime.Effect.sync interrupt
        |> Eta_runtime.Effect.map (fun () -> `Timed_out))
    in
    Eta_runtime.Effect.race [ query; interrupt ]
    |> Eta_runtime.Effect.bind (function
         | `Query_ok value ->
             check_not_cancelled
             |> Eta_runtime.Effect.map (fun () -> value)
         | `Query_error err ->
             check_not_cancelled
             |> Eta_runtime.Effect.bind (fun () ->
                    Eta_runtime.Effect.fail (`Sql err))
         | `Timed_out -> Eta_runtime.Effect.fail `Timeout)

  let acquire_connection ?blocking_pool sqlite =
    blocking_result ?blocking_pool ~name:"sqlite.open" (fun () ->
        Connection.create sqlite)

  let release_connection ?blocking_pool conn =
    Eta_runtime.Effect.blocking ?pool:blocking_pool ~name:"sqlite.close" (fun () ->
        Connection.close conn)

  let health_check ?blocking_pool conn =
    Eta_runtime.Effect.blocking ?pool:blocking_pool ~name:"sqlite.ping" (fun () ->
        Connection.ping conn)
    |> Eta_runtime.Effect.bind (fun healthy ->
           if healthy then
             Eta_runtime.Effect.unit
           else
             Eta_runtime.Effect.fail (`Sql (Pool_error "connection health check failed")))

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime sqlite =
    Eta_runtime.Pool.create ?name ~kind:"sql" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime ~acquire:(acquire_connection ?blocking_pool sqlite)
      ~release:(release_connection ?blocking_pool)
      ~health_check:(health_check ?blocking_pool) ()

  let with_connection = Eta_runtime.Pool.with_resource

  let query ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.query"
          (fun () -> Connection.query conn sql params))

  let select ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.select"
          (fun () -> Connection.select conn query))

  let returning ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.returning"
          (fun () -> Connection.returning conn query))

  let prepare_dynamic_statement conn sql params =
    Connection.if_open conn @@ fun () ->
    Connection.touch conn;
    let db = Connection.sqlite conn in
    match sqlite_result (Sqlite.prepare_result db sql) with
    | Result.Error _ as err -> err
    | Ok stmt -> (
        match bind_dynamic_values db stmt params with
        | Ok () -> Ok stmt
        | Result.Error err ->
            ignore (Sqlite.finalize stmt);
            Result.Error err)

  let prepare_typed_statement conn (query : _ Compiled.select) =
    Connection.if_open conn @@ fun () ->
    Connection.touch conn;
    let db = Connection.sqlite conn in
    match sqlite_result (Sqlite.prepare_result db query.sql) with
    | Result.Error _ as err -> err
    | Ok stmt -> (
        match bind_params db stmt query.params with
        | Ok () -> Ok stmt
        | Result.Error err ->
            ignore (Sqlite.finalize stmt);
            Result.Error err)

  let finalize_dynamic_statement conn stmt =
    finalize_result (Connection.sqlite conn) stmt (Ok ())

  let fetch_batch conn stmt batch_size =
    let db = Connection.sqlite conn in
    let rec loop remaining acc =
      if remaining = 0 then
        Ok (List.rev acc, false)
      else
        let rc = Sqlite.step stmt in
        if Sqlite.rc_equal rc Sqlite.row then
          loop (remaining - 1) (materialize_row stmt :: acc)
        else if Sqlite.rc_equal rc Sqlite.done_ then
          Ok (List.rev acc, true)
        else
          match Sqlite.check db ~operation:"query" rc with
          | Ok () -> assert false
          | Result.Error err -> Result.Error (Sqlite err)
    in
    loop batch_size []

  let fetch_typed_batch conn stmt batch_size decode =
    let db = Connection.sqlite conn in
    let rec loop remaining acc =
      if remaining = 0 then
        Ok (List.rev acc, false)
      else
        let rc = Sqlite.step stmt in
        if Sqlite.rc_equal rc Sqlite.row then
          loop (remaining - 1) (decode stmt :: acc)
        else if Sqlite.rc_equal rc Sqlite.done_ then
          Ok (List.rev acc, true)
        else
          match Sqlite.check db ~operation:"select" rc with
          | Ok () -> assert false
          | Result.Error err -> Result.Error (Sqlite err)
    in
    loop batch_size []

  let fold ?blocking_pool ~timeout ?(batch_size = 1024) t sql params ~init ~f =
    if batch_size <= 0 then invalid_arg "Sql.Eta_pool.fold: batch_size must be > 0";
    with_connection t (fun conn ->
        Eta_runtime.Effect.scoped
          (Eta_runtime.Effect.acquire_release
             ~acquire:
               (timed_blocking_result ?blocking_pool ~timeout ~conn
                  ~name:"sqlite.fold.prepare" (fun () ->
                    prepare_dynamic_statement conn sql params))
             ~release:(fun stmt ->
               timed_blocking_result ?blocking_pool ~timeout ~conn
                 ~name:"sqlite.fold.finalize" (fun () ->
                   finalize_dynamic_statement conn stmt))
          |> Eta_runtime.Effect.bind (fun stmt ->
                 let rec loop acc =
                   timed_blocking_result ?blocking_pool ~timeout ~conn
                     ~name:"sqlite.fold.batch" (fun () ->
                       fetch_batch conn stmt batch_size)
                   |> Eta_runtime.Effect.bind (fun (rows, done_) ->
                          let acc = List.fold_left f acc rows in
                          if done_ then Eta_runtime.Effect.pure acc else loop acc)
                 in
                 loop init)))

  let fold_select ?blocking_pool ~timeout ?(batch_size = 1024) t
      (query : _ Compiled.select) ~init ~f =
    if batch_size <= 0 then
      invalid_arg "Sql.Eta_pool.fold_select: batch_size must be > 0";
    with_connection t (fun conn ->
        Eta_runtime.Effect.scoped
          (Eta_runtime.Effect.acquire_release
             ~acquire:
               (timed_blocking_result ?blocking_pool ~timeout ~conn
                  ~name:"sqlite.select_fold.prepare" (fun () ->
                    prepare_typed_statement conn query))
             ~release:(fun stmt ->
               timed_blocking_result ?blocking_pool ~timeout ~conn
                 ~name:"sqlite.select_fold.finalize" (fun () ->
                   finalize_dynamic_statement conn stmt))
          |> Eta_runtime.Effect.bind (fun stmt ->
                 let rec loop acc =
                   timed_blocking_result ?blocking_pool ~timeout ~conn
                     ~name:"sqlite.select_fold.batch" (fun () ->
                       fetch_typed_batch conn stmt batch_size query.decode)
                   |> Eta_runtime.Effect.bind (fun (rows, done_) ->
                          let acc = List.fold_left f acc rows in
                          if done_ then Eta_runtime.Effect.pure acc else loop acc)
                 in
                 loop init)))

  let execute ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.execute"
          (fun () -> Connection.execute conn sql params))

  let execute_compiled ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn
          ~name:"sqlite.execute_compiled" (fun () ->
            Connection.execute_compiled conn query))

  let execute_script ?blocking_pool ~timeout t sql =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn
          ~name:"sqlite.execute_script" (fun () -> Connection.execute_script conn sql))

  let run_schema ?blocking_pool ~timeout t schema =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"sqlite.schema"
          (fun () -> Connection.run_schema conn schema))

  let tx_select ?blocking_pool ~timeout tx query =
    timed_blocking_result ?blocking_pool ~timeout ~conn:tx ~name:"sqlite.tx.select"
      (fun () -> Connection.select tx query)

  let tx_returning ?blocking_pool ~timeout tx query =
    timed_blocking_result ?blocking_pool ~timeout ~conn:tx
      ~name:"sqlite.tx.returning" (fun () -> Connection.returning tx query)

  let tx_execute_compiled ?blocking_pool ~timeout tx query =
    timed_blocking_result ?blocking_pool ~timeout ~conn:tx
      ~name:"sqlite.tx.execute_compiled" (fun () ->
        Connection.execute_compiled tx query)

  let tx_run_schema ?blocking_pool ~timeout tx schema =
    timed_blocking_result ?blocking_pool ~timeout ~conn:tx ~name:"sqlite.tx.schema"
      (fun () -> Connection.run_schema tx schema)

  let tx_fold_select ?blocking_pool ~timeout ?(batch_size = 1024) tx
      (query : _ Compiled.select) ~init ~f =
    if batch_size <= 0 then
      invalid_arg "Sql.Eta_pool.tx_fold_select: batch_size must be > 0";
    Eta_runtime.Effect.scoped
      (Eta_runtime.Effect.acquire_release
         ~acquire:
           (timed_blocking_result ?blocking_pool ~timeout ~conn:tx
              ~name:"sqlite.tx.select_fold.prepare" (fun () ->
                prepare_typed_statement tx query))
         ~release:(fun stmt ->
           timed_blocking_result ?blocking_pool ~timeout ~conn:tx
             ~name:"sqlite.tx.select_fold.finalize" (fun () ->
               finalize_dynamic_statement tx stmt))
      |> Eta_runtime.Effect.bind (fun stmt ->
             let rec loop acc =
               timed_blocking_result ?blocking_pool ~timeout ~conn:tx
                 ~name:"sqlite.tx.select_fold.batch" (fun () ->
                   fetch_typed_batch tx stmt batch_size query.decode)
               |> Eta_runtime.Effect.bind (fun (rows, done_) ->
                      let acc = List.fold_left f acc rows in
                      if done_ then Eta_runtime.Effect.pure acc else loop acc)
             in
             loop init))

  let with_transaction ?blocking_pool ~timeout t body =
    with_connection t (fun conn ->
        let committed = ref false in
        Eta_runtime.Effect.scoped
          (Eta_runtime.Effect.acquire_release
             ~acquire:
               (timed_blocking_result ?blocking_pool ~timeout ~conn
                  ~name:"sqlite.begin_transaction" (fun () ->
                    Connection.begin_transaction conn))
             ~release:(fun () ->
               if !committed then
                 Eta_runtime.Effect.unit
               else
                 timed_blocking_result ?blocking_pool ~timeout ~conn
                   ~name:"sqlite.rollback" (fun () -> Connection.rollback conn))
          |> Eta_runtime.Effect.bind (fun () ->
                 body conn
                 |> Eta_runtime.Effect.bind (fun value ->
                        timed_blocking_result ?blocking_pool ~timeout ~conn
                          ~name:"sqlite.commit" (fun () -> Connection.commit conn)
                        |> Eta_runtime.Effect.map (fun () ->
                               committed := true;
                               value)))))

  let shutdown = Eta_runtime.Pool.shutdown
  let stats = Eta_runtime.Pool.stats
end

module Migrate = struct
  module Version = struct
    type t = int64

    type error =
      | Not_positive of int64
      | Invalid_integer of string
      | Expected_integer_value

    let from_int64 value =
      if Int64.compare value 0L <= 0 then
        Result.Error (Not_positive value)
      else
        Ok value

    let from_int value = from_int64 (Int64.of_int value)

    let from_string value =
      if String.equal value "" then
        Result.Error Expected_integer_value
      else
        match Int64.of_string value with
        | parsed -> from_int64 parsed
        | exception Failure _ -> Result.Error (Invalid_integer value)

    let from_int64_unchecked value = value
    let to_int64 value = value
    let to_string = Int64.to_string
    let equal = Int64.equal
    let compare = Int64.compare

    let error_to_string = function
      | Not_positive value -> "migration version must be positive: " ^ Int64.to_string value
      | Invalid_integer value -> "invalid migration version: " ^ value
      | Expected_integer_value -> "expected integer migration version"
  end

  module Table_name = struct
    type t = string

    type error =
      | Empty
      | Invalid_identifier of string

    let is_ident_start = function
      | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
      | _ -> false

    let is_ident_char = function
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
      | _ -> false

    let from_string value =
      let value = String.trim value in
      if String.equal value "" then
        Result.Error Empty
      else
        let valid_part part =
          let len = String.length part in
          len > 0 && is_ident_start part.[0]
          &&
          let rec loop index =
            index = len || (is_ident_char part.[index] && loop (index + 1))
          in
          loop 1
        in
        if List.for_all valid_part (String.split_on_char '.' value) then
          Ok value
        else
          Result.Error (Invalid_identifier value)

    let from_string_unchecked value = value
    let default = "__eta_migrations"
    let to_string value = value

    let error_to_string = function
      | Empty -> "migration table name must not be empty"
      | Invalid_identifier value -> "invalid migration table name: " ^ value
  end

  type migration_type =
    | Simple
    | Reversible_up
    | Reversible_down

  let migration_type_to_string = function
    | Simple -> "simple"
    | Reversible_up -> "up"
    | Reversible_down -> "down"

  let no_transaction_directive = "-- no-transaction"

  let starts_with value prefix =
    let value_len = String.length value in
    let prefix_len = String.length prefix in
    value_len >= prefix_len
    && String.equal (String.sub value 0 prefix_len) prefix

  let strip_no_transaction_directive sql =
    if starts_with sql no_transaction_directive then
      let offset = String.length no_transaction_directive in
      let rest = String.sub sql offset (String.length sql - offset) in
      if starts_with rest "\r\n" then
        String.sub rest 2 (String.length rest - 2)
      else if starts_with rest "\n" then
        String.sub rest 1 (String.length rest - 1)
      else
        rest
    else
      sql

  let sha256_hex value =
    value
    |> Cstruct.of_string
    |> Mirage_crypto.Hash.SHA256.digest
    |> Cstruct.to_hex_string

  let checksum_sql sql =
    sha256_hex (strip_no_transaction_directive sql)

  module Migration = struct
    type t = {
      version : Version.t;
      description : string;
      migration_type : migration_type;
      sql : string;
      checksum : string;
      no_tx : bool;
    }

    let make ?(no_tx = false) ?checksum ~version ~description ~migration_type ~sql () =
      {
        version;
        description;
        migration_type;
        sql;
        checksum =
          (match checksum with
           | Some checksum -> checksum
           | None -> checksum_sql sql);
        no_tx;
      }
  end

  module Applied_migration = struct
    type t = {
      version : Version.t;
      checksum : string;
    }
  end

  module Config = struct
    type t = {
      table_name : Table_name.t;
      ignore_missing : bool;
    }

    let default = { table_name = Table_name.default; ignore_missing = false }
  end

  type applied = {
    migration : Migration.t;
    elapsed_ms : int;
  }

  type run_report = {
    applied : applied list;
    already_applied : Applied_migration.t list;
  }

  type source_error =
    | Read_migration_file_failed of {
        path : string;
        reason : string;
      }
    | Read_migration_directory_failed of {
        path : string;
        reason : string;
      }
    | Inspect_migration_path_failed of {
        path : string;
        reason : string;
      }

  type error =
    | Source_error of source_error
    | Invalid_version of Version.error
    | Invalid_table_name of Table_name.error
    | Sql_error of sql_error
    | Dirty of Version.t
    | Version_missing of Version.t
    | Version_mismatch of Version.t
    | Version_not_present of Version.t
    | Migration_execution_error of {
        version : Version.t;
        error : sql_error;
      }

  module Source = struct
    type resolve_config = { ignored_checksum_chars : char list }

    let default_resolve_config = { ignored_checksum_chars = [] }

    type t =
      | Directory of string
      | Migrations of Migration.t list

    exception Read_file_failed of string * string

    let from_directory path = Directory path
    let from_migrations migrations = Migrations migrations

    let has_suffix value suffix =
      let value_len = String.length value in
      let suffix_len = String.length suffix in
      value_len >= suffix_len
      && String.equal
           (String.sub value (value_len - suffix_len) suffix_len)
           suffix

    let strip_suffix value suffix =
      if has_suffix value suffix then
        String.sub value 0 (String.length value - String.length suffix)
      else
        value

    let normalize_checksum_sql config sql =
      let sql = strip_no_transaction_directive sql in
      match config.ignored_checksum_chars with
      | [] -> sql
      | ignored ->
          String.to_seq sql
          |> Seq.filter (fun c -> not (List.exists (Char.equal c) ignored))
          |> String.of_seq

    let read_file path =
      match open_in_bin path with
      | input ->
          Fun.protect
            ~finally:(fun () -> close_in_noerr input)
            (fun () -> really_input_string input (in_channel_length input))
      | exception Sys_error reason ->
          raise (Sys_error reason)

    let is_regular_file path =
      match Unix.lstat path with
      | stats -> Ok (stats.Unix.st_kind = Unix.S_REG)
      | exception Unix.Unix_error (err, _, _) ->
          Result.Error (Unix.error_message err)
      | exception Sys_error reason -> Result.Error reason

    let parse_name name =
      if not (has_suffix name ".sql") then
        Ok None
      else
        match String.index_opt name '_' with
        | None -> Result.Error (Invalid_version Version.Expected_integer_value)
        | Some split -> (
            let version_text = String.sub name 0 split in
            match Version.from_string version_text with
            | Result.Error err -> Result.Error (Invalid_version err)
            | Ok version ->
                let rest =
                  String.sub name (split + 1) (String.length name - split - 1)
                in
                let migration_type, raw_description =
                  if has_suffix rest ".up.sql" then
                    (Reversible_up, strip_suffix rest ".up.sql")
                  else if has_suffix rest ".down.sql" then
                    (Reversible_down, strip_suffix rest ".down.sql")
                  else
                    (Simple, strip_suffix rest ".sql")
                in
                let description =
                  String.map (fun c -> if Char.equal c '_' then ' ' else c) raw_description
                in
                Ok (Some (version, description, migration_type)))

    let resolve ?(config = default_resolve_config) = function
      | Migrations migrations ->
          Ok (List.sort (fun left right -> Version.compare left.Migration.version right.version) migrations)
      | Directory dir -> (
          let entries =
            match Sys.readdir dir with
            | entries -> Array.to_list entries
            | exception Sys_error reason ->
                raise (Sys_error reason)
          in
          let rec loop acc = function
            | [] ->
                Ok
                  (List.sort
                     (fun left right -> Version.compare left.Migration.version right.version)
                     acc)
            | name :: rest -> (
                let path = Filename.concat dir name in
                match is_regular_file path with
                | Result.Error reason ->
                    Result.Error
                      (Source_error
                         (Inspect_migration_path_failed { path; reason }))
                | Ok false -> loop acc rest
                | Ok true -> (
                    match parse_name name with
                    | Result.Error _ as err -> err
                    | Ok None -> loop acc rest
                    | Ok (Some (version, description, migration_type)) ->
                        let sql =
                          match read_file path with
                          | sql -> sql
                          | exception Sys_error reason ->
                              raise (Read_file_failed (path, reason))
                        in
                        let no_tx = starts_with sql "-- no-transaction" in
                        let checksum =
                          checksum_sql (normalize_checksum_sql config sql)
                        in
                        let migration =
                          Migration.make ~no_tx ~checksum ~version ~description
                            ~migration_type ~sql ()
                        in
                        loop (migration :: acc) rest))
          in
          match loop [] entries with
          | Ok _ as ok -> ok
          | Result.Error _ as err -> err
          | exception Read_file_failed (path, reason) ->
              Result.Error
                (Source_error
                   (Read_migration_file_failed { path; reason }))
          | exception Sys_error reason ->
              Result.Error
                (Source_error
                   (Read_migration_directory_failed { path = dir; reason })))
  end

  let error_to_string = function
    | Source_error (Read_migration_file_failed { path; reason }) ->
        "read migration file failed: " ^ path ^ ": " ^ reason
    | Source_error (Read_migration_directory_failed { path; reason }) ->
        "read migration directory failed: " ^ path ^ ": " ^ reason
    | Source_error (Inspect_migration_path_failed { path; reason }) ->
        "inspect migration path failed: " ^ path ^ ": " ^ reason
    | Invalid_version err -> Version.error_to_string err
    | Invalid_table_name err -> Table_name.error_to_string err
    | Sql_error err -> show_error err
    | Dirty version -> "dirty migration version: " ^ Version.to_string version
    | Version_missing version -> "migration version missing: " ^ Version.to_string version
    | Version_mismatch version -> "migration checksum mismatch: " ^ Version.to_string version
    | Version_not_present version -> "migration version not present: " ^ Version.to_string version
    | Migration_execution_error { version; error } ->
        "migration " ^ Version.to_string version ^ " failed: " ^ show_error error

  type applied_state = {
    applied_version : Version.t;
    applied_checksum : string;
    applied_success : bool;
  }

  let table_name config = quote_ident (Table_name.to_string config.Config.table_name)

  let ensure_table conn config =
    let table = table_name config in
    Connection.execute_script conn
      ("CREATE TABLE IF NOT EXISTS " ^ table
     ^ " (version INTEGER PRIMARY KEY, description TEXT NOT NULL, checksum TEXT NOT NULL, success INTEGER NOT NULL, installed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, execution_time_ms INTEGER NOT NULL DEFAULT 0)")

  let decode_applied_row row =
    match (Row.int64 "version" row, Row.string "checksum" row, Row.bool "success" row) with
    | Some version, Some checksum, Some success ->
        Ok { applied_version = version; applied_checksum = checksum; applied_success = success }
    | _ ->
        Result.Error
          (Sql_error
             (Decode_error
                {
                  operation = "migrate.list_applied";
                  message = "migration table row has unexpected shape";
                }))

  let load_applied_states conn config =
    match ensure_table conn config with
    | Result.Error err -> Result.Error (Sql_error err)
    | Ok () -> (
        match
          Connection.query conn
            ("SELECT version, checksum, success FROM " ^ table_name config ^ " ORDER BY version")
            []
        with
        | Result.Error err -> Result.Error (Sql_error err)
        | Ok rows ->
            let rec loop acc = function
              | [] -> Ok (List.rev acc)
              | row :: rest -> (
                  match decode_applied_row row with
                  | Ok applied -> loop (applied :: acc) rest
                  | Result.Error _ as err -> err)
            in
            loop [] rows)

  let list_applied ?(config = Config.default) pool =
    let run conn =
      match load_applied_states conn config with
      | Result.Error _ as err -> err
      | Ok states ->
          Ok
            (states
             |> List.filter (fun state -> state.applied_success)
             |> List.map (fun state ->
                    {
                      Applied_migration.version = state.applied_version;
                      checksum = state.applied_checksum;
                    }))
    in
    match Pool.acquire pool with
    | Result.Error err -> Result.Error (Sql_error err)
    | Ok conn -> Fun.protect ~finally:(fun () -> Pool.release pool conn) (fun () -> run conn)

  let up_migrations migrations =
    migrations
    |> List.filter (fun migration ->
           match migration.Migration.migration_type with
           | Simple | Reversible_up -> true
           | Reversible_down -> false)

  let find_migration version migrations =
    List.find_opt (fun migration -> Version.equal migration.Migration.version version) migrations

  let validate_applied config migrations applied =
    let rec loop already = function
      | [] -> Ok (List.rev already)
      | state :: rest ->
          if not state.applied_success then
            Result.Error (Dirty state.applied_version)
          else (
            match find_migration state.applied_version migrations with
            | None when config.Config.ignore_missing ->
                loop
                  ({
                     Applied_migration.version = state.applied_version;
                     checksum = state.applied_checksum;
                   }
                  :: already)
                  rest
            | None -> Result.Error (Version_missing state.applied_version)
            | Some migration ->
                if String.equal migration.Migration.checksum state.applied_checksum then
                  loop
                    ({
                       Applied_migration.version = state.applied_version;
                       checksum = state.applied_checksum;
                     }
                    :: already)
                    rest
                else
                  Result.Error (Version_mismatch state.applied_version))
    in
    loop [] applied

  let elapsed_ms start =
    int_of_float ((Unix.gettimeofday () -. start) *. 1000.0)

  let execute_body conn migration =
    if migration.Migration.no_tx then
      Connection.execute_script conn migration.Migration.sql
    else
      Connection.with_transaction conn (fun conn ->
          Connection.execute_script conn migration.Migration.sql)

  let mark_dirty conn table migration =
    Connection.execute conn
      ("INSERT OR REPLACE INTO " ^ table
     ^ " (version, description, checksum, success, installed_at, execution_time_ms) VALUES (?, ?, ?, 0, CURRENT_TIMESTAMP, 0)")
      [
        Value.Int64 migration.Migration.version;
        String migration.Migration.description;
        String migration.Migration.checksum;
      ]

  let mark_success conn table migration elapsed =
    Connection.execute conn
      ("UPDATE " ^ table
     ^ " SET checksum = ?, success = 1, execution_time_ms = ? WHERE version = ?")
      [ Value.String migration.Migration.checksum; Int elapsed; Int64 migration.Migration.version ]

  let apply_one conn config migration =
    let table = table_name config in
    match mark_dirty conn table migration with
    | Result.Error err ->
        Result.Error
          (Migration_execution_error { version = migration.Migration.version; error = err })
    | Ok _ -> (
        let start = Unix.gettimeofday () in
        match execute_body conn migration with
        | Result.Error err ->
            Result.Error
              (Migration_execution_error
                 { version = migration.Migration.version; error = err })
        | Ok () ->
            let elapsed = elapsed_ms start in
            match mark_success conn table migration elapsed with
            | Result.Error err ->
                Result.Error
                  (Migration_execution_error
                     { version = migration.Migration.version; error = err })
            | Ok _ -> Ok { migration; elapsed_ms = elapsed })

  let run_migrations config pool migrations =
    match Pool.acquire pool with
    | Result.Error err -> Result.Error (Sql_error err)
    | Ok conn ->
        Fun.protect ~finally:(fun () -> Pool.release pool conn) @@ fun () ->
        match load_applied_states conn config with
        | Result.Error _ as err -> err
        | Ok applied_states -> (
            let up = up_migrations migrations in
            match validate_applied config up applied_states with
            | Result.Error _ as err -> err
            | Ok already_applied ->
                let pending =
                  up
                  |> List.filter (fun migration ->
                         not
                           (List.exists
                              (fun state ->
                                state.applied_success
                                && Version.equal state.applied_version
                                     migration.Migration.version)
                              applied_states))
                in
                let rec loop acc = function
                  | [] -> Ok { applied = List.rev acc; already_applied }
                  | migration :: rest -> (
                      match apply_one conn config migration with
                      | Ok applied -> loop (applied :: acc) rest
                      | Result.Error _ as err -> err)
                in
                loop [] pending)

  let run ?(config = Config.default) pool source =
    match Source.resolve source with
    | Result.Error _ as err -> err
    | Ok migrations -> run_migrations config pool migrations

  let run_to ?(config = Config.default) pool source ~target =
    match Source.resolve source with
    | Result.Error _ as err -> err
    | Ok migrations ->
        let up = up_migrations migrations in
        if not (List.exists (fun migration -> Version.equal migration.Migration.version target) up) then
          Result.Error (Version_not_present target)
        else
          let migrations =
            List.filter
              (fun migration -> Version.compare migration.Migration.version target <= 0)
              migrations
          in
          run_migrations config pool migrations

  let down_migration_for version migrations =
    List.find_opt
      (fun migration ->
        Version.equal migration.Migration.version version
        &&
        match migration.Migration.migration_type with
        | Reversible_down -> true
        | Simple | Reversible_up -> false)
      migrations

  let undo ?(config = Config.default) pool source ~target =
    match Source.resolve source with
    | Result.Error _ as err -> err
    | Ok migrations -> (
        match Pool.acquire pool with
        | Result.Error err -> Result.Error (Sql_error err)
        | Ok conn ->
            Fun.protect ~finally:(fun () -> Pool.release pool conn) @@ fun () ->
            match load_applied_states conn config with
            | Result.Error _ as err -> err
            | Ok applied_states -> (
                let dirty =
                  List.find_opt (fun state -> not state.applied_success) applied_states
                in
                match dirty with
                | Some state -> Result.Error (Dirty state.applied_version)
                | None ->
                    let to_undo =
                      applied_states
                      |> List.filter (fun state ->
                             Version.compare state.applied_version target > 0)
                      |> List.sort (fun left right ->
                             Version.compare right.applied_version left.applied_version)
                    in
                    let table = table_name config in
                    let rec loop acc = function
                      | [] ->
                          Ok
                            {
                              applied = List.rev acc;
                              already_applied =
                                applied_states
                                |> List.filter (fun state ->
                                       Version.compare state.applied_version target <= 0)
                                |> List.map (fun state ->
                                       {
                                         Applied_migration.version = state.applied_version;
                                         checksum = state.applied_checksum;
                                       });
                            }
                      | state :: rest -> (
                          match down_migration_for state.applied_version migrations with
                          | None -> Result.Error (Version_not_present state.applied_version)
                          | Some migration -> (
                              let start = Unix.gettimeofday () in
                              match execute_body conn migration with
                              | Result.Error err ->
                                  Result.Error
                                    (Migration_execution_error
                                       { version = migration.Migration.version; error = err })
                              | Ok () -> (
                                  match
                                    Connection.execute conn
                                      ("DELETE FROM " ^ table ^ " WHERE version = ?")
                                      [ Value.Int64 state.applied_version ]
                                  with
                                  | Result.Error err ->
                                      Result.Error
                                        (Migration_execution_error
                                           { version = migration.Migration.version; error = err })
                                  | Ok _ ->
                                      loop
                                        ({ migration; elapsed_ms = elapsed_ms start } :: acc)
                                        rest)))
                    in
                    loop [] to_undo))
end

let connect ?clock ?min_connections ?max_connections sqlite =
  let min_connections =
    match min_connections with
    | Some value -> value
    | None -> 0
  in
  let max_connections =
    match max_connections with
    | Some value -> value
    | None -> 10
  in
  Pool.create ?clock (Pool.config ~min_connections ~max_connections sqlite)

let query pool sql params =
  Pool.with_connection pool (fun conn -> Connection.query conn sql params)

let exec pool sql params =
  Pool.with_connection pool (fun conn -> Connection.execute conn sql params)

let with_transaction pool f =
  Pool.with_connection pool (fun conn -> Connection.with_transaction conn f)

let migrate ?(config = Migrate.Config.default) ?source pool () =
  let source =
    match source with
    | Some source -> source
    | None -> Migrate.Source.from_directory "migrations"
  in
  match Migrate.run ~config pool source with
  | Ok _ -> Ok ()
  | Result.Error _ as err -> err

let shutdown = Pool.shutdown
