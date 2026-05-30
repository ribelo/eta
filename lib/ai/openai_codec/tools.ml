module A = Eta_ai
module Json = A.Json

open Core

type tool_shape =
  | Chat_tool
  | Responses_tool

let tool_json ~schema_value ~shape (tool : A.tool) =
  match
    schema_value
      ("tool " ^ tool.name ^ " input_schema_json")
      tool.input_schema_json
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok schema ->
      let function_fields =
        [
          ("name", Some (Json.string tool.name));
          ("description", Option.map Json.string tool.description);
          ("parameters", Some schema);
          ("strict", Option.map Json.bool tool.strict);
        ]
      in
      let json =
        match shape with
        | Chat_tool ->
            Json.object_
              [
                ("type", Some (Json.string "function"));
                ("function", Some (Json.object_ function_fields));
              ]
        | Responses_tool ->
            Json.object_
              [
                ("type", Some (Json.string "function"));
                ("name", Some (Json.string tool.name));
                ("description", Option.map Json.string tool.description);
                ("parameters", Some schema);
                ("strict", Option.map Json.bool tool.strict);
              ]
      in
      Stdlib.Ok json

type structured_output_shape =
  | Chat_response_format
  | Responses_format

let structured_output_json ~shape output =
  match shape with
  | Chat_response_format ->
      Json.object_
        [
          ("type", Some (Json.string "json_schema"));
          ( "json_schema",
            Some
              (Json.object_
                 [
                   ("name", Some (Json.string output.name));
                   ("schema", Some output.schema);
                   ("strict", Option.map Json.bool output.strict);
                 ]) );
        ]
  | Responses_format ->
      Json.object_
        [
          ("type", Some (Json.string "json_schema"));
          ("name", Some (Json.string output.name));
          ("schema", Some output.schema);
          ("strict", Option.map Json.bool output.strict);
        ]


