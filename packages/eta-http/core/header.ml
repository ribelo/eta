(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = (string * string) list

let empty = []
let add name value headers = (name, value) :: headers
let of_list headers = headers
let to_list headers = headers
let normalize_name name = String.lowercase_ascii (String.trim name)

let get_all name headers =
  let normalized = normalize_name name in
  headers
  |> List.filter_map (fun (candidate, value) ->
         if String.equal (normalize_name candidate) normalized then Some value
         else None)

let get name headers = match get_all name headers with [] -> None | value :: _ -> Some value

let remove name headers =
  let normalized = normalize_name name in
  List.filter
    (fun (candidate, _) -> not (String.equal (normalize_name candidate) normalized))
    headers
