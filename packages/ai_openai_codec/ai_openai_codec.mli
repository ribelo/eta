(** Shared OpenAI-family JSON codec helpers for eta-ai providers. *)

type structured_output = {
  name : string;
  schema : Ai.Json.t;
  strict : bool option;
}

val structured_output :
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  ?strict:bool ->
  name:string ->
  schema_json:Ai.raw_json ->
  unit ->
  (structured_output, Ai.ai_error) result

val decode_error_result :
  ?raw:Ai.raw_json ->
  provider:string ->
  string ->
  ('a, Ai.ai_error) result

val parse_json :
  provider:string ->
  Ai.raw_json ->
  (Ai.Json.t, Ai.ai_error) result

val schema_value :
  provider:string ->
  string ->
  Ai.raw_json ->
  (Ai.Json.t, Ai.ai_error) result

val content_text : Ai.content -> string
val contents_text : Ai.content list -> string
val message_item : string -> Ai.content list -> Ai.Json.t
val function_call_item : Ai.tool_call -> Ai.Json.t
val input_items : Ai.message -> Ai.Json.t list
val chat_message_json : Ai.message -> Ai.Json.t

type tool_shape =
  | Chat_tool
  | Responses_tool

val tool_json :
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  shape:tool_shape ->
  Ai.tool ->
  (Ai.Json.t, Ai.ai_error) result

type structured_output_shape =
  | Chat_response_format
  | Responses_format

val structured_output_json :
  shape:structured_output_shape ->
  structured_output ->
  Ai.Json.t

val encode_chat_json :
  provider:string ->
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.Json.t, Ai.ai_error) result

val encode_chat :
  provider:string ->
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val encode_responses_json :
  provider:string ->
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.Json.t, Ai.ai_error) result

val encode_responses :
  provider:string ->
  schema_value:
    (string -> Ai.raw_json -> (Ai.Json.t, Ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val finish_reason : string -> Ai.finish_reason
val usage : ?raw_prompt_names:bool -> Ai.Json.t -> Ai.usage

val decode_chat :
  ?usage_raw_prompt_names:bool ->
  provider:string ->
  Ai.raw_json ->
  (Ai.response, Ai.ai_error) result

val decode_responses :
  provider:string ->
  Ai.raw_json ->
  (Ai.response, Ai.ai_error) result

val provider_error_json :
  ?status:int ->
  ?raw:Ai.raw_json ->
  ?nested_response_error:bool ->
  provider:string ->
  Ai.Json.t ->
  Ai.ai_error

val provider_error :
  ?status:int ->
  ?nested_response_error:bool ->
  provider:string ->
  Ai.raw_json ->
  Ai.ai_error

val decode_error :
  ?nested_response_error:bool ->
  provider:string ->
  status:int ->
  headers:'headers ->
  Ai.raw_json ->
  Ai.ai_error

val chat_stream_events :
  finish_reason:(string -> Ai.finish_reason) ->
  Ai.raw_json ->
  Ai.Json.t ->
  Ai.stream_event list
(** Decode OpenAI Chat Completions SSE JSON into stream events, including
    [delta.tool_calls] argument fragments. *)

val responses_stream_events :
  ?nested_response_error:bool ->
  provider:string ->
  Ai.raw_json ->
  string option ->
  Ai.Json.t ->
  Ai.stream_event list

val decode_stream_event :
  ?nested_response_error:bool ->
  provider:string ->
  Ai.sse_event ->
  (Ai.stream_event list, Ai.ai_error) result

val result_all : ('a, 'err) result list -> ('a list, 'err) result
