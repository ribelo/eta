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
  (routing, Eta_ai.ai_error) result

val provider :
  ?base_url:string ->
  ?attribution:attribution ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider
(** OpenRouter Responses API provider value. The default base URL is
    [https://openrouter.ai] and the path is [/api/v1/responses]. *)

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

val encode_chat :
  ?structured_output:structured_output ->
  ?routing:routing ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result
(** Encode eta-ai chat requests as OpenRouter Responses API requests. *)

val encode_responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val decode_responses :
  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

val responses_request :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val chat_completions_request :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result
[@@deprecated "Use responses_request; this sends the OpenRouter Responses API envelope."]

val responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val chat_completions :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
[@@deprecated "Use responses; this sends the OpenRouter Responses API envelope."]

val stream_responses :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?routing:routing ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
[@@deprecated "Use stream_responses; this sends the OpenRouter Responses API envelope."]
