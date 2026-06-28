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
    | Struct of (string * t) list
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
  let struct_ name fields = (name, Value.Struct fields)
  let rows name rows = list name (List.map (fun fields -> Value.Struct fields) rows)
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

  let map (f) decode row = Result.map f (decode row)

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
