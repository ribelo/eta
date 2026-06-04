type error : immutable_data =
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

exception Error of error

let raise_error err = raise (Error err)

type 'a typ = {
  value : ('a -> Value.t) @@ many;
  decode : (Sqlite.stmt -> int -> 'a) @@ many;
  sql_type : string;
}

let int =
  {
    value = (fun value -> Value.Int value);
    decode = Sqlite.column_int;
    sql_type = "INTEGER";
  }

let int64 =
  {
    value = (fun value -> Value.Int64 value);
    decode = Sqlite.column_int64;
    sql_type = "INTEGER";
  }

let text =
  {
    value = (fun value -> Value.String value);
    decode = Sqlite.column_text;
    sql_type = "TEXT";
  }

let float =
  {
    value = (fun value -> Value.Float value);
    decode = Sqlite.column_float;
    sql_type = "REAL";
  }

let blob =
  {
    value = (fun value -> Value.Bytes value);
    decode = Sqlite.column_blob;
    sql_type = "BLOB";
  }

let bool =
  {
    value = (fun value -> Value.Bool value);
    decode = (fun stmt index -> Sqlite.column_int stmt index <> 0);
    sql_type = "INTEGER";
  }

let nullable typ =
  {
    value = (fun v -> match v with None -> Value.Null | Some x -> typ.value x);
    decode =
      (fun stmt index ->
        if Sqlite.column_is_null stmt index then None else Some (typ.decode stmt index));
    sql_type = typ.sql_type;
  }

let sqlite_result = function
  | Ok value -> Ok value
  | Result.Error err -> Result.Error (Sqlite err)

let check_sqlite db ~operation rc =
  match Sqlite.check db ~operation rc with
  | Ok () -> Ok ()
  | Result.Error err -> Result.Error (Sqlite err)

let unexpected_sqlite_step ~operation rc =
  Result.Error
    (Sqlite
       {
         Sqlite.operation;
         code = rc;
         message =
           "unexpected SQLite step result " ^ Sqlite.rc_name rc
           ^ " in " ^ operation;
       })

let finalize_result db stmt result =
  let finalize_rc = Sqlite.finalize stmt in
  match result with
  | Result.Error _ -> result
  | Ok _ -> (
      match check_sqlite db ~operation:"finalize" finalize_rc with
      | Ok () -> result
      | Result.Error _ as err -> err)

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
