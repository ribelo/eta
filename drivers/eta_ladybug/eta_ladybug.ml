module Value = Eta_ladybug_data.Value
module Row = Eta_ladybug_data.Row
module Param = Eta_ladybug_data.Param
module Decode = Eta_ladybug_data.Decode

let add_joined buffer sep = function
  | [] -> ()
  | item :: rest ->
      Buffer.add_string buffer item;
      List.iter
        (fun item ->
          Buffer.add_string buffer sep;
          Buffer.add_string buffer item)
        rest

module Expr = struct
  type operand =
    | Raw_operand of string
    | Property of string * string
    | Param of string

  type t = string

  let raw value = value
  let raw_operand value = Raw_operand value
  let property alias property = Property (alias, property)
  let param name = Param name

  let operand = function
    | Raw_operand value -> value
    | Property (alias, property) -> alias ^ "." ^ property
    | Param name -> "$" ^ name

  let binary op left right = operand left ^ " " ^ op ^ " " ^ operand right
  let eq left right = binary "=" left right
  let ne left right = binary "<>" left right
  let gt left right = binary ">" left right
  let ge left right = binary ">=" left right
  let lt left right = binary "<" left right
  let le left right = binary "<=" left right

  let join op left right = "(" ^ left ^ " " ^ op ^ " " ^ right ^ ")"
  let and_ left right = join "AND" left right
  let or_ left right = join "OR" left right
  let not_ expr = "NOT (" ^ expr ^ ")"
end

module Pattern = struct
  type direction =
    | Out
    | In
    | Undirected

  type hops =
    | One
    | Range of int option * int option

  type t =
    | Node of {
        alias : string option;
        labels : string list;
        props : (string * string) list;
      }
    | Rel of {
        alias : string option;
        label : string option;
        direction : direction;
        hops : hops;
        props : (string * string) list;
      }
    | Path of {
        alias : string option;
        parts : t list;
      }
    | Raw of string

  let node ?as_ ?(labels = []) ?(props = []) () =
    Node { alias = as_; labels; props }

  let anon_node ?labels ?props () = node ?labels ?props ()

  let rel ?as_ ?label ?(direction = Out) ?(hops = One) ?(props = []) () =
    Rel { alias = as_; label; direction; hops; props }

  let path ?as_ parts = Path { alias = as_; parts }
  let raw value = Raw value

  let param_props props =
    match props with
    | [] -> ""
    | (name, param) :: rest ->
        let buf = Buffer.create 32 in
        Buffer.add_string buf " {";
        Buffer.add_string buf name;
        Buffer.add_string buf ": $";
        Buffer.add_string buf param;
        List.iter
          (fun (name, param) ->
            Buffer.add_string buf ", ";
            Buffer.add_string buf name;
            Buffer.add_string buf ": $";
            Buffer.add_string buf param)
          rest;
        Buffer.add_char buf '}';
        Buffer.contents buf

  let labels = function
    | [] -> ""
    | labels -> ":" ^ String.concat ":" labels

  let hops = function
    | One -> ""
    | Range (None, None) -> "*"
    | Range (Some min, None) -> "*" ^ string_of_int min ^ ".."
    | Range (None, Some max) -> "*.." ^ string_of_int max
    | Range (Some min, Some max) -> "*" ^ string_of_int min ^ ".." ^ string_of_int max

  let rec to_cypher = function
    | Raw value -> value
    | Node { alias; labels = node_labels; props } ->
        let name = Option.value alias ~default:"" in
        let buf = Buffer.create 32 in
        Buffer.add_char buf '(';
        Buffer.add_string buf name;
        Buffer.add_string buf (labels node_labels);
        Buffer.add_string buf (param_props props);
        Buffer.add_char buf ')';
        Buffer.contents buf
    | Rel { alias; label; direction; hops = rel_hops; props } ->
        let name = Option.value alias ~default:"" in
        let buf = Buffer.create 32 in
        begin match direction with
        | Out | Undirected -> Buffer.add_char buf '-'
        | In -> Buffer.add_string buf "<-"
        end;
        Buffer.add_char buf '[';
        Buffer.add_string buf name;
        begin
          match label with
          | None -> ()
          | Some label ->
              Buffer.add_char buf ':';
              Buffer.add_string buf label
        end;
        Buffer.add_string buf (hops rel_hops);
        Buffer.add_string buf (param_props props);
        Buffer.add_char buf ']';
        begin match direction with
        | Out -> Buffer.add_string buf "->"
        | In | Undirected -> Buffer.add_char buf '-'
        end;
        Buffer.contents buf
    | Path { alias; parts } ->
        let buf = Buffer.create 64 in
        begin match alias with
        | None -> ()
        | Some alias ->
            Buffer.add_string buf alias;
            Buffer.add_string buf " = "
        end;
        List.iter (fun part -> Buffer.add_string buf (to_cypher part)) parts;
        Buffer.contents buf
