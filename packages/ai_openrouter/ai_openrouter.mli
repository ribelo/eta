(** OpenRouter provider package for eta-ai.

    OpenRouter uses the OpenAI-style Responses API envelope with additional
    routing controls, attribution headers, and OpenRouter-specific error
    shapes. *)

type attribution = {
  referer : string option;
  title : string option;
}
(** Optional OpenRouter attribution headers. [referer] is sent as
    [HTTP-Referer] and [title] is sent as [X-Title]. *)

val attribution : ?referer:string -> ?title:string -> unit -> attribution

type routing = {
  order : string list;
  only_providers : string list;
  ignored_providers : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  sort : string option;
}
(** OpenRouter provider routing object.

    [order] models an ordered provider fallback chain. [only_providers] and
    [ignored_providers] map to OpenRouter's [only] and [ignore] provider
    fields. *)

val routing :
  ?order:string list ->
  ?only_providers:string list ->
  ?ignored_providers:string list ->
  ?allow_fallbacks:bool ->
  ?require_parameters:bool ->
  ?sort:string ->
  unit ->
  (routing, Ai.ai_error) result

val provider :
  ?base_url:string ->
  ?attribution:attribution ->
  ?extra_headers:Ai.headers ->
  unit ->
  Ai.provider
(** OpenRouter Responses API provider value. The default base URL is
    [https://openrouter.ai] and the path is [/api/v1/responses]. *)

type structured_output = Ai_openai_codec.structured_output = {
  name : string;
  schema : Ai.Json.t;
  strict : bool option;
}

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Ai.raw_json ->
  unit ->
  (structured_output, Ai.ai_error) result

val encode_chat :
  ?structured_output:structured_output ->
  ?routing:routing ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result
(** Encode eta-ai chat requests as OpenRouter Responses API requests. *)

val encode_responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_responses :
  Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_stream_event :
  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
val decode_error :
  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error

val responses_request :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result

val chat_completions_request :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result
[@@deprecated "Use responses_request; this sends the OpenRouter Responses API envelope."]

val responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t

val chat_completions :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t
[@@deprecated "Use responses; this sends the OpenRouter Responses API envelope."]

val stream_responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t
[@@deprecated "Use stream_responses; this sends the OpenRouter Responses API envelope."]
