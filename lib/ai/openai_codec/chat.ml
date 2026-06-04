module A = Eta_ai
module Json = A.Json

open Core
open Content
open Tools

let encode_chat_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  let* temperature = temperature_json ~provider request.temperature in
  let* tools =
    result_map_all (tool_json ~schema_value ~shape:Chat_tool) request.tools
  in
  let* messages =
    result_map_all (chat_message_json ~provider) request.prompt
  in
  let response_format =
    structured_output
    |> Option.map (structured_output_json ~shape:Chat_response_format)
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
       ])

let encode_chat ~provider ~schema_value ?structured_output request =
  encode_chat_json ~provider ~schema_value ?structured_output request
  |> Result.map Json.to_string

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

let finish_reasons choices =
  let rec loop acc = function
    | [] -> List.rev acc
    | choice :: rest -> (
        match Json.string_member "finish_reason" choice with
        | None -> loop acc rest
        | Some reason -> loop (finish_reason reason :: acc) rest)
  in
  loop [] choices

let decode_chat ?(usage_raw_prompt_names = false) ~provider raw =
  let* json = parse_json ~provider raw in
  match Json.array_member "choices" json with
  | Some (choice :: _ as choices) -> (
      match Json.object_member "message" choice with
      | Some message_json ->
          Stdlib.Ok
            {
              A.id = Json.string_member "id" json;
              model = Json.string_member "model" json;
              message = assistant_message message_json;
              finish_reasons = finish_reasons choices;
              usage =
                Option.map
                  (usage ~raw_prompt_names:usage_raw_prompt_names)
                  (Json.object_member "usage" json);
              raw = Some raw;
            }
      | None ->
          decode_error_result ~provider ~raw
            "chat completion choice missing message")
  | _ -> decode_error_result ~provider ~raw "chat completion missing choices"
