module Value = struct
  type node = {
    id : int64 option;
    labels : string list;
    properties : (string * t) list;
  }

  and rel = {
    id : int64 option;
    src : int64 option;
    dst : int64 option;
    label : string option;
    properties : (string * t) list;
  }

  and path = {
    nodes : node list;
    rels : rel list;
  }

  and t =
    | Null
    | Bool of bool
    | Int of int64
    | Float of float
    | String of string
    | List of t list
    | Map of (string * t) list
    | Node of node
    | Rel of rel
    | Path of path
end

module Row = struct
  type t = (string * Value.t) list

  let get field row = List.assoc_opt field row
  let fields row = List.map fst row

  let string field row =
    match get field row with
    | Some (Value.String value) -> Some value
    | _ -> None

  let int field row =
    match get field row with
    | Some (Value.Int value) -> Some value
    | _ -> None

  let bool field row =
    match get field row with
    | Some (Value.Bool value) -> Some value
    | _ -> None

  let float field row =
    match get field row with
    | Some (Value.Float value) -> Some value
    | _ -> None

  let node field row =
    match get field row with
    | Some (Value.Node value) -> Some value
    | _ -> None
end

module Param = struct
  type t = string * Value.t

  let null name = (name, Value.Null)
  let bool name value = (name, Value.Bool value)
  let int name value = (name, Value.Int value)
  let float name value = (name, Value.Float value)
  let string name value = (name, Value.String value)
  let list name values = (name, Value.List values)
  let map name fields = (name, Value.Map fields)
end

module Decode = struct
  type 'a t = Row.t -> ('a, string) result

  let run decode row = decode row

  let value field row =
    match Row.get field row with
    | Some value -> Ok value
    | None -> Result.Error ("missing field " ^ field)

  let expect field kind decode row =
    match decode field row with
    | Some value -> Ok value
    | None -> Result.Error ("expected " ^ kind ^ " field " ^ field)

  let string field = expect field "string" Row.string
  let int field = expect field "int" Row.int
  let bool field = expect field "bool" Row.bool
  let float field = expect field "float" Row.float
  let node field = expect field "node" Row.node

  let map f decode row = Result.map f (decode row)

  let tuple2 left right row =
    match left row with
    | Result.Error _ as err -> err
    | Ok left -> (
        match right row with
        | Result.Error _ as err -> err
        | Ok right -> Ok (left, right))

  let tuple3 first second third row =
    match first row with
    | Result.Error _ as err -> err
    | Ok first -> (
        match second row with
        | Result.Error _ as err -> err
        | Ok second -> (
            match third row with
            | Result.Error _ as err -> err
            | Ok third -> Ok (first, second, third)))
end

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
    | props ->
        props
        |> List.map (fun (name, param) -> name ^ ": $" ^ param)
        |> String.concat ", "
        |> fun body -> " {" ^ body ^ "}"

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
        "(" ^ name ^ labels node_labels ^ param_props props ^ ")"
    | Rel { alias; label; direction; hops = rel_hops; props } ->
        let name = Option.value alias ~default:"" in
        let label =
          match label with
          | None -> ""
          | Some label -> ":" ^ label
        in
        let body = "[" ^ name ^ label ^ hops rel_hops ^ param_props props ^ "]" in
        begin match direction with
        | Out -> "-" ^ body ^ "->"
        | In -> "<-" ^ body ^ "-"
        | Undirected -> "-" ^ body ^ "-"
        end
    | Path { alias; parts } ->
        let body = parts |> List.map to_cypher |> String.concat "" in
        begin match alias with
        | None -> body
        | Some alias -> alias ^ " = " ^ body
        end
end

