let escape_json s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b
            (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let string_field name value =
  Printf.sprintf "\"%s\":\"%s\"" name (escape_json value)

let int_field name value = Printf.sprintf "\"%s\":%d" name value

let headers_json headers =
  headers
  |> Redaction.headers
  |> List.map (fun (name, value) ->
         Printf.sprintf "{%s,%s}" (string_field "name" name)
           (string_field "value" value))
  |> String.concat ","
  |> Printf.sprintf "[%s]"

let to_json t =
  let base =
    [
      string_field "method" t.Error.context.method_;
      string_field "uri" (Redaction.uri t.context.uri);
      string_field "protocol" (Error.protocol_to_string t.context.protocol);
      string_field "kind" (Error.kind_name t.kind);
      string_field "layer" (Error.layer_to_string (Error.layer t));
      string_field "retryability"
        (Error.retryability_to_string (Error.retryability t));
      string_field "error_class" (Error.error_class t);
      string_field "body" "<omitted>";
    ]
  in
  let with_status =
    match Error.status t with
    | None -> base
    | Some status ->
        int_field "status" status
        :: string_field "status_class"
             (Option.value ~default:"none" (Error.status_class t))
        :: base
  in
  let fields =
    match Error.headers t with
    | [] -> with_status
    | headers -> Printf.sprintf "\"headers\":%s" (headers_json headers) :: with_status
  in
  "{" ^ String.concat "," (List.rev fields) ^ "}"