end

module Query = struct
  type 'a t = {
    cypher : string;
    params : Param.t list;
    decode : 'a Decode.t;
  }

  type builder = {
    rev_clauses : string list;
    rev_params : Param.t list;
    rev_order_by : string list;
    limit : int option;
  }

  let empty = { rev_clauses = []; rev_params = []; rev_order_by = []; limit = None }
  let add clause query = { query with rev_clauses = clause :: query.rev_clauses }
  let with_params params query =
    { query with rev_params = List.rev_append params query.rev_params }
  let match_ pattern = empty |> add ("MATCH " ^ Pattern.to_cypher pattern)
  let optional pattern query = add ("OPTIONAL MATCH " ^ Pattern.to_cypher pattern) query
  let where expr query = add ("WHERE " ^ expr) query
  let with_ items query = add ("WITH " ^ String.concat ", " items) query
  let raw_clause clause query = add clause query

  let order_by ?(desc = false) expr query =
    let item = expr ^ if desc then " DESC" else " ASC" in
    { query with rev_order_by = item :: query.rev_order_by }

  let limit count query =
    if count < 0 then invalid_arg "Eta_ladybug.Query.limit: count must be non-negative";
    { query with limit = Some count }

  let returning items ~decode query =
    let buf = Buffer.create 128 in
    let add_clause clause =
      if Buffer.length buf > 0 then Buffer.add_char buf ' ';
      Buffer.add_string buf clause
    in
    List.iter add_clause (List.rev query.rev_clauses);
    add_clause "RETURN";
    Buffer.add_char buf ' ';
    add_joined buf ", " items;
    begin match List.rev query.rev_order_by with
    | [] -> ()
    | order_by ->
        Buffer.add_string buf " ORDER BY ";
        add_joined buf ", " order_by
    end;
    begin match query.limit with
    | None -> ()
    | Some count ->
        Buffer.add_string buf " LIMIT ";
        Buffer.add_string buf (string_of_int count)
    end;
    {
      cypher = Buffer.contents buf;
      params = List.rev query.rev_params;
      decode;
    }

  let raw ?(params = []) ~cypher ~decode () = { cypher; params; decode }
  let cypher (query : _ t) = query.cypher
  let params (query : _ t) = query.params
  let decode (query : _ t) = query.decode
end

type raw_database
type raw_connection

type database = {
  raw : raw_database;
  mutable closed : bool;
}

type connection = {
  database : database;
  raw : raw_connection;
  mutable closed : bool;
}

type error_category =
  | Query_syntax
  | Type_mismatch
  | Integrity_violation
  | Timeout_or_interrupt
  | Connection_closed_or_invalid
  | Other

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      category : error_category;
      message : string;
    }
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

external raw_available : unit -> string option = "eta_ladybug_available"
external raw_version : unit -> string = "eta_ladybug_version"
external raw_open : string -> raw_database = "eta_ladybug_open"
external raw_close_database : raw_database -> unit = "eta_ladybug_close_database"
external raw_connect : raw_database -> raw_connection = "eta_ladybug_connect"
external raw_close_connection : raw_connection -> unit = "eta_ladybug_close_connection"
external raw_interrupt : raw_connection -> unit = "eta_ladybug_interrupt"
external raw_classify_read_only : raw_connection -> string -> bool = "eta_ladybug_classify_read_only"
external raw_query_string : raw_connection -> string -> Param.t list -> string = "eta_ladybug_query_string"
external raw_query_values : raw_connection -> string -> Param.t list -> Row.t list = "eta_ladybug_query_values"

