module A = Eta_ai
module Common = Eta_ai_openai_common
module Json = Common.Json

let stream_error raw json =
  Common.decode_provider_error_json raw json

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

let chat_events raw json =
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
    |> List.map Common.finish_reason
  in
  starts @ deltas
  @ if finishes = [] then [] else [ A.Stream_finish finishes ]

let responses_events event_name json =
  match event_name with
  | Some "response.output_text.delta" -> (
      match Json.string_member "delta" json with
      | Some text -> [ A.Stream_content_delta text ]
      | None -> [])
  | Some "response.function_call_arguments.delta" ->
      [
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
          };
      ]
  | Some "response.completed" -> [ A.Stream_finish [ A.Stop ]; A.Stream_done ]
  | Some "response.failed" ->
      [ A.Stream_error (stream_error (Json.compact json) json) ]
  | _ -> []

let decode_event (event : A.sse_event) =
  let data = String.trim event.data in
  if String.equal data "[DONE]" then Stdlib.Ok [ A.Stream_done ]
  else
    match Common.parse_json data with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok json -> (
        match Json.object_member "error" json with
        | Some _ -> Stdlib.Ok [ A.Stream_error (stream_error event.data json) ]
        | None -> (
            let response_events = responses_events event.event json in
            match response_events with
            | [] -> Stdlib.Ok (chat_events event.data json)
            | events -> Stdlib.Ok events))
