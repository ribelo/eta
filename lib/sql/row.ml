type t = (string * Value.t) list

let get field row =
  let rec loop = function
    | [] -> None
    | (name, value) :: rest ->
        if String.equal name field then Some value else loop rest
  in
  loop row

let fields row = List.map fst row
let int field row = Option.bind (get field row) Value.to_int
let int64 field row = Option.bind (get field row) Value.to_int64
let string field row = Option.bind (get field row) Value.to_string_value
let bool field row = Option.bind (get field row) Value.to_bool
let float field row = Option.bind (get field row) Value.to_float
let bytes field row = Option.bind (get field row) Value.to_bytes

let to_string row =
  row
  |> List.map (fun (field, value) -> field ^ "=" ^ Value.to_string value)
  |> String.concat ", "

let equal left right =
  List.length left = List.length right
  && List.for_all2
       (fun (left_field, left_value) (right_field, right_value) ->
         String.equal left_field right_field && Value.equal left_value right_value)
       left right