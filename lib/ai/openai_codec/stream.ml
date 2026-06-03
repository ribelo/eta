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

let responses_stream_events ?(nested_response_error = false) ~provider raw
    event_name json =
  match event_name with
  | Some "response.output_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_content_delta text ]
      | None -> [])
  | Some "response.output_item.added" -> responses_stream_tool_added json
  | Some "response.function_call_arguments.delta" ->
      [ responses_stream_tool_delta json ]
  | Some "response.completed" -> [ A.Stream_finish [ A.Stop ]; A.Stream_done ]
  | Some "response.incomplete" -> [ A.Stream_finish [ A.Length ] ]
  | Some "response.failed" ->
      [
        A.Stream_error
          (provider_error_json ~raw ~nested_response_error ~provider json);
      ]
  | _ -> []

let decode_stream_event ?(nested_response_error = false) ~provider event =
  let data = String.trim event.A.data in
  if String.equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
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
