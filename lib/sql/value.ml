type t =
  | Null
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bool of bool
  | Bytes of bytes

let null = Null
let int value = Int value
let int64 value = Int64 value
let float value = Float value
let string value = String value
let bool value = Bool value
let bytes value = Bytes value

let int64_to_int_opt value =
  let min = Int64.of_int min_int in
  let max = Int64.of_int max_int in
  if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
    Some (Int64.to_int value)
  else
    None

let to_int = function
  | Int value -> Some value
  | Int64 value -> int64_to_int_opt value
  | _ -> None

let to_int64 = function
  | Int value -> Some (Int64.of_int value)
  | Int64 value -> Some value
  | _ -> None

let to_float = function
  | Float value -> Some value
  | _ -> None

let to_string_value = function
  | String value -> Some value
  | _ -> None

let to_bool = function
  | Bool value -> Some value
  | Int 0 -> Some false
  | Int 1 -> Some true
  | Int64 0L -> Some false
  | Int64 1L -> Some true
  | _ -> None

let to_bytes = function
  | Bytes value -> Some value
  | _ -> None

let is_null = function
  | Null -> true
  | _ -> false

let to_string = function
  | Null -> "NULL"
  | Int value -> string_of_int value
  | Int64 value -> Int64.to_string value
  | Float value -> string_of_float value
  | String value -> value
  | Bool true -> "true"
  | Bool false -> "false"
  | Bytes value -> Bytes.to_string value

let compare = Stdlib.compare
let equal left right = compare left right = 0