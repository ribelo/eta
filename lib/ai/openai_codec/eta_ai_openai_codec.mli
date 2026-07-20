(** Shared OpenAI-family JSON codec helpers for eta-ai providers. *)

type structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}

type reasoning_level = Off | Minimal | Low | Medium | High | Xhigh | Max

val reasoning_level_of_string :
  provider:string -> string -> (reasoning_level, Eta_ai.ai_error) result

val structured_output :
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

val decode_error_result :
  ?raw:Eta_ai.raw_json ->
  provider:string ->
  string ->
  ('a, Eta_ai.ai_error) result

val parse_json :
  provider:string ->
  Eta_ai.raw_json ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val schema_value :
  provider:string ->
  string ->
  Eta_ai.raw_json ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val non_empty_list :
  provider:string -> string -> 'a list -> ('a list, Eta_ai.ai_error) result

val optional_non_empty :
  provider:string ->
  string ->
  string option ->
  (string option, Eta_ai.ai_error) result

val with_json_fields :
  (string * Eta_ai.Json.t) list ->
  (string * Eta_ai.Json.t option) list ->
  Eta_ai.Json.t

val encode_speech :
  ?instructions:bool ->
  provider:string ->
  Eta_ai.Speech.request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val encode_embeddings_json :
  provider:string ->
  Eta_ai.Embedding.request ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val encode_embeddings :
  provider:string ->
  Eta_ai.Embedding.request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_embeddings :
  ?usage_extra_raw_names:string list ->
  provider:string ->
  Eta_ai.raw_json ->
  (Eta_ai.Embedding.response, Eta_ai.ai_error) result

val content_text : Eta_ai.content -> string option
val contents_text :
  provider:string -> Eta_ai.content list -> (string, Eta_ai.ai_error) result
val message_item :
  provider:string ->
  string ->
  Eta_ai.content list ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result
val function_call_item : Eta_ai.tool_call -> Eta_ai.Json.t
val input_items :
  provider:string -> Eta_ai.message -> (Eta_ai.Json.t list, Eta_ai.ai_error) result
val chat_message_json :
  provider:string -> Eta_ai.message -> (Eta_ai.Json.t, Eta_ai.ai_error) result

type tool_shape =
  | Chat_tool
  | Responses_tool

val tool_json :
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  shape:tool_shape ->
  Eta_ai.tool ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

type structured_output_shape =
  | Chat_response_format
  | Responses_format

val structured_output_json :
  shape:structured_output_shape ->
  structured_output ->
  Eta_ai.Json.t

val encode_chat_json :
  provider:string ->
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val encode_chat :
  provider:string ->
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val encode_chat_with_thinking :
  provider:string ->
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val encode_responses_json :
  provider:string ->
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val encode_responses :
  provider:string ->
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val finish_reason : string -> Eta_ai.finish_reason
val usage : ?raw_prompt_names:bool -> Eta_ai.Json.t -> Eta_ai.usage

val decode_chat :
  ?usage_raw_prompt_names:bool ->
  provider:string ->
  Eta_ai.raw_json ->
  (Eta_ai.response, Eta_ai.ai_error) result

val decode_responses :
  provider:string ->
  Eta_ai.raw_json ->
  (Eta_ai.response, Eta_ai.ai_error) result

val provider_error_json :
  ?status:int ->
  ?raw:Eta_ai.raw_json ->
  ?retry_after_s:int ->
  ?nested_response_error:bool ->
  provider:string ->
  Eta_ai.Json.t ->
  Eta_ai.ai_error

val provider_error :
  ?status:int ->
  ?retry_after_s:int ->
  ?nested_response_error:bool ->
  provider:string ->
  Eta_ai.raw_json ->
  Eta_ai.ai_error

val decode_error :
  ?nested_response_error:bool ->
  provider:string ->
  status:int ->
  headers:Eta_ai.headers ->
  Eta_ai.raw_json ->
  Eta_ai.ai_error

val chat_stream_events :
  finish_reason:(string -> Eta_ai.finish_reason) ->
  Eta_ai.raw_json ->
  Eta_ai.Json.t ->
  Eta_ai.stream_event list
(** Decode OpenAI Chat Completions SSE JSON into stream events, including
    [delta.tool_calls] argument fragments. *)

val responses_stream_events :
  ?nested_response_error:bool ->
  provider:string ->
  Eta_ai.raw_json ->
  string option ->
  Eta_ai.Json.t ->
  Eta_ai.stream_event list

val decode_stream_event :
  ?nested_response_error:bool ->
  provider:string ->
  Eta_ai.sse_event ->
  (Eta_ai.stream_event list, Eta_ai.ai_error) result

val result_all : ('a, 'err) result list -> ('a list, 'err) result
val result_map_all : ('a -> ('b, 'err) result) -> 'a list -> ('b list, 'err) result
