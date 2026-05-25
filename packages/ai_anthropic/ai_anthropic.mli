(** Anthropic provider package for eta-ai.

    This package owns Anthropic-specific request encoding, response decoding,
    and eta-http runners. eta-ai owns the provider vocabulary; applications own
    state, retry policy, and key management. *)

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

val provider :
  ?base_url:string ->
  ?version:string ->
  ?beta_headers:string list ->
  unit ->
  Ai.provider
(** Messages API provider value. The default base URL is
    [https://api.anthropic.com] and the default API version is [2023-06-01]. *)

val encode_messages :
  ?prompt_cache:prompt_cache ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val decode_message : Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_stream_event :
  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
val decode_error :
  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error

val messages_request :
  ?prompt_cache:prompt_cache ->
  ?provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result

val messages :
  ?prompt_cache:prompt_cache ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t

val stream_messages :
  ?prompt_cache:prompt_cache ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t
