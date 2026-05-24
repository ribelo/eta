(** Shared OpenAI-family JSON codec helpers for eta-ai providers. *)

type structured_output = {
  name : string;
  schema_json : Eta_ai.raw_json;
  strict : bool option;
}

val structured_output :
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

val content_text : Eta_ai.content -> string
val contents_text : Eta_ai.content list -> string
val message_item : string -> Eta_ai.content list -> Eta_ai.Json.t
val function_call_item : Eta_ai.tool_call -> Eta_ai.Json.t
val input_items : Eta_ai.message -> Eta_ai.Json.t list

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
  schema_value:
    (string -> Eta_ai.raw_json -> (Eta_ai.Json.t, Eta_ai.ai_error) result) ->
  shape:structured_output_shape ->
  structured_output ->
  (Eta_ai.Json.t, Eta_ai.ai_error) result

val result_all : ('a, 'err) result list -> ('a list, 'err) result
