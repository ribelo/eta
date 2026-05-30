module Backend = struct
  type value = Value.t
  type row = Sqlite.stmt
  type nonrec error = Types.error

  exception Error = Types.Error

  type nonrec 'a typ = 'a Types.typ = {
    value : 'a -> value;
    decode : row -> int -> 'a;
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

  let quote_text value =
    let len = String.length value in
    let extra_quotes = ref 0 in
    for i = 0 to len - 1 do
      if Char.equal (String.unsafe_get value i) '\'' then incr extra_quotes
    done;
    let out = Bytes.create (len + !extra_quotes + 2) in
    Bytes.unsafe_set out 0 '\'';
    let j = ref 1 in
    for i = 0 to len - 1 do
      let ch = String.unsafe_get value i in
      Bytes.unsafe_set out !j ch;
      incr j;
      if Char.equal ch '\'' then (
        Bytes.unsafe_set out !j '\'';
        incr j)
    done;
    Bytes.unsafe_set out !j '\'';
    Bytes.unsafe_to_string out

  let quote_blob value =
    let hex = "0123456789ABCDEF" in
    let len = Bytes.length value in
    let out = Bytes.create ((len * 2) + 3) in
    Bytes.unsafe_set out 0 'X';
    Bytes.unsafe_set out 1 '\'';
    for i = 0 to len - 1 do
      let byte = Char.code (Bytes.unsafe_get value i) in
      Bytes.unsafe_set out ((i * 2) + 2) (String.unsafe_get hex (byte lsr 4));
      Bytes.unsafe_set out ((i * 2) + 3) (String.unsafe_get hex (byte land 0xF))
    done;
    Bytes.unsafe_set out ((len * 2) + 2) '\'';
    Bytes.unsafe_to_string out

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
