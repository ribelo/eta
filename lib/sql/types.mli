type error : immutable_data =
  | Sqlite of Sqlite.error
  | Pool_error of string
  | Invalid_query of string
  | Decode_error of {
      operation : string;
      message : string;
    }

val pp_error : Format.formatter -> error -> unit
val show_error : error -> string

type sql_error = error

exception Error of error

val raise_error : error -> 'a

type 'a typ = {
  value : ('a -> Value.t) @@ many;
  decode : (Sqlite.stmt -> int -> 'a) @@ many;
  sql_type : string;
}

val int : int typ
val int64 : int64 typ
val text : string typ
val float : float typ
val blob : bytes typ
val bool : bool typ
val nullable : 'a typ -> 'a option typ

val sqlite_result : ('a, Sqlite.error) result -> ('a, error) result
val check_sqlite : Sqlite.db -> operation:string -> Sqlite.rc -> (unit, error) result
val unexpected_sqlite_step : operation:string -> Sqlite.rc -> ('a, error) result
val finalize_result : Sqlite.db -> Sqlite.stmt -> ('a, error) result -> ('a, error) result
val bind_value : Sqlite.stmt -> int -> Value.t -> Sqlite.rc
val bind_dynamic_values : Sqlite.db -> Sqlite.stmt -> Value.t list -> (unit, error) result
val with_dynamic_statement :
  Sqlite.db ->
  string ->
  Value.t list ->
  (Sqlite.stmt -> ('a, error) result) ->
  ('a, error) result
val read_dynamic_value : Sqlite.stmt -> int -> Value.t
val materialize_row : Sqlite.stmt -> Row.t
