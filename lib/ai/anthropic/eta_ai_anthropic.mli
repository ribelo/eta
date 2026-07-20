(** Anthropic Messages provider.

    Requests use [/v1/messages] with the [anthropic-version] header. System
    text is encoded through Anthropic's top-level [system] field, tool results
    use [tool_result] blocks, and optional prompt-cache support only covers
    system text. *)

type prompt_cache = {
  beta_header : string;
  cache_system : bool;
}
(** Prompt-cache controls expressible with eta-ai's current message vocabulary.

    [beta_header] is added as [Anthropic-Beta]. When [cache_system] is true,
    system text is encoded as an Anthropic text block with ephemeral
    [cache_control]. *)

val prompt_cache :
  ?beta_header:string -> ?cache_system:bool -> unit -> prompt_cache

(** {1 Credentials}

    Callers pass resolved API keys; this package owns [x-api-key] and version
    headers via {!provider}. *)

type credential = Eta_ai.api_key
val credential : string -> credential
val authorization_headers :
  ?version:string ->
  ?beta_headers:string list ->
  credential ->
  Eta_ai.headers

val provider :
  ?base_url:string ->
  ?version:string ->
  ?beta_headers:string list ->
  unit ->
  Eta_ai.provider
(** Messages API provider value. The default base URL is
    [https://api.anthropic.com] and the default API version is [2023-06-01]. *)

module Chat : sig
  include Eta_ai.Provider.Chat

  val messages_request :
    ?prompt_cache:prompt_cache ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val messages :
    ?prompt_cache:prompt_cache ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream_messages :
    ?prompt_cache:prompt_cache ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Embeddings : Eta_ai.Provider.Embeddings

val encode_messages :
  ?prompt_cache:prompt_cache ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_message : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

val messages_request :
  ?prompt_cache:prompt_cache ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val messages :
  ?prompt_cache:prompt_cache ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_messages :
  ?prompt_cache:prompt_cache ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

(** {1 Native model catalog}

    [GET /v1/models] against the configured provider base URL. Bodies are bounded
    to 5 MiB. Non-2xx responses use the provider error decoder (no credentials). *)

type model_info = {
  id : string;
  display_name : string option;
}

val models_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result

val list_models :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (model_info list, Eta_ai.ai_error) Eta.Effect.t
