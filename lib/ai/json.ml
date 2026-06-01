type t = Yojson.Safe.t

let parse raw =
  try Stdlib.Ok (Yojson.Safe.from_string raw) with
  | Yojson.Json_error message -> Stdlib.Error message

let to_string json = Yojson.Safe.to_string json
let compact = to_string
let string value = `String value
let bool value = `Bool value
let int value = `Int value

let float value =
  if classify_float value = FP_nan || classify_float value = FP_infinite
  then None
  else Some (`Float value)

let array values = `List values

let object_ fields =
  fields
  |> List.filter_map (fun (name, value) ->
         Option.map (fun value -> (name, value)) value)
  |> fun fields -> `Assoc fields

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match member name json with Some (`String value) -> Some value | _ -> None

let scalar_string_member name json =
  match member name json with
  | Some (`String value) -> Some value
  | Some (`Int value) -> Some (string_of_int value)
  | Some (`Intlit value) -> Some value
  | Some (`Float value) -> Some (Printf.sprintf "%.17g" value)
  | Some (`Bool value) -> Some (string_of_bool value)
  | _ -> None

let int_member name json =
  match member name json with
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> int_of_string_opt value
  | Some (`Float value) when Float.is_integer value ->
      let int_value = int_of_float value in
      if Float.equal (float_of_int int_value) value then Some int_value else None
  | Some (`Float _) -> None
  | _ -> None

let array_member name json =
  match member name json with Some (`List values) -> Some values | _ -> None

let object_member name json =
  match member name json with Some (`Assoc _ as value) -> Some value | _ -> None
