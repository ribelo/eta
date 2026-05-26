(** OpenAI provider package for eta-ai.

    This package owns OpenAI-specific request encoding, response decoding, and
    eta-http runners. eta-ai owns the provider vocabulary; applications own
    state, retry policy, and key management. *)

type structured_output = Ai_openai_codec.structured_output = {
  name : string;
  schema : Ai.Json.t;
  strict : bool option;
}
(** JSON Schema configuration for OpenAI structured outputs. The constructor
    accepts raw JSON until eta-schema exposes JSON Schema export. *)

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Ai.raw_json ->
  unit ->
  (structured_output, Ai.ai_error) result

val provider : ?base_url:string -> unit -> Ai.provider
(** Default Responses API provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/responses]. *)

val chat_completions_provider : ?base_url:string -> unit -> Ai.provider
(** Explicit legacy Chat Completions provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/chat/completions]. *)

val responses_provider : ?base_url:string -> unit -> Ai.provider
(** Responses API provider value. The default base URL is
    [https://api.openai.com]. *)

val encode_chat :
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val encode_responses :
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_responses : Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_stream_event :
  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
val decode_error :
  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error

module Realtime = Realtime

val chat_completions_request :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result

val responses_request :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t

val responses :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t

val stream_responses :
  ?structured_output:structured_output ->
  ?provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t
