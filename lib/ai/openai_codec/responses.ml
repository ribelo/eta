module A = Eta_ai
module Json = A.Json

open Core
open Content
open Tools

let optional_float_json_lossless label = function
  | None -> Stdlib.Ok None
  | Some value -> (
      match Json.float value with
      | Some encoded -> Stdlib.Ok (Some encoded)
      | None -> Stdlib.Error (Invalid_request ("non-finite " ^ label)))

let optional_float_json ~provider label value =
  optional_float_json_lossless label value |> map_codec_failure ~provider

let replay_item_lossless raw =
  match Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error (Decode { message; raw_body = Some raw })
  | Stdlib.Ok json -> (
      match Json.string_member "type" json with
      | Some "reasoning" -> Stdlib.Ok json
      | Some _ | None ->
          Stdlib.Error
            (Invalid_request "provider replay item must be a reasoning item"))

let replay_item ~provider raw =
  replay_item_lossless raw |> map_codec_failure ~provider

let response_input_items_lossless_with encode_input_items ~provider
    ~replay_items prompt =
  let* replay_items = result_map_all replay_item_lossless replay_items in
  let rec loop replay_used = function
    | [] -> Stdlib.Ok ([], replay_used)
    | message :: rest -> (
        match loop replay_used rest with
        | Stdlib.Error _ as error -> error
        | Stdlib.Ok (rest_items, replay_used) -> (
            match encode_input_items ~provider message with
            | Stdlib.Error (A.Unsupported { feature; _ }) ->
                Stdlib.Error (Unsupported feature)
            | Stdlib.Error (A.Decode_error { message; raw; _ }) ->
                Stdlib.Error (Decode { message; raw_body = raw })
            | Stdlib.Error (A.Invalid_request { message; _ }) ->
                Stdlib.Error (Invalid_request message)
            | Stdlib.Error (A.Invalid_tool { name; message }) ->
                Stdlib.Error (Invalid_tool { name; message })
            | Stdlib.Error _ ->
                Stdlib.Error
                  (Decode { message = "input item encode"; raw_body = None })
            | Stdlib.Ok items ->
                let should_replay =
                  (not replay_used)
                  && replay_items <> []
                  &&
                  match message with
                  | A.Assistant { tool_calls = _ :: _; _ } -> true
                  | A.System _ | A.User _ | A.Assistant _ | A.Tool _ -> false
                in
                let items =
                  if should_replay then replay_items @ items else items
                in
                Stdlib.Ok (items @ rest_items, replay_used || should_replay)))
  in
  match loop false prompt with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok (items, replay_used) ->
      if replay_items <> [] && not replay_used then
        Stdlib.Error
          (Invalid_request
             "provider replay items require a preceding assistant tool call")
      else Stdlib.Ok items

let response_input_items_lossless =
  response_input_items_lossless_with input_items

let openrouter_response_input_items_lossless =
  response_input_items_lossless_with openrouter_input_items

let response_input_items ~provider ~replay_items prompt =
  response_input_items_lossless ~provider ~replay_items prompt
  |> map_codec_failure ~provider

