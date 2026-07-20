module A = Eta_ai
module Json = A.Json

open Core
open Error_codec

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
  let id = Json.string_member "id" json in
  let model = Json.string_member "model" json in
  let add_choice (starts, deltas, finishes) choice =
    let finishes =
      match Json.string_member "finish_reason" choice with
      | None -> finishes
      | Some reason -> finish_reason reason :: finishes
    in
    match Json.object_member "delta" choice with
    | None -> (starts, deltas, finishes)
    | Some delta ->
        let deltas =
          match Json.string_member "content" delta with
          | None -> deltas
          | Some text -> A.Stream_content_delta text :: deltas
        in
        let deltas =
          match Json.string_member "reasoning_content" delta with
          | None -> deltas
          | Some text -> A.Stream_reasoning_delta text :: deltas
        in
        let deltas =
          match Json.array_member "tool_calls" delta with
          | None -> deltas
          | Some tool_calls ->
              let rec add_tool_deltas deltas = function
                | [] -> deltas
                | tool_call :: rest ->
                    add_tool_deltas
                      (stream_tool_delta tool_call :: deltas)
                      rest
              in
              add_tool_deltas deltas tool_calls
        in
        let starts =
          if Json.string_member "role" delta = Some "assistant" then
            A.Stream_message_start { id; model; raw = Some raw } :: starts
          else starts
        in
        (starts, deltas, finishes)
  in
  let rec add_choices acc = function
    | [] -> acc
    | choice :: rest -> add_choices (add_choice acc choice) rest
  in
  let starts, deltas, finishes = add_choices ([], [], []) choices in
  let tail =
    match finishes with
    | [] -> []
    | _ -> [ A.Stream_finish (List.rev finishes) ]
  in
  List.rev_append starts (List.rev_append deltas tail)

let responses_stream_tool_delta json =
  A.Stream_tool_call_delta
    {
      index = Json.int_member "output_index" json;
      id =
        (match Json.string_member "call_id" json with
        | Some _ as value -> value
        | None -> Json.string_member "item_id" json);
      name = None;
      arguments_json_delta =
        Option.value ~default:"" (Json.string_member "delta" json);
    }

let responses_stream_tool_added json =
  match Json.object_member "item" json with
  | Some item when Json.string_member "type" item = Some "function_call" ->
      let id =
        match Json.string_member "call_id" item with
        | Some _ as value -> value
        | None -> Json.string_member "id" item
      in
      let arguments_json_delta =
        match Json.member "arguments" item with
        | Some (`String arguments) -> arguments
        | Some arguments -> Json.compact arguments
        | None -> ""
      in
      [
        A.Stream_tool_call_delta
          {
            index = Json.int_member "output_index" json;
            id;
            name = Json.string_member "name" item;
            arguments_json_delta;
          };
      ]
  | _ -> []

let response_event_name event json =
  match event.A.event with
  | Some _ as value -> value
  | None -> Json.string_member "type" json

let responses_message_start raw json =
  match Json.object_member "response" json with
  | None -> []
  | Some response ->
      [
        A.Stream_message_start
          {
            id = Json.string_member "id" response;
            model = Json.string_member "model" response;
            raw = Some raw;
          };
      ]

let responses_terminal ~provider json =
  match Json.object_member "response" json with
  | None -> [ A.Stream_finish [ A.Stop ]; A.Stream_done ]
  | Some response -> (
      match Responses.decode_responses ~provider (Json.compact response) with
      | Stdlib.Ok response ->
          [
            A.Stream_response response;
            A.Stream_finish response.finish_reasons;
            A.Stream_done;
          ]
      | Stdlib.Error error -> [ A.Stream_error error ])

let responses_stream_events ?(nested_response_error = false) ~provider raw
    event_name json =
  match event_name with
  | Some "response.created" -> responses_message_start raw json
  | Some "response.reasoning_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_reasoning_delta text ]
      | None -> [])
  | Some "response.output_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_content_delta text ]
      | None -> [])
  | Some "response.output_item.added" -> responses_stream_tool_added json
  | Some "response.function_call_arguments.delta" ->
      [ responses_stream_tool_delta json ]
  | Some "response.completed" -> responses_terminal ~provider json
  | Some "response.incomplete" -> responses_terminal ~provider json
  | Some "response.failed" ->
      [
        A.Stream_error
          (provider_error_json ~raw ~nested_response_error ~provider json);
      ]
  | _ -> []

let decode_stream_event ?(nested_response_error = false) ~provider event =
  let data = event.A.data in
  if A.Json_helpers.trim_equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
  else
    match parse_json ~provider data with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok json ->
        if Option.is_some (error_object ~nested_response_error json) then
          Stdlib.Ok
            [
              A.Stream_error
                (provider_error_json ~raw:data ~nested_response_error ~provider
                   json);
            ]
        else
          let response_events =
            responses_stream_events ~nested_response_error ~provider data
              (response_event_name event json) json
          in
          if response_events = [] then
            Stdlib.Ok (chat_stream_events ~finish_reason data json)
          else Stdlib.Ok response_events