module Query = struct
  type 'a t = {
    cypher : string;
    params : Param.t list;
    decode : 'a Decode.t;
  }

  type builder = {
    clauses : string list;
    params : Param.t list;
    order_by : string list;
    limit : int option;
  }

  let empty = { clauses = []; params = []; order_by = []; limit = None }
  let add clause query = { query with clauses = query.clauses @ [ clause ] }
  let with_params params query = { query with params = query.params @ params }
  let match_ pattern = empty |> add ("MATCH " ^ Pattern.to_cypher pattern)
  let optional pattern query = add ("OPTIONAL MATCH " ^ Pattern.to_cypher pattern) query
  let where expr query = add ("WHERE " ^ expr) query
  let with_ items query = add ("WITH " ^ String.concat ", " items) query
  let raw_clause clause query = add clause query

  let order_by ?(desc = false) expr query =
    let item = expr ^ if desc then " DESC" else " ASC" in
    { query with order_by = query.order_by @ [ item ] }

  let limit count query =
    if count < 0 then invalid_arg "Eta_ladybug.Query.limit: count must be non-negative";
    { query with limit = Some count }

  let returning items ~decode query =
    let clauses = query.clauses @ [ "RETURN " ^ String.concat ", " items ] in
    let clauses =
      match query.order_by with
      | [] -> clauses
      | order_by -> clauses @ [ "ORDER BY " ^ String.concat ", " order_by ]
    in
    let clauses =
      match query.limit with
      | None -> clauses
      | Some count -> clauses @ [ "LIMIT " ^ string_of_int count ]
    in
    { cypher = String.concat " " clauses; params = query.params; decode }

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
external raw_query_string : raw_connection -> string -> Param.t list -> string = "eta_ladybug_query_string"
external raw_query_values : raw_connection -> string -> Param.t list -> Row.t list = "eta_ladybug_query_values"

let lower_ascii value = String.lowercase_ascii value

let contains haystack needle =
  let haystack = lower_ascii haystack in
  let needle = lower_ascii needle in
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec loop pos =
    n_len = 0
    || (pos + n_len <= h_len && (at pos 0 || loop (pos + 1)))
  in
  loop 0

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

module Database = struct
  type t = database

  let open_ ~path =
    wrap "database open" (fun () -> { raw = raw_open path; closed = false })

  let open_memory () = open_ ~path:":memory:"

  let close (db : database) =
    if_database_open db @@ fun () ->
    db.closed <- true;
    wrap "database close" (fun () -> raw_close_database db.raw)
end

module Connection = struct
  type t = connection

  let connect database =
    if_database_open database @@ fun () ->
    wrap "connection open" (fun () ->
        { database; raw = raw_connect database.raw; closed = false })

  let close (conn : connection) =
    if_connection_open conn @@ fun () ->
    conn.closed <- true;
    wrap "connection close" (fun () -> raw_close_connection conn.raw)

  let interrupt (conn : connection) = if not conn.closed then raw_interrupt conn.raw

  let query_string ?(params = []) (conn : connection) cypher =
    if_connection_open conn @@ fun () ->
    wrap "query" (fun () -> raw_query_string conn.raw cypher params)

  let query conn query =
    if_connection_open conn @@ fun () ->
    match
      wrap "query" (fun () ->
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
        loop [] rows

  let exec ?params conn cypher = query_string ?params conn cypher |> Result.map (fun _ -> ())
end

module Pool = struct
  type raw_error = [ `Ladybug of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (connection, raw_error) Eta.Pool.t

  type nonrec error =
    | Ladybug of error
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

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Ladybug err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime database =
    Eta.Pool.create ?name ~kind:"ladybug" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime
      ~acquire:
        (blocking_result ?blocking_pool ~name:"ladybug.connect" (fun () ->
             Connection.connect database))
      ~release:(fun conn ->
        Eta.Effect.blocking ?pool:blocking_pool ~name:"ladybug.close" (fun () ->
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
    let query =
      Eta.Effect.blocking ?pool:blocking_pool ~name ~on_cancel:(fun () ->
          Connection.interrupt conn)
        f
      |> Eta.Effect.map (function
           | Ok value -> `Query_ok value
           | Result.Error err -> `Query_error err)
    in
    let timeout =
      Eta.Effect.delay timeout
        (Eta.Effect.sync (fun () -> Connection.interrupt conn)
         |> Eta.Effect.map (fun () -> `Timed_out))
    in
    Eta.Effect.race [ query; timeout ]
    |> Eta.Effect.bind (function
         | `Query_ok value -> Eta.Effect.pure value
         | `Query_error err -> Eta.Effect.fail (`Ladybug err)
         | `Timed_out -> Eta.Effect.fail `Timeout)

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

  let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
  let stats = Eta.Pool.stats
end
