module type BACKEND = sig
  type value
  type row

  type 'a typ = {
    value : 'a -> value;
    decode : row -> int -> 'a;
    sql_type : string;
  }

  val module_name : string
  val value_to_sql_literal : value -> string
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
    end) =
struct
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

  let reference_action label action =
    let normalized = String.uppercase_ascii (String.trim action) in
    match normalized with
    | "CASCADE" | "RESTRICT" | "SET NULL" | "SET DEFAULT" | "NO ACTION" ->
        normalized
    | _ ->
        invalid_arg
          (Backend.module_name ^ ".Eta_schema.references: invalid " ^ label)

  let references ?on_delete ?on_update (column : (_, _) Model.column) =
    {
      table_name = column.table_name;
      column_name = Some column.column_name;
      on_delete = Option.map (reference_action "on_delete") on_delete;
      on_update = Option.map (reference_action "on_update") on_update;
    }

  let column ?(primary_key = false) ?(not_null = false) ?(unique = false)
      ?default ?references (column : (_, _) Model.column) =
    {
      name = column.column_name;
      sql_type = column.typ.sql_type;
      primary_key;
      not_null;
      unique;
      default =
        Option.map
          (fun value -> Backend.value_to_sql_literal (column.typ.value value))
          default;
      references;
    }

  let create_table ?(if_not_exists = false) (table : _ Model.table) columns =
    if columns = [] then
      invalid_arg
        (Backend.module_name ^ ".Eta_schema.create_table: columns must not be empty");
    Create_table { if_not_exists; table = table.table_name; columns }

  let drop_table ?(if_exists = false) (table : _ Model.table) =
    Drop_table { if_exists; table = table.table_name }

  let create_index ?(unique = false) ?(if_not_exists = false) ~name
      (table : _ Model.table) columns =
    if columns = [] then
      invalid_arg
        (Backend.module_name ^ ".Eta_schema.create_index: columns must not be empty");
    Create_index
      {
        unique;
        if_not_exists;
        name;
        table = table.table_name;
        columns =
          List.map (fun (column : (_, _) Model.column) -> column.column_name) columns;
      }

  let reference_sql reference =
    let buf = Buffer.create 48 in
    Buffer.add_string buf " REFERENCES ";
    Buffer.add_string buf (Model.quote_ident reference.table_name);
    (match reference.column_name with
     | None -> ()
     | Some column ->
         Buffer.add_string buf " (";
         Buffer.add_string buf (Model.quote_ident column);
         Buffer.add_char buf ')');
    (match reference.on_delete with
     | None -> ()
     | Some action -> Buffer.add_string buf " ON DELETE "; Buffer.add_string buf action);
    (match reference.on_update with
     | None -> ()
     | Some action -> Buffer.add_string buf " ON UPDATE "; Buffer.add_string buf action);
    Buffer.contents buf

  let column_sql def =
    let buf = Buffer.create 64 in
    Buffer.add_string buf (Model.quote_ident def.name);
    Buffer.add_char buf ' ';
    Buffer.add_string buf def.sql_type;
    if def.primary_key then Buffer.add_string buf " PRIMARY KEY";
    if def.not_null then Buffer.add_string buf " NOT NULL";
    if def.unique then Buffer.add_string buf " UNIQUE";
    (match def.default with
     | None -> ()
     | Some value -> Buffer.add_string buf " DEFAULT "; Buffer.add_string buf value);
    (match def.references with
     | None -> ()
     | Some ref -> Buffer.add_string buf (reference_sql ref));
    Buffer.contents buf

  let to_sql = function
    | Create_table { if_not_exists; table; columns } ->
        let buf = Buffer.create 128 in
        Buffer.add_string buf "CREATE TABLE ";
        if if_not_exists then Buffer.add_string buf "IF NOT EXISTS ";
        Buffer.add_string buf (Model.quote_ident table);
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
        Buffer.add_string buf (Model.quote_ident table);
        Buffer.contents buf
    | Create_index { unique; if_not_exists; name; table; columns } ->
        let buf = Buffer.create 64 in
        Buffer.add_string buf "CREATE ";
        if unique then Buffer.add_string buf "UNIQUE ";
        Buffer.add_string buf "INDEX ";
        if if_not_exists then Buffer.add_string buf "IF NOT EXISTS ";
        Buffer.add_string buf (Model.quote_ident name);
        Buffer.add_string buf " ON ";
        Buffer.add_string buf (Model.quote_ident table);
        Buffer.add_string buf " (";
        List.iteri
          (fun i col ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf (Model.quote_ident col))
          columns;
        Buffer.add_char buf ')';
        Buffer.contents buf

  let compile schema = Model.compiled_schema (to_sql schema)
end