let contains = Eta.String_helpers.contains_ascii_ci

let classify_error message =
  if contains message "parser exception" then Query_syntax
  else if contains message "binder exception" then Type_mismatch
  else if contains message "duplicated primary key" then Integrity_violation
  else if contains message "interrupted" then Timeout_or_interrupt
  else if contains message "closed" || contains message "invalid connection" then
    Connection_closed_or_invalid
  else Other

let pp_category ppf = function
  | Query_syntax -> Format.pp_print_string ppf "query syntax"
  | Type_mismatch -> Format.pp_print_string ppf "type mismatch"
  | Integrity_violation -> Format.pp_print_string ppf "integrity violation"
  | Timeout_or_interrupt -> Format.pp_print_string ppf "timeout or interrupt"
  | Connection_closed_or_invalid -> Format.pp_print_string ppf "closed or invalid connection"
  | Other -> Format.pp_print_string ppf "other"

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "ladybug library unavailable: %s" message
  | Driver_error { operation; category; message } ->
      Format.fprintf ppf "%s: %a: %s" operation pp_category category message
  | Decode_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Invalid_value message -> Format.fprintf ppf "invalid LadybugDB value: %s" message
  | Closed -> Format.pp_print_string ppf "LadybugDB handle is closed"

let show_error err = Format.asprintf "%a" pp_error err
let pp_ladybug_error = pp_error

module Extension = struct
  type official = string

  type source =
    | Official
    | User
    | Static_link
    | Unknown of string

  type loaded = {
    name : string;
    source : source;
    path : string;
  }

  type available = {
    name : string;
    description : string;
  }

  let valid_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false

  let valid_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false

  let official_names =
    [
      "algo";
      "azure";
      "delta";
      "duckdb";
      "fts";
      "httpfs";
      "iceberg";
      "json";
      "llm";
      "neo4j";
      "postgres";
      "sqlite";
      "unity_catalog";
      "vector";
    ]

  let is_known_official value =
    List.exists (String.equal value) official_names

  let official value =
    let len = String.length value in
    let rec loop index =
      index = len || (valid_rest value.[index] && loop (index + 1))
    in
    if len = 0 then Result.Error (Invalid_value "extension name must not be empty")
    else if (not (valid_first value.[0])) || not (loop 1) then
      Result.Error
        (Invalid_value
           ("invalid LadybugDB official extension name: " ^ value))
    else
      let value = Eta.String_helpers.lowercase_ascii value in
      if is_known_official value then Ok value
      else
        Result.Error
          (Invalid_value
             ("unknown LadybugDB official extension name: " ^ value))

  let unsafe_official value =
    match official value with
    | Ok value -> value
    | Result.Error _ ->
        invalid_arg ("Eta_ladybug.Extension.unsafe_official: " ^ value)

  let name value = value
  let algo = unsafe_official "algo"
  let azure = unsafe_official "azure"
  let delta = unsafe_official "delta"
  let duckdb = unsafe_official "duckdb"
  let fts = unsafe_official "fts"
  let httpfs = unsafe_official "httpfs"
  let iceberg = unsafe_official "iceberg"
  let json = unsafe_official "json"
  let llm = unsafe_official "llm"
  let neo4j = unsafe_official "neo4j"
  let postgres = unsafe_official "postgres"
  let sqlite = unsafe_official "sqlite"
  let unity_catalog = unsafe_official "unity_catalog"
  let vector = unsafe_official "vector"

  let source_of_string = function
    | "OFFICIAL" -> Official
    | "USER" -> User
    | "STATIC LINK" -> Static_link
    | value -> Unknown value

  let has_nul value =
    let rec loop index =
      index < String.length value
      && (Char.equal value.[index] '\000' || loop (index + 1))
    in
    loop 0

  let string_literal ~kind value =
    if has_nul value then
      Result.Error (Invalid_value (kind ^ " must not contain NUL bytes"))
    else
      let buffer = Buffer.create (String.length value + 2) in
      Buffer.add_char buffer '\'';
      String.iter
        (function
          | '\\' -> Buffer.add_string buffer "\\\\"
          | '\'' -> Buffer.add_string buffer "\\'"
          | '\b' -> Buffer.add_string buffer "\\b"
          | '\012' -> Buffer.add_string buffer "\\f"
          | '\n' -> Buffer.add_string buffer "\\n"
          | '\r' -> Buffer.add_string buffer "\\r"
          | '\t' -> Buffer.add_string buffer "\\t"
          | char -> Buffer.add_char buffer char)
        value;
      Buffer.add_char buffer '\'';
      Ok (Buffer.contents buffer)

  let install_statement ?repo ?(force = false) extension =
    let prefix = if force then "FORCE INSTALL " else "INSTALL " in
    match repo with
    | None -> Ok (prefix ^ extension)
    | Some repo ->
        Result.map
          (fun repo -> prefix ^ extension ^ " FROM " ^ repo)
          (string_literal ~kind:"extension repository" repo)

  let update_statement extension = "UPDATE " ^ extension
  let uninstall_statement extension = "UNINSTALL " ^ extension
  let load_official_statement extension = "LOAD EXTENSION " ^ extension

  let load_path_statement ~path =
    if String.equal path "" then
      Result.Error (Invalid_value "extension path must not be empty")
    else
      Result.map
        (fun path -> "LOAD EXTENSION " ^ path)
        (string_literal ~kind:"extension path" path)

  let loaded_decode row =
    match
      Decode.(
        tuple3 (string "extension name") (string "extension source")
          (string "extension path"))
        row
    with
    | Ok (name, source, path) -> Ok { name; source = source_of_string source; path }
    | Result.Error _ as err -> err

  let available_decode row =
    match Decode.(tuple2 (string "name") (string "description")) row with
    | Ok (name, description) -> Ok { name; description }
    | Result.Error _ as err -> err

  let loaded_query =
    Query.raw
      ~cypher:"CALL SHOW_LOADED_EXTENSIONS() RETURN *"
      ~decode:loaded_decode ()

  let official_query =
    Query.raw
      ~cypher:
        "CALL SHOW_OFFICIAL_EXTENSIONS() RETURN name, description ORDER BY name"
      ~decode:available_decode ()
