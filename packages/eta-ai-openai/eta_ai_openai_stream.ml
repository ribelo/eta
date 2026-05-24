module A = Eta_ai
module Codec = Eta_ai_openai_codec
module Common = Eta_ai_openai_common
module Json = Common.Json

let stream_error raw json =
  Common.decode_provider_error_json raw json

let chat_events raw json =
  Codec.chat_stream_events ~finish_reason:Common.finish_reason raw json

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
