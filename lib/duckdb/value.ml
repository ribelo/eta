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