end

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
      | exception Failure message ->
          Result.Error
            (Driver_error
               { operation; category = classify_error message; message }))

let version () = wrap "version" raw_version
let if_database_open (db : database) f = if db.closed then Result.Error Closed else f ()

let if_connection_open (conn : connection) f =
  if conn.closed || conn.database.closed then Result.Error Closed else f ()

let validate_params params =
  let unsupported kind =
    Result.Error (Invalid_value ("LadybugDB parameters do not support " ^ kind))
  in
  let rec value = function
    | Value.Null | Value.Bool _ | Value.Int _ | Value.Float _ | Value.String _ ->
        Ok ()
    | Value.List values -> list values
    | Value.Map fields | Value.Struct fields -> fields_list fields
    | Value.Node _ -> unsupported "node values"
    | Value.Rel _ -> unsupported "relationship values"
    | Value.Path _ -> unsupported "path values"
  and list = function
    | [] -> Ok ()
    | value_ :: rest -> (
        match value value_ with
        | Ok () -> list rest
        | Result.Error _ as err -> err)
  and fields_list = function
    | [] -> Ok ()
    | (_, value_) :: rest -> (
        match value value_ with
        | Ok () -> fields_list rest
        | Result.Error _ as err -> err)
  in
  let rec loop = function
    | [] -> Ok ()
    | (_, value_) :: rest -> (
        match value value_ with
        | Ok () -> loop rest
        | Result.Error _ as err -> err)
  in
  loop params

module Database = struct
  type t = database

  let open_ ~path =
    wrap "database open" (fun () -> { raw = raw_open path; closed = false })

  let open_memory () = open_ ~path:":memory:"

  let close (db : database) =
    if_database_open db @@ fun () ->
    match wrap "database close" (fun () -> raw_close_database db.raw) with
    | Ok () ->
        db.closed <- true;
        Ok ()
    | Result.Error _ as err -> err
end

