(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bytes of bytes
  | Decimal of string
  | Date of string
  | Time of string
  | Timestamp of string
  | Uuid of string
  | Json of string
  | Enum of string
  | List of t list
  | Struct of (string * t) list

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

let to_string_value = function
  | String value | Decimal value | Date value | Time value | Timestamp value
  | Uuid value | Json value | Enum value -> Some value
  | _ -> None

let to_bool = function
  | Bool value -> Some value
  | _ -> None

let to_float = function
  | Float value -> Some value
  | _ -> None

let to_bytes = function
  | Bytes value -> Some value
  | _ -> None

let rec to_string = function
  | Null -> "NULL"
  | Bool true -> "true"
  | Bool false -> "false"
  | Int value -> string_of_int value
  | Int64 value -> Int64.to_string value
  | Float value -> string_of_float value
  | String value -> value
  | Bytes value -> Bytes.to_string value
  | Decimal value | Date value | Time value | Timestamp value | Uuid value
  | Json value | Enum value -> value
  | List values -> "[" ^ String.concat ", " (List.map to_string values) ^ "]"
  | Struct fields ->
      fields
      |> List.map (fun (name, value) -> name ^ "=" ^ to_string value)
      |> String.concat ", "

let compare = Stdlib.compare
let equal left right = compare left right = 0
