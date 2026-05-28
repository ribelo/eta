module Value = Eta_sql.Value
module Row = Eta_sql.Row

type raw_db
type raw_stmt

type rc = int

type open_mode =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode =
  | Mvcc
  | Wal

type config = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode;
}

type transaction_mode =
  | Read
  | Write
  | Concurrent

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      code : rc;
      extended_code : int;
      message : string;
    }
  | Invalid_config of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Closed

exception Error of error

type db = {
  raw : raw_db;
  config : config;
  mutable closed : bool;
}

type stmt = {
  db : db;
  raw : raw_stmt;
  mutable finalized : bool;
}

external raw_available : unit -> string option = "eta_turso_available"
external raw_open : string -> (int[@untagged]) -> raw_db = "eta_turso_open_bc" "eta_turso_open"
external raw_close : raw_db -> (int[@untagged]) = "eta_turso_close_bc" "eta_turso_close"
external raw_prepare : raw_db -> string -> raw_stmt = "eta_turso_prepare"
external raw_finalize : raw_stmt -> (int[@untagged]) = "eta_turso_finalize_bc" "eta_turso_finalize"
external raw_step : raw_stmt -> (int[@untagged]) = "eta_turso_step_bc" "eta_turso_step"
external raw_bind_null : raw_stmt -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_bind_null_bc" "eta_turso_bind_null"
external raw_bind_int64 : raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) -> (int[@untagged]) = "eta_turso_bind_int64_bc" "eta_turso_bind_int64"
external raw_bind_double : raw_stmt -> (int[@untagged]) -> (float[@unboxed]) -> (int[@untagged]) = "eta_turso_bind_double_bc" "eta_turso_bind_double"
external raw_bind_text : raw_stmt -> (int[@untagged]) -> string -> (int[@untagged]) = "eta_turso_bind_text_bc" "eta_turso_bind_text"
external raw_bind_blob : raw_stmt -> (int[@untagged]) -> bytes -> (int[@untagged]) = "eta_turso_bind_blob_bc" "eta_turso_bind_blob"
external raw_column_count : raw_stmt -> (int[@untagged]) = "eta_turso_column_count_bc" "eta_turso_column_count"
external raw_column_name : raw_stmt -> (int[@untagged]) -> string = "eta_turso_column_name_bc" "eta_turso_column_name"
external raw_column_type : raw_stmt -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_column_type_bc" "eta_turso_column_type"
external raw_column_int64 : raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) = "eta_turso_column_int64_bc" "eta_turso_column_int64"
external raw_column_double : raw_stmt -> (int[@untagged]) -> (float[@unboxed]) = "eta_turso_column_double_bc" "eta_turso_column_double"
external raw_column_text : raw_stmt -> (int[@untagged]) -> string = "eta_turso_column_text_bc" "eta_turso_column_text"
external raw_column_blob : raw_stmt -> (int[@untagged]) -> bytes = "eta_turso_column_blob_bc" "eta_turso_column_blob"
external raw_changes : raw_db -> (int[@untagged]) = "eta_turso_changes_bc" "eta_turso_changes"
external raw_busy_timeout : raw_db -> (int[@untagged]) -> (int[@untagged]) = "eta_turso_busy_timeout_bc" "eta_turso_busy_timeout"
external raw_errcode : raw_db -> (int[@untagged]) = "eta_turso_errcode_bc" "eta_turso_errcode"
external raw_extended_errcode : raw_db -> (int[@untagged]) = "eta_turso_extended_errcode_bc" "eta_turso_extended_errcode"
external raw_errmsg : raw_db -> string = "eta_turso_errmsg"

let ok = 0
let row = 100
let done_ = 101
let busy = 5
let locked = 6

let sqlite_integer = 1
let sqlite_float = 2
let sqlite_text = 3
let sqlite_blob = 4
let sqlite_null = 5

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "turso library unavailable: %s" message
  | Driver_error { operation; code; extended_code; message } ->
      Format.fprintf ppf "%s: rc=%d xrc=%d: %s" operation code extended_code message
  | Invalid_config message -> Format.fprintf ppf "invalid Turso config: %s" message
  | Invalid_query message -> Format.fprintf ppf "invalid query: %s" message
  | Decode_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Closed -> Format.pp_print_string ppf "Turso database is closed"

let show_error err = Format.asprintf "%a" pp_error err
let raise_error err = raise (Error err)
let pp_turso_error = pp_error

let available () =
  match raw_available () with
  | None -> Ok ()
  | Some message -> Result.Error (Library_unavailable message)

