(** Moonshot Open Platform (Kimi-native Chat Completions).

    Default base URL is [https://api.moonshot.ai/v1] with path
    [/chat/completions]. Catalog listing uses [GET /models]. Callers pass an
    API-key credential; this package owns authorization headers. *)

val provider_name : string
val default_base_url : string
val china_base_url : string

type credential = private Eta_ai.api_key

val credential : string -> (credential, Eta_ai.ai_error) result
val credential_to_json : credential -> Eta_ai.Json.t
val credential_of_json : Eta_ai.Json.t -> (credential, Eta_ai.ai_error) result
val credential_to_string : credential -> Eta_ai.raw_json

val credential_of_string :
  Eta_ai.raw_json -> (credential, Eta_ai.ai_error) result

val pp_credential : Format.formatter -> credential -> unit
val api_key : credential -> Eta_ai.api_key
val auth_headers : ?extra_headers:Eta_ai.headers -> credential -> Eta_ai.headers

type structured_output = Eta_ai_openai_codec.structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

val provider :
  ?base_url:string -> ?extra_headers:Eta_ai.headers -> unit -> Eta_ai.provider

type supports_thinking_type = Only | No | Both

type think_efforts = {
  support : bool option;
  valid_efforts : string list;
  default_effort : string option;
}

type model_info = {
  id : string;
  display_name : string option;
  context_length : int option;
  supports_reasoning : bool option;
  supports_image_in : bool option;
  supports_video_in : bool option;
  supports_tool_use : bool option;
  supports_thinking_type : supports_thinking_type option;
  think_efforts : think_efforts option;
}

val models_request :
  ?provider:Eta_ai.provider ->
  credential:credential ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result

val list_models :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  credential:credential ->
  (model_info list, Eta_ai.ai_error) Eta.Effect.t

val encode_chat :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result

val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result

val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

val chat_completions_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

module Chat : sig
  val request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end
