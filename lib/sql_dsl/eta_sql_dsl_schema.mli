module type BACKEND = sig
  type 'a typ

  val module_name : string
  val sql_type : 'a typ -> string
  val literal : 'a typ -> 'a -> string
end

module Make
    (Backend : BACKEND)
    (Model : sig
      type 'table table = {
        table_name : string;
        quoted_table_name : string;
        from_sql : string;
        column_qualifier : string;
      }

      type ('table, 'a) column = {
        table_name : string;
        column_name : string;
        typ : 'a Backend.typ;
        quoted_column_name : string;
        qualified_column_name : string;
      }

      type compiled_schema

      val quote_ident : string -> string
      val compiled_schema : string -> compiled_schema
    end) : sig
  type reference
  type column_def
  type t

  val references :
    ?on_delete:string -> ?on_update:string -> (_, _) Model.column -> reference

  val column :
    ?primary_key:bool ->
    ?not_null:bool ->
    ?unique:bool ->
    ?default:'a ->
    ?references:reference ->
    (_, 'a) Model.column ->
    column_def

  val create_table : ?if_not_exists:bool -> 'table Model.table -> column_def list -> t
  val drop_table : ?if_exists:bool -> 'table Model.table -> t

  val create_index :
    ?unique:bool ->
    ?if_not_exists:bool ->
    name:string ->
    'table Model.table ->
    (_, _) Model.column list ->
    t

  val to_sql : t -> string
  val compile : t -> Model.compiled_schema
end