let open_mode_code = function
  | Read_only -> 0
  | Read_write -> 1
  | Read_write_create -> 2

let journal_mode_sql = function
  | Mvcc -> "mvcc"
  | Wal -> "wal"

let default_config path =
  {
    path;
    mode = Read_write_create;
    busy_timeout_ms = Some 5_000;
    foreign_keys = true;
    journal_mode = Mvcc;
  }

let make_driver_error (db : db) ~operation code =
  Driver_error
    {
      operation;
      code;
      extended_code = raw_extended_errcode db.raw;
      message = raw_errmsg db.raw;
    }

let check db ~operation rc =
  if rc = ok then Ok () else Result.Error (make_driver_error db ~operation rc)

let if_open db f = if db.closed then Result.Error Closed else f ()

let bind_value db stmt index = function
  | Value.Null -> check db ~operation:"bind null" (raw_bind_null stmt.raw index)
  | Int value -> check db ~operation:"bind int" (raw_bind_int64 stmt.raw index (Int64.of_int value))
  | Int64 value -> check db ~operation:"bind int64" (raw_bind_int64 stmt.raw index value)
  | Float value -> check db ~operation:"bind float" (raw_bind_double stmt.raw index value)
  | String value -> check db ~operation:"bind text" (raw_bind_text stmt.raw index value)
  | Bool value -> check db ~operation:"bind bool" (raw_bind_int64 stmt.raw index (if value then 1L else 0L))
  | Bytes value -> check db ~operation:"bind blob" (raw_bind_blob stmt.raw index value)

let bind_values db stmt values =
  let rec loop index = function
    | [] -> Ok ()
    | value :: rest -> (
        match bind_value db stmt index value with
        | Ok () -> loop (index + 1) rest
        | Result.Error _ as err -> err)
  in
  loop 1 values

let read_value raw index =
  match raw_column_type raw index with
  | value when value = sqlite_null -> Value.Null
  | value when value = sqlite_integer ->
      let value = raw_column_int64 raw index in
      let min = Int64.of_int min_int in
      let max = Int64.of_int max_int in
      if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
        Int (Int64.to_int value)
      else
        Int64 value
  | value when value = sqlite_float -> Float (raw_column_double raw index)
  | value when value = sqlite_text -> String (raw_column_text raw index)
  | value when value = sqlite_blob -> Bytes (raw_column_blob raw index)
  | _ -> Null

let materialize_row raw =
  let count = raw_column_count raw in
  let rec loop index acc =
    if index < 0 then acc
    else loop (index - 1) ((raw_column_name raw index, read_value raw index) :: acc)
  in
  loop (count - 1) []

let prepare db sql =
  if_open db @@ fun () ->
  match raw_prepare db.raw sql with
  | raw -> Ok { db; raw; finalized = false }
  | exception Failure message ->
      Result.Error
        (Driver_error
           {
             operation = "prepare";
             code = raw_errcode db.raw;
             extended_code = raw_extended_errcode db.raw;
             message;
           })

let finalize stmt =
  if stmt.finalized then Ok ()
  else (
    stmt.finalized <- true;
    check stmt.db ~operation:"finalize" (raw_finalize stmt.raw))

let with_statement db sql params f =
  match prepare db sql with
  | Result.Error _ as err -> err
  | Ok stmt -> (
      match bind_values db stmt params with
      | Result.Error err ->
          ignore (finalize stmt);
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
          ignore (finalize stmt);
          result)

let step stmt = if stmt.finalized then 21 else raw_step stmt.raw

let query db sql params =
  if_open db @@ fun () ->
  with_statement db sql params @@ fun stmt ->
  let rec loop acc =
    let rc = step stmt in
    if rc = row then loop (materialize_row stmt.raw :: acc)
    else if rc = done_ then Ok (List.rev acc)
    else Result.Error (make_driver_error db ~operation:"query" rc)
  in
  loop []

let execute db sql params =
  if_open db @@ fun () ->
  with_statement db sql params @@ fun stmt ->
  let rc = step stmt in
  if rc = done_ then Ok (raw_changes db.raw)
  else Result.Error (make_driver_error db ~operation:"execute" rc)

let exec_script db sql = execute db sql [] |> Result.map (fun _ -> ())

let query_one_string db sql =
  match query db sql [] with
  | Ok [ row ] -> (
      match row with
      | [ (_, String value) ] -> Ok value
      | [ (_, value) ] -> Ok (Value.to_string value)
      | _ -> Result.Error (Decode_error { operation = sql; message = "expected one column" }))
  | Ok _ -> Result.Error (Decode_error { operation = sql; message = "expected one row" })
  | Result.Error _ as err -> err