let encode_responses_json_lossless_with encode_input_items ~provider
    ~map_codec_failure ~encode_tool
    (request : _ A.Responses.request) =
  let map_failure result = Result.map_error map_codec_failure result in
  let* temperature = map_failure (temperature_json_lossless request.temperature) in
  let* top_p = map_failure (optional_float_json_lossless "top_p" request.top_p) in
  let* min_p = map_failure (optional_float_json_lossless "min_p" request.min_p) in
  let reasoning =
    request.reasoning
    |> Option.map
         (fun { A.Responses.effort; summary; generate_summary } ->
           Json.object_
             [
               ("effort", Option.map Json.string effort);
               ("summary", Option.map Json.string summary);
               ("generate_summary", Option.map Json.bool generate_summary);
             ])
  in
  let* input =
    match request.input with
    | A.Responses.Text _ when request.replay_items <> [] ->
        Stdlib.Error
          (map_codec_failure
             (Invalid_request
                "provider replay items with Responses text input"))
    | A.Responses.Text text -> Stdlib.Ok (Json.string text)
    | A.Responses.Messages prompt ->
        encode_input_items ~provider
          ~replay_items:request.replay_items prompt
        |> map_failure |> Result.map Json.array
  in
  let* tools = result_map_all encode_tool request.tools in
  let request_text =
    request.text
    |> Option.map (fun { A.Responses.format } ->
           let format =
             match format with
             | A.Responses.Text ->
                 Json.object_ [ ("type", Some (Json.string "text")) ]
             | A.Responses.Json_object ->
                 Json.object_ [ ("type", Some (Json.string "json_object")) ]
             | A.Responses.Json_schema { name; schema; strict } ->
                 Json.object_
                   [
                     ("type", Some (Json.string "json_schema"));
                     ("name", Some (Json.string name));
                     ("schema", Some schema);
                     ("strict", Option.map Json.bool strict);
                   ]
           in
           Json.object_ [ ("format", Some format) ])
  in
  let tool_choice =
    request.tool_choice
    |> Option.map (function
         | A.Responses.None_ -> Json.string "none"
         | A.Responses.Auto -> Json.string "auto"
         | A.Responses.Required -> Json.string "required"
         | A.Responses.Function name ->
             Json.object_
               [
                 ("type", Some (Json.string "function"));
                 ("name", Some (Json.string name));
               ])
  in
  Stdlib.Ok
    (Json.object_
       [
         ("model", Some (Json.string request.model));
         ("input", Some input);
         ("instructions", Option.map Json.string request.instructions);
         ( "previous_response_id",
           Option.map Json.string request.previous_response_id );
         ("store", Option.map Json.bool request.store);
         ( "include",
           if request.include_ = [] then None
           else Some (Json.array (List.map Json.string request.include_)) );
         ("stream", Some (Json.bool request.stream));
         ("temperature", temperature);
         ("top_p", top_p);
         ("reasoning", reasoning);
         ( "reasoning_effort",
           Option.map Json.string request.reasoning_effort );
         ("max_turns", Option.map Json.int request.max_turns);
         ("max_output_tokens", Option.map Json.int request.max_output_tokens);
         ("top_k", Option.map Json.int request.top_k);
         ("min_p", min_p);
         ("tools", if tools = [] then None else Some (Json.array tools));
         ("tool_choice", tool_choice);
         ("parallel_tool_calls", Option.map Json.bool request.parallel_tool_calls);
         ("text", request_text);
         ("service_tier", Option.map Json.string request.service_tier);
         ("user", Option.map Json.string request.user);
         ("prompt_cache_key", Option.map Json.string request.prompt_cache_key);
       ])

let encode_responses_json_lossless ~provider ~map_codec_failure ~encode_tool
    request =
  encode_responses_json_lossless_with response_input_items_lossless ~provider
    ~map_codec_failure ~encode_tool request

let encode_responses_json ~provider ~encode_tool request =
  encode_responses_json_lossless ~provider
    ~map_codec_failure:(ai_error_of_codec_failure_historical ~provider)
    ~encode_tool request

let encode_responses_lossless ~provider ~map_codec_failure ~encode_tool request =
  encode_responses_json_lossless ~provider ~map_codec_failure
    ~encode_tool request
  |> Result.map Json.to_string

let encode_responses ~provider ~encode_tool request =
  encode_responses_json ~provider ~encode_tool request
  |> Result.map Json.to_string

let encode_openrouter_responses ~encode_tool request =
  encode_responses_json_lossless_with openrouter_response_input_items_lossless
    ~provider:"openrouter"
    ~map_codec_failure:
      (ai_error_of_codec_failure_historical ~provider:"openrouter")
    ~encode_tool request
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

let responses_replay_item item =
  match Json.string_member "type" item with
  | Some "reasoning" -> Some (Json.compact item)
  | Some _ | None -> None

let status_finish ~has_tool_calls json =
  match Json.string_member "status" json with
  | Some "completed" -> if has_tool_calls then [ A.Tool_calls ] else [ A.Stop ]
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
      let replay_items = output |> List.filter_map responses_replay_item in
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
          finish_reasons = status_finish ~has_tool_calls:(tool_calls <> []) json;
          usage = Option.map usage (Json.object_member "usage" json);
          replay_items;
          raw = Some raw;
        }
