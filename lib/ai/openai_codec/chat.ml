module A = Eta_ai
module Json = A.Json

open Core
open Content
open Tools

let encode_chat_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  let* () =
    match request.reasoning with
    | None -> Stdlib.Ok ()
    | Some _ -> unsupported ~provider "reasoning with Chat Completions"
  in
  let* () =
    if request.replay_items = [] then Stdlib.Ok ()
    else unsupported ~provider "provider replay items with Chat Completions"
  in
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

let thinking_json = function
  | Off -> Json.object_ [ ("type", Some (Json.string "disabled")) ]
  | Minimal | Low | Medium | High | Xhigh | Max ->
      Json.object_ [ ("type", Some (Json.string "enabled")) ]

let encode_chat_with_thinking_json ~provider ~schema_value ?structured_output
    (request : A.chat_request) =
  let* reasoning =
    match request.reasoning with
    | None -> Stdlib.Ok None
    | Some value ->
        reasoning_level_of_string ~provider value |> Result.map Option.some
  in
  let request = { request with reasoning = None } in
  let* json =
    encode_chat_json ~provider ~schema_value ?structured_output request
  in
  match json with
  | `Assoc fields ->
      let thinking =
        match reasoning with
        | None -> []
        | Some level -> [ ("thinking", thinking_json level) ]
      in
      Stdlib.Ok (`Assoc (fields @ thinking))
  | _ -> assert false

let encode_chat_with_thinking ~provider ~schema_value ?structured_output request =
  encode_chat_with_thinking_json ~provider ~schema_value ?structured_output
    request
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

let decode_chat ?(usage_raw_prompt_names = true) ~provider raw =
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
              replay_items = [];
              raw = Some raw;
            }
      | None ->
          decode_error_result ~provider ~raw
            "chat completion choice missing message")
  | _ -> decode_error_result ~provider ~raw "chat completion missing choices"