module Connection = struct
  type t = connection

  type timed_error =
    | Ladybug of error
    | Timeout

  let to_timed_error = function
    | `Ladybug err -> Ladybug err
    | `Timeout -> Timeout

  let timed_public eff = Eta.Effect.map_error to_timed_error eff

  let connect database =
    if_database_open database @@ fun () ->
    wrap "connection open" (fun () ->
        { database; raw = raw_connect database.raw; closed = false })

  let close (conn : connection) =
    if_connection_open conn @@ fun () ->
    match wrap "connection close" (fun () -> raw_close_connection conn.raw) with
    | Ok () ->
        conn.closed <- true;
        Ok ()
    | Result.Error _ as err -> err

  let interrupt (conn : connection) = if not conn.closed then raw_interrupt conn.raw

  let classify_read_only (conn : connection) cypher =
    if_connection_open conn @@ fun () ->
    wrap "prepare" (fun () -> raw_classify_read_only conn.raw cypher)

  let query_string_with_operation operation ?(params = []) (conn : connection)
      cypher =
    if_connection_open conn @@ fun () ->
    match validate_params params with
    | Result.Error _ as err -> err
    | Ok () -> wrap operation (fun () -> raw_query_string conn.raw cypher params)

  let query_string ?params conn cypher =
    query_string_with_operation "query" ?params conn cypher

  let query_rows_with_operation operation ?(params = []) (conn : connection)
      cypher =
    if_connection_open conn @@ fun () ->
    match validate_params params with
    | Result.Error _ as err -> err
    | Ok () ->
        wrap operation (fun () -> raw_query_values conn.raw cypher params)

  let query_rows ?params conn cypher =
    query_rows_with_operation "query" ?params conn cypher

  let query_with_operation operation conn query =
    if_connection_open conn @@ fun () ->
    match validate_params (Query.params query) with
    | Result.Error _ as err -> err
    | Ok () -> (
    match
      wrap operation (fun () ->
          raw_query_values conn.raw (Query.cypher query) (Query.params query))
    with
    | Result.Error _ as err -> err
    | Ok rows ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | row :: rest -> (
              match Query.decode query row with
              | Ok value -> loop (value :: acc) rest
              | Result.Error message ->
                  Result.Error (Decode_error { operation = "query decode"; message }))
        in
        loop [] rows)

  let query conn query = query_with_operation "query" conn query

  let exec_with_operation operation ?params conn cypher =
    query_string_with_operation operation ?params conn cypher
    |> Result.map (fun _ -> ())

  let exec ?params conn cypher =
    exec_with_operation "query" ?params conn cypher

  let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
    Eta_blocking.run_result_timeout ?pool:blocking_pool ~name
      ~on_cancel:(fun () -> interrupt conn)
      ~timeout ~on_timeout:`Timeout (fun () ->
        match f () with
        | Ok value -> Ok value
        | Result.Error err -> Error (`Ladybug err))

  let query_string_with_timeout ?blocking_pool ~timeout ?params conn cypher =
    timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.query"
      (fun () -> query_string ?params conn cypher)
    |> timed_public

  let query_rows_with_timeout ?blocking_pool ~timeout ?params conn cypher =
    timed_blocking_result ?blocking_pool ~timeout ~conn
      ~name:"ladybug.dynamic_query" (fun () -> query_rows ?params conn cypher)
    |> timed_public

  let query_with_timeout ?blocking_pool ~timeout conn query_ =
    timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.typed_query"
      (fun () -> query conn query_)
    |> timed_public

  let exec_with_timeout ?blocking_pool ~timeout ?params conn cypher =
    timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.exec"
      (fun () -> exec ?params conn cypher)
    |> timed_public

  let install_extension ?repo ?force conn extension =
    match Extension.install_statement ?repo ?force extension with
    | Result.Error _ as err -> err
    | Ok statement ->
        exec_with_operation "extension install" conn statement

  let update_extension conn extension =
    Extension.update_statement extension
    |> exec_with_operation "extension update" conn

  let uninstall_extension conn extension =
    Extension.uninstall_statement extension
    |> exec_with_operation "extension uninstall" conn

  let load_extension conn extension =
    Extension.load_official_statement extension
    |> exec_with_operation "extension load" conn

  let load_extension_path conn ~path =
    match Extension.load_path_statement ~path with
    | Result.Error _ as err -> err
    | Ok statement -> exec_with_operation "extension load" conn statement

  let loaded_extensions conn =
    query_with_operation "extension list loaded" conn Extension.loaded_query

  let official_extensions conn =
    query_with_operation "extension list official" conn Extension.official_query

  let begin_transaction conn = exec conn "BEGIN TRANSACTION"
  let commit conn = exec conn "COMMIT"
  let rollback conn = exec conn "ROLLBACK"

  let transaction conn f =
    match begin_transaction conn with
    | Result.Error _ as err -> err
    | Ok () -> (
        match f conn with
        | Ok value -> (
            match commit conn with
            | Ok () -> Ok value
            | Result.Error _ as err ->
                ignore (rollback conn);
                err)
        | Result.Error _ as err ->
            ignore (rollback conn);
            err
        | exception exn ->
            ignore (rollback conn);
            raise exn)
