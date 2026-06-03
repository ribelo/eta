module A = Eta_ai
module Json = A.Json

open Core
open Content
open Tools

let encode_responses_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  let* temperature = temperature_json ~provider request.temperature in
  let* tools =
    request.tools
    |> List.map (tool_json ~schema_value ~shape:Responses_tool)
    |> result_all
  in
  let* input =
    request.prompt |> List.map (input_items ~provider) |> result_all
  in
  let text_format =
    structured_output
    |> Option.map (fun output ->
           let format = structured_output_json ~shape:Responses_format output in
           Json.object_ [ ("format", Some format) ])
  in
  Stdlib.Ok
    (Json.object_
       [
         ("model", Some (Json.string request.model));
         ("input", Some (Json.array (List.concat input)));
         ("stream", Some (Json.bool request.stream));
         ("temperature", temperature);
         ("max_output_tokens", Option.map Json.int request.max_output_tokens);
         ("tools", if tools = [] then None else Some (Json.array tools));
         ("text", text_format);
       ])

let encode_responses ~provider ~schema_value ?structured_output request =
  encode_responses_json ~provider ~schema_value ?structured_output request
  |> Result.map Json.to_string

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

let responses_tool_call item =
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
          Some { A.id = Option.value ~default:"" id; name; arguments_json }
      | _ -> None)
  | _ -> None

let status_finish json =
  match Json.string_member "status" json with
  | Some "completed" -> [ A.Stop ]
  | Some "incomplete" -> [ A.Length ]
  | Some status -> [ A.Other status ]
  | None -> []

let decode_responses ~provider raw =
  let* json = parse_json ~provider raw in
  match Json.string_member "status" json with
  | Some "failed" ->
      Stdlib.Error (Error_codec.provider_error_json ~raw ~provider json)
  | _ ->
      let output = Json.array_member "output" json |> Option.value ~default:[] in
      let text = output |> List.concat_map output_text |> String.concat "" in
      let tool_calls = output |> List.filter_map responses_tool_call in
      Stdlib.Ok
        {
          A.id = Json.string_member "id" json;
          model = Json.string_member "model" json;
          message =
            A.Assistant
              {
                content =
                  (if String.equal text "" then [] else [ A.Text text ]);
                tool_calls;
              };
          finish_reasons = status_finish json;
          usage = Option.map usage (Json.object_member "usage" json);
          raw = Some raw;
        }
