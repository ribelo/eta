module A = Eta_ai
module Json = A.Json

open Core
open Content
open Tools

let encode_chat_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  match temperature_json ~provider request.temperature with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok temperature -> (
      match
        result_all
          (List.map
             (tool_json ~schema_value ~shape:Chat_tool)
             request.tools)
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tools ->
          match result_all (List.map (chat_message_json ~provider) request.prompt) with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok messages ->
              let response_format =
                structured_output
                |> Option.map
                     (structured_output_json ~shape:Chat_response_format)
              in
              Stdlib.Ok
                (Json.object_
                   [
                     ("model", Some (Json.string request.model));
                     ("messages", Some (Json.array messages));
                     ("stream", Some (Json.bool request.stream));
                     ("temperature", temperature);
                     ("max_tokens", Option.map Json.int request.max_output_tokens);
                     ("tools", if tools = [] then None else Some (Json.array tools));
                     ("response_format", response_format);
                   ]))

let encode_chat ~provider ~schema_value ?structured_output request =
  match encode_chat_json ~provider ~schema_value ?structured_output request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let chat_tool_call json =
  let function_json = Json.object_member "function" json in
  let name =
    match function_json with
    | Some fn -> Json.string_member "name" fn
    | None -> Json.string_member "name" json
  in
  let arguments =
    match function_json with
    | Some fn -> Json.member "arguments" fn
    | None -> Json.member "arguments" json
  in
  match (Json.string_member "id" json, name, arguments) with
  | id, Some name, Some arguments ->
      Some
        {
          A.id = Option.value ~default:"" id;
          name;
          arguments_json = raw_json arguments;
        }
  | _ -> None

let assistant_message message_json =
  let content =
    match Json.string_member "content" message_json with
    | Some "" | None -> []
    | Some text -> [ A.Text text ]
  in
  let tool_calls =
    Json.array_member "tool_calls" message_json
    |> Option.value ~default:[] |> List.filter_map chat_tool_call
  in
  A.Assistant { content; tool_calls }

let decode_chat ?(usage_raw_prompt_names = false) ~provider raw =
  match parse_json ~provider raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "choices" json with
      | Some (choice :: _ as choices) -> (
          match Json.object_member "message" choice with
          | Some message_json ->
              let finish_reasons =
                choices
                |> List.filter_map (Json.string_member "finish_reason")
                |> List.map finish_reason
              in
              Stdlib.Ok
                {
                  A.id = Json.string_member "id" json;
                  model = Json.string_member "model" json;
                  message = assistant_message message_json;
                  finish_reasons;
                  usage =
                    Option.map
                      (usage ~raw_prompt_names:usage_raw_prompt_names)
                      (Json.object_member "usage" json);
                  raw = Some raw;
                }
          | None ->
              decode_error_result ~provider ~raw
                "chat completion choice missing message")
      | _ ->
          decode_error_result ~provider ~raw "chat completion missing choices")