end

module Pool = struct
  type driver_error = error
  type raw_error = [ `Ladybug of driver_error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (connection, raw_error) Eta.Pool.t

  type nonrec error =
    | Ladybug of driver_error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let to_public_error = function
    | `Ladybug err -> Ladybug err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let to_raw_error = function
    | Ladybug err -> `Ladybug err
    | Pool_shutdown -> `Pool_shutdown
    | Pool_shutdown_timeout -> `Pool_shutdown_timeout
    | Timeout -> `Timeout

  let public eff = Eta.Effect.map_error to_public_error eff

  let blocking_result ?blocking_pool ?name f =
    Eta_blocking.run_result ?pool:blocking_pool ?name (fun () ->
        match f () with
        | Ok value -> Ok value
        | Result.Error err -> Error (`Ladybug err))

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime database =
    Eta.Pool.create ?name ~kind:"ladybug" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime
      ~acquire:
        (blocking_result ?blocking_pool ~name:"ladybug.connect" (fun () ->
             Connection.connect database))
      ~release:(fun conn ->
        Eta_blocking.run ?pool:blocking_pool ~name:"ladybug.close" (fun () ->
            ignore (Connection.close conn)))
      ~health_check:(fun conn ->
        blocking_result ?blocking_pool ~name:"ladybug.ping" (fun () ->
            Connection.query_string conn "RETURN 1" |> Result.map (fun _ -> ())))
      ()
    |> public

  let with_connection t f =
    Eta.Pool.with_resource t (fun conn ->
        f conn |> Eta.Effect.map_error to_raw_error)
    |> public

  let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
    Connection.timed_blocking_result ?blocking_pool ~timeout ~conn ~name f

  let query_string ?blocking_pool ~timeout ?params t cypher =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.query"
          (fun () -> Connection.query_string ?params conn cypher)
        |> public)

  let query ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.typed_query"
          (fun () -> Connection.query conn query)
        |> public)

  let with_timed_connection ?blocking_pool ~timeout ~name t f =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name (fun () ->
            f conn)
        |> public)

  let install_extension ?blocking_pool ~timeout ?repo ?force t extension =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.install"
      t
      (fun conn -> Connection.install_extension ?repo ?force conn extension)

  let update_extension ?blocking_pool ~timeout t extension =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.update"
      t
      (fun conn -> Connection.update_extension conn extension)

  let uninstall_extension ?blocking_pool ~timeout t extension =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.uninstall"
      t
      (fun conn -> Connection.uninstall_extension conn extension)

  let load_extension ?blocking_pool ~timeout t extension =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.load"
      t
      (fun conn -> Connection.load_extension conn extension)

  let load_extension_path ?blocking_pool ~timeout t ~path =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.load"
      t
      (fun conn -> Connection.load_extension_path conn ~path)

  let loaded_extensions ?blocking_pool ~timeout t =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.list_loaded"
      t Connection.loaded_extensions

  let official_extensions ?blocking_pool ~timeout t =
    with_timed_connection ?blocking_pool ~timeout ~name:"ladybug.extension.list_official"
      t Connection.official_extensions

  let transaction ?blocking_pool ~timeout t f =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.transaction"
          (fun () -> Connection.transaction conn f)
        |> public)

  let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
  let stats = Eta.Pool.stats
end
