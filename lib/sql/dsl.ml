module Backend = struct
  type value = Value.t
  type row = Sqlite.stmt
  type nonrec error = Types.error

  exception Error = Types.Error

  type nonrec 'a typ = 'a Types.typ = {
    value : ('a -> value) @@ many;
    decode : (row -> int -> 'a) @@ many;
    sql_type : string;
  }

  let int = Types.int
  let int64 = Types.int64
  let bool = Types.bool
  let float = Types.float
  let text = Types.text
  let nullable = Types.nullable
  let invalid_query message = Types.Invalid_query message
  let module_name = "Eta_sql"
  let value_to_string = Value.to_string

  let quote_text = Eta_sql_dsl.quote_text
  let quote_blob = Eta_sql_dsl.quote_blob

  let value_to_sql_literal = function
    | Value.Null -> "NULL"
    | Value.Int value -> string_of_int value
    | Value.Int64 value -> Int64.to_string value
    | Value.Float value -> string_of_float value
    | Value.String value -> quote_text value
    | Value.Bool true -> "1"
    | Value.Bool false -> "0"
    | Value.Bytes value -> quote_blob value
end

include Eta_sql_dsl.Make (Backend)