let bool_sql value = if value then "ON" else "OFF"

let apply_config db =
  Result.bind
    (match db.config.busy_timeout_ms with
     | None -> Ok ()
     | Some ms -> check db ~operation:"busy timeout" (raw_busy_timeout db.raw ms))
    (fun () ->
      Result.bind
        (exec_script db ("PRAGMA foreign_keys = " ^ bool_sql db.config.foreign_keys))
        (fun () ->
          let expected = journal_mode_sql db.config.journal_mode in
          Result.bind
            (query_one_string db ("PRAGMA journal_mode = '" ^ expected ^ "'"))
            (fun actual ->
              if String.equal (String.lowercase_ascii actual) expected then Ok ()
              else
                Result.Error
                  (Invalid_config
                     ("requested journal_mode=" ^ expected ^ " but Turso reported "
                    ^ actual)))))

let open_ config =
  match available () with
  | Result.Error _ as err -> err
  | Ok () -> (
      match raw_open config.path (open_mode_code config.mode) with
      | raw ->
          let db = { raw; config; closed = false } in
          (match apply_config db with
           | Ok () -> Ok db
           | Result.Error err ->
               ignore (raw_close raw);
               Result.Error err)
      | exception Failure message -> Result.Error (Library_unavailable message))

let open_exn config =
  match open_ config with
  | Ok db -> db
  | Result.Error err -> raise_error err

let close db =
  if db.closed then Ok ()
  else (
    db.closed <- true;
    check db ~operation:"close" (raw_close db.raw))

let close_exn db = match close db with Ok () -> () | Result.Error err -> raise_error err

let begin_sql = function
  | Read -> "BEGIN"
  | Write -> "BEGIN IMMEDIATE"
  | Concurrent -> "BEGIN CONCURRENT"

let begin_transaction ?(mode = Write) db =
  if mode = Concurrent && db.config.journal_mode <> Mvcc then
    Result.Error (Invalid_config "BEGIN CONCURRENT requires journal_mode=Mvcc")
  else
    exec_script db (begin_sql mode)

let commit db = exec_script db "COMMIT"
let rollback db = exec_script db "ROLLBACK"

let transaction ?mode db f =
  match begin_transaction ?mode db with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f db with
      | Ok value -> (
          match commit db with
          | Ok () -> Ok value
          | Result.Error _ as err -> err)
      | Result.Error _ as err ->
          ignore (rollback db);
          err
      | exception exn ->
          ignore (rollback db);
          raise exn)

let is_retryable = function
  | Driver_error { code; _ } -> code = busy || code = locked || code = 1
  | _ -> false

let retry_on_conflict ~max_attempts ~backoff f =
  if max_attempts <= 0 then invalid_arg "Eta_turso.retry_on_conflict: max_attempts must be positive";
  let rec loop attempt =
    match f () with
    | Ok _ as ok -> ok
    | Result.Error err when attempt < max_attempts && is_retryable err ->
        backoff ~attempt;
        loop (attempt + 1)
    | Result.Error _ as err -> err
  in
  loop 1

type 'a typ = {
  value : 'a -> Value.t;
  decode : Value.t -> 'a option;
  sql_type : string;
}

let int =
  {
    value = (fun value -> Value.Int value);
    decode = Value.to_int;
    sql_type = "INTEGER";
  }

let int64 =
  {
    value = (fun value -> Value.Int64 value);
    decode = Value.to_int64;
    sql_type = "INTEGER";
  }

let text =
  {
    value = (fun value -> Value.String value);
    decode = Value.to_string_value;
    sql_type = "TEXT";
  }

let bool =
  {
    value = (fun value -> Value.Bool value);
    decode = Value.to_bool;
    sql_type = "INTEGER";
  }

let float =
  {
    value = (fun value -> Value.Float value);
    decode = Value.to_float;
    sql_type = "REAL";
  }

