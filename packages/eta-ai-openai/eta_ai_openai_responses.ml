module A = Eta_ai
module Common = Eta_ai_openai_common
module Codec = Eta_ai_openai_codec
module Json = Common.Json

let encode ?structured_output (request : A.chat_request) =
  let temperature =
    match request.temperature with
    | None -> Stdlib.Ok None
    | Some value -> (
        match Json.float value with
        | Some encoded -> Stdlib.Ok (Some encoded)
        | None ->
            Stdlib.Error
              (A.Unsupported
                 { provider = "openai"; feature = "non-finite temperature" }))
  in
  match temperature with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok temperature -> (
      match
        Codec.result_all
          (List.map
             (Codec.tool_json ~schema_value:Common.schema_value
                ~shape:Codec.Responses_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools -> (
          match
            Option.fold ~none:(Stdlib.Ok None)
              ~some:(fun output ->
                Codec.structured_output_json
                  ~schema_value:Common.schema_value
                  ~shape:Codec.Responses_format output
                |> Result.map (fun format ->
                       Some (Json.object_ [ ("format", Some format) ])))
              structured_output
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok text_format ->
              Stdlib.Ok
                (Json.to_string
                   (Json.object_
                      [
                        ("model", Some (Json.string request.model));
                        ( "input",
                          Some
                            (request.prompt |> List.concat_map Codec.input_items
                           |> Json.array) );
                        ("stream", Some (Json.bool request.stream));
                        ("temperature", temperature);
                        ( "max_output_tokens",
                          Option.map Json.int request.max_output_tokens );
                        ( "tools",
                          if tools = [] then None else Some (Json.array tools) );
                        ("text", text_format);
                      ]))))

let output_text item =
  match Json.string_member "type" item with
  | Some "message" | None ->
      Json.array_member "content" item |> Option.value ~default:[]
      |> List.filter_map (fun part ->
             match Json.string_member "text" part with
             | Some text -> Some text
             | None -> Json.string_member "content" part)
  | Some "output_text" -> (
      match Json.string_member "text" item with
      | Some text -> [ text ]
      | None -> [])
  | Some _ -> []

let tool_call item =
  match Json.string_member "type" item with
  | Some "function_call" ->
      let id =
        match Json.string_member "call_id" item with
        | Some _ as value -> value
        | None -> Json.string_member "id" item
      in
      let arguments =
        match Json.member "arguments" item with
        | Some (`String arguments) -> Some arguments
        | Some json -> Some (Json.compact json)
        | None -> None
      in
      (match (Json.string_member "name" item, arguments) with
      | Some name, Some arguments_json ->
          Some
            {
              A.id = Option.value ~default:"" id;
              name;
              arguments_json;
            }
      | _ -> None)
  | _ -> None

let status_finish json =
  match Json.string_member "status" json with
  | Some "completed" -> [ A.Stop ]
  | Some "incomplete" -> [ A.Length ]
  | Some status -> [ A.Other status ]
  | None -> []

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      let output = Json.array_member "output" json |> Option.value ~default:[] in
      let text = output |> List.concat_map output_text |> String.concat "" in
      let tool_calls = output |> List.filter_map tool_call in
      Stdlib.Ok
        {
          A.id = Json.string_member "id" json;
          model = Json.string_member "model" json;
          message =
            A.Assistant
              {
                content = (if String.equal text "" then [] else [ A.Text text ]);
                tool_calls;
              };
          finish_reasons = status_finish json;
          usage = Option.map Common.usage (Json.object_member "usage" json);
          raw = Some raw;
        }
