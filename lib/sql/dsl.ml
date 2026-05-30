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
  let bool = Types.bool
  let float = Types.float
  let text = Types.text
  let invalid_query message = Types.Invalid_query message
  let module_name = "Eta_sql"
  let value_to_string = Value.to_string
end

include Eta_sql_dsl.Make (Backend)
