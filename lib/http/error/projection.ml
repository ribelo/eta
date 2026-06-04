(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

let string_field name value = (name, `String value)
let int_field name value = (name, `Int value)

let array_map (f @ many) values =
  let rec loop acc = function
    | [] -> `List (List.rev acc)
    | value :: rest -> loop (f value :: acc) rest
  in
  loop [] values

let header_json (name, value) =
  `Assoc [ string_field "name" name; string_field "value" value ]

let redacted_header_json (name, value) =
  let value = if Redaction.is_sensitive name then "<redacted>" else value in
  header_json (name, value)

let to_json t =
  let fields =
    [
      string_field "method" t.Error.context.method_;
      string_field "uri" (Redaction.uri t.context.uri);
      string_field "protocol" (Error.protocol_to_string t.context.protocol);
      string_field "kind" (Error.kind_name t.kind);
      string_field "layer" (Error.layer_to_string (Error.layer t));
      string_field "retryability" (Error.retryability_to_string (Error.retryability t));
      string_field "error_class" (Error.error_class t);
      string_field "body" "<omitted>";
    ]
  in
  let fields =
    match Error.status t with
    | None -> fields
    | Some status ->
        int_field "status" status
        :: string_field "status_class"
             (Option.value ~default:"none" (Error.status_class t))
        :: fields
  in
  let fields =
    match Error.headers t with
    | [] -> fields
    | headers ->
        ("headers", array_map redacted_header_json headers) :: fields
  in
  Yojson.Safe.to_string (`Assoc (List.rev fields))
