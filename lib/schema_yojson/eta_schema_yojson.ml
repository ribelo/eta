type external_json = Yojson.Safe.t

let rec of_yojson = function
  | `Null -> Ok Eta_schema.Json.Null
  | `Bool value -> Ok (Eta_schema.Json.bool value)
  | `Int value -> Ok (Eta_schema.Json.int value)
  | `Intlit value -> Ok (Eta_schema.Json.intlit value)
  | `Float value when Float.is_finite value ->
      Ok (Eta_schema.Json.number value)
  | `Float _ -> Error [ Eta_schema.issue "JSON number must be finite" ]
  | `String value -> Ok (Eta_schema.Json.string value)
  | `List values ->
      map_values (fun values -> Eta_schema.Json.array values) [] values
  | `Assoc fields -> map_fields [] fields
  | `Tuple _ | `Variant _ ->
      Error [ Eta_schema.issue "unsupported non-standard JSON value" ]

and map_values make reversed = function
  | [] -> Ok (make (List.rev reversed))
  | value :: rest -> (
      match of_yojson value with
      | Ok value -> map_values make (value :: reversed) rest
      | Error _ as error -> error)

and map_fields reversed = function
  | [] -> Ok (Eta_schema.Json.object_ (List.rev reversed))
  | (name, value) :: rest -> (
      match of_yojson value with
      | Ok value -> map_fields ((name, value) :: reversed) rest
      | Error _ as error -> error)

let rec to_yojson = function
  | Eta_schema.Json.Null -> `Null
  | Bool value -> `Bool value
  | Number (Int value) -> `Int value
  | Number (Intlit value) -> `Intlit value
  | Number (Float value) -> `Float value
  | String value -> `String value
  | Array values -> `List (List.map to_yojson values)
  | Object fields ->
      `Assoc (List.map (fun (name, value) -> (name, to_yojson value)) fields)

include Eta_schema.Make (struct
  type nonrec external_json = external_json

  let of_external = of_yojson
  let to_external = to_yojson
end)
