module A = Eta_ai
module Json = A.Json

type structured_output = {
  name : string;
  schema_json : A.raw_json;
  strict : bool option;
}

let structured_output ~schema_value ?strict ~name ~schema_json () =
  let trimmed = String.trim name in
  if String.equal trimmed "" then
    Stdlib.Error
      (A.Invalid_tool { name; message = "structured output name is required" })
  else
    match schema_value "structured output schema_json" schema_json with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok _ -> Stdlib.Ok { name = trimmed; schema_json; strict }

let content_text = function A.Text text -> text | A.Json raw -> raw

let contents_text contents = contents |> List.map content_text |> String.concat ""

let message_item role contents =
  Json.object_
    [
      ("role", Some (Json.string role));
      ("content", Some (Json.string (contents_text contents)));
    ]

let function_call_item (call : A.tool_call) =
  Json.object_
    [
      ("type", Some (Json.string "function_call"));
      ("call_id", Some (Json.string call.id));
      ("name", Some (Json.string call.name));
      ("arguments", Some (Json.string call.arguments_json));
    ]

let input_items = function
  | A.System text -> [ message_item "system" [ A.Text text ] ]
  | A.User contents -> [ message_item "user" contents ]
  | A.Assistant { content; tool_calls } ->
      let content_item =
        if String.equal (contents_text content) "" then []
        else [ message_item "assistant" content ]
      in
      content_item @ List.map function_call_item tool_calls
  | A.Tool { tool_call_id; content } ->
      [
        Json.object_
          [
            ("type", Some (Json.string "function_call_output"));
            ("call_id", Some (Json.string tool_call_id));
            ("output", Some (Json.string (contents_text content)));
          ];
      ]

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

let structured_output_json ~schema_value ~shape output =
  match schema_value "structured output schema_json" output.schema_json with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok schema ->
      let json =
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
                         ("schema", Some schema);
                         ("strict", Option.map Json.bool output.strict);
                       ]) );
              ]
        | Responses_format ->
            Json.object_
              [
                ("type", Some (Json.string "json_schema"));
                ("name", Some (Json.string output.name));
                ("schema", Some schema);
                ("strict", Option.map Json.bool output.strict);
              ]
      in
      Stdlib.Ok json

let stream_tool_delta json =
  let index = Json.int_member "index" json in
  let id = Json.string_member "id" json in
  let function_json = Json.object_member "function" json in
  let name = Option.bind function_json (Json.string_member "name") in
  let arguments_json_delta =
    match Option.bind function_json (Json.member "arguments") with
    | Some (`String value) -> value
    | Some value -> Json.compact value
    | None -> ""
  in
  A.Stream_tool_call_delta { index; id; name; arguments_json_delta }

let chat_stream_events ~finish_reason raw json =
  let choices = Json.array_member "choices" json |> Option.value ~default:[] in
  let starts =
    choices
    |> List.filter_map (fun choice ->
           match Json.object_member "delta" choice with
           | Some delta when Json.string_member "role" delta = Some "assistant" ->
               Some
                 (A.Stream_message_start
                    {
                      id = Json.string_member "id" json;
                      model = Json.string_member "model" json;
                      raw = Some raw;
                    })
           | _ -> None)
  in
  let deltas =
    choices
    |> List.concat_map (fun choice ->
           match Json.object_member "delta" choice with
           | None -> []
           | Some delta ->
               let content =
                 match Json.string_member "content" delta with
                 | Some text -> [ A.Stream_content_delta text ]
                 | None -> []
               in
               let tool_calls =
                 Json.array_member "tool_calls" delta
                 |> Option.value ~default:[]
                 |> List.map stream_tool_delta
               in
               content @ tool_calls)
  in
  let finishes =
    choices
    |> List.filter_map (Json.string_member "finish_reason")
    |> List.map finish_reason
  in
  starts @ deltas
  @ if finishes = [] then [] else [ A.Stream_finish finishes ]

let result_all values =
  let rec loop acc = function
    | [] -> Stdlib.Ok (List.rev acc)
    | Stdlib.Ok value :: rest -> loop (value :: acc) rest
    | Stdlib.Error _ as error :: _ -> error
  in
  loop [] values
