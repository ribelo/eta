(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = (string * Value.t) list

let get field row = List.assoc_opt field row
let fields row = List.map fst row

let int field row =
  match get field row with
  | Some (Value.Int value) -> Some value
  | Some (Int64 value) ->
      let min = Int64.of_int min_int in
      let max = Int64.of_int max_int in
      if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
        Some (Int64.to_int value)
      else
        None
  | _ -> None

let int64 field row =
  match get field row with
  | Some (Value.Int value) -> Some (Int64.of_int value)
  | Some (Int64 value) -> Some value
  | _ -> None

let string field row =
  match get field row with
  | Some (Value.String value | Decimal value | Date value | Time value
         | Timestamp value | Uuid value | Json value | Enum value) -> Some value
  | _ -> None

let bool field row = match get field row with Some (Value.Bool value) -> Some value | _ -> None
let float field row = match get field row with Some (Value.Float value) -> Some value | _ -> None
let bytes field row = match get field row with Some (Value.Bytes value) -> Some value | _ -> None