let blob =
  {
    value = (fun value -> Value.Bytes value);
    decode = Value.to_bytes;
    sql_type = "BLOB";
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
    invalid_arg "Turso identifiers must not be empty";
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
      | None -> failwith (operation ^ ": could not decode value " ^ Value.to_string value))

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
    | [] -> invalid_arg "Eta_turso.Select.group_by_many: columns must not be empty"
    | columns -> { query with group_by = query.group_by @ List.map column_sql columns }

  let having expr query = { query with having = Some expr }
  let order_by ?(desc = false) column query = { query with order_by = query.order_by @ [ { sql = column_sql column; desc } ] }

  let limit count query =
    if count < 0 then invalid_arg "Eta_turso.Select.limit: count must be non-negative";
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
    | [] -> Result.Error (Invalid_query "INSERT requires at least one value")
    | values ->
        let columns = List.map Assignment.column_sql values |> String.concat ", " in
        let placeholders = List.map (fun _ -> "?") values |> String.concat ", " in
        Ok (columns, placeholders)

  let conflict_target columns =
    match columns with
    | [] -> invalid_arg "Eta_turso.Insert.on_conflict: target columns must not be empty"
    | columns -> List.map column_ident columns

  let on_conflict_do_nothing columns query = { query with conflict = Some (Do_nothing (conflict_target columns)) }

  let on_conflict_update columns ~set query =
    match set with
    | [] -> invalid_arg "Eta_turso.Insert.on_conflict_update: set columns must not be empty"
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
    | [] -> raise (Error (Invalid_query "UPDATE requires at least one set"))
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
    if columns = [] then invalid_arg "Eta_turso.Eta_schema.create_table: columns must not be empty";
    Create_table { if_not_exists; table = table.table_name; columns }

  let drop_table ?(if_exists = false) (table : _ table) = Drop_table { if_exists; table = table.table_name }

  let create_index ?(unique = false) ?(if_not_exists = false) ~name (table : _ table) columns =
    if columns = [] then invalid_arg "Eta_turso.Eta_schema.create_index: columns must not be empty";
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

let select db (compiled : _ Compiled.select) =
  match query db compiled.sql (params_to_values compiled.params) with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map compiled.decode rows with
      | values -> Ok values
      | exception Failure message -> Result.Error (Decode_error { operation = "select"; message }))

let returning db (compiled : _ Compiled.returning) =
  match query db compiled.sql (params_to_values compiled.params) with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map compiled.decode rows with
      | values -> Ok values
      | exception Failure message -> Result.Error (Decode_error { operation = "returning"; message }))

let execute_compiled db (compiled : Compiled.change) =
  execute db compiled.sql (params_to_values compiled.params)

let run_schema db (schema : Compiled.schema) = exec_script db schema.sql

module Pool = struct
  type raw_error = [ `Turso of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (db, raw_error) Eta.Pool.t

  type nonrec error =
    | Turso of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let pp_error ppf = function
    | Turso err -> pp_turso_error ppf err
    | Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
    | Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
    | Timeout -> Format.pp_print_string ppf "timeout"

  let to_public_error = function
    | `Turso err -> Turso err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Turso err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let acquire ?blocking_pool config =
    blocking_result ?blocking_pool ~name:"turso.open" (fun () -> open_ config)

  let release ?blocking_pool db =
    Eta.Effect.blocking ?pool:blocking_pool ~name:"turso.close" (fun () ->
        ignore (close db))

  let health_check ?blocking_pool db =
    blocking_result ?blocking_pool ~name:"turso.ping" (fun () ->
        match query db "SELECT 1" [] with
        | Ok _ -> Ok ()
        | Result.Error _ as err -> err)

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime config =
    Eta.Pool.create ?name ~kind:"turso" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime ~acquire:(acquire ?blocking_pool config)
      ~release:(release ?blocking_pool)
      ~health_check:(health_check ?blocking_pool) ()
    |> public

  let with_db t f =
    Eta.Pool.with_resource t (fun db -> f db |> Eta.Effect.map_error (function
        | Turso err -> `Turso err
        | Pool_shutdown -> `Pool_shutdown
        | Pool_shutdown_timeout -> `Pool_shutdown_timeout
        | Timeout -> `Timeout))
    |> public

  let query ?blocking_pool t sql params =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.query" (fun () ->
            query db sql params)
        |> public)

  let select ?blocking_pool t query =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.select" (fun () ->
            select db query)
        |> public)

  let returning ?blocking_pool t query =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.returning" (fun () ->
            returning db query)
        |> public)

  let execute ?blocking_pool t sql params =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.execute" (fun () ->
            execute db sql params)
        |> public)

  let execute_compiled ?blocking_pool t query =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.execute_compiled" (fun () ->
            execute_compiled db query)
        |> public)

  let run_schema ?blocking_pool t schema =
    with_db t (fun db ->
        blocking_result ?blocking_pool ~name:"turso.schema" (fun () ->
            run_schema db schema)
        |> public)

  let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
  let stats = Eta.Pool.stats
end
