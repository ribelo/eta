(** OpenAI provider package for eta-ai.

    This package owns OpenAI-specific request encoding, response decoding, and
    eta-http runners. eta-ai owns the provider vocabulary; applications own
    state, retry policy, and key management. *)

type structured_output = Eta_ai_openai_codec.structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}
(** JSON Eta_schema configuration for OpenAI structured outputs. The constructor
    accepts raw JSON until eta-schema exposes JSON Eta_schema export. *)

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

val provider : ?base_url:string -> unit -> Eta_ai.provider
(** Default Responses API provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/responses]. *)

val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
(** Explicit legacy Chat Completions provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/chat/completions]. *)

val responses_provider : ?base_url:string -> unit -> Eta_ai.provider
(** Responses API provider value. The default base URL is
    [https://api.openai.com]. *)

module Chat : sig
  include Eta_ai.Provider.Chat

  val responses_request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val responses :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream_responses :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Embeddings : Eta_ai.Provider.Embeddings
module Images : Eta_ai.Provider.Images
module Speech : Eta_ai.Provider.Speech
module Transcriptions : Eta_ai.Provider.Transcriptions

val encode_chat :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val encode_responses :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val encode_embeddings :
  Eta_ai.Embedding.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_embeddings :
  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
val encode_image_generation :
  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_image_response :
  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
val encode_speech :
  Eta_ai.Speech.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_transcription_response :
  Eta_ai.raw_json -> (Eta_ai.Transcription.response, Eta_ai.ai_error) result
val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

module Realtime = Realtime

val chat_completions_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val responses_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val embeddings_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val image_generation_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val speech_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Speech.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val transcription_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Transcription.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val embeddings :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t

val image_generation :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t

val speech :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Speech.request ->
  (Eta_ai.Speech.response, Eta_ai.ai_error) Eta.Effect.t

val transcription :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Transcription.request ->
  (Eta_ai.Transcription.response, Eta_ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

val stream_responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
