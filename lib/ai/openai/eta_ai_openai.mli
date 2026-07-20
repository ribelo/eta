(** OpenAI provider.

    [provider] defaults to the Responses API; use
    {!chat_completions_provider} for the legacy Chat Completions envelope.
    Chat prompt capability flags are conservative: image parts are encoded, but
    audio prompt input belongs to Realtime and video prompt input is not
    advertised. Speech, transcription, image generation, and Realtime are
    exposed as separate endpoint modules. *)

type structured_output = Eta_ai_openai_codec.structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}
(** OpenAI structured-output configuration. [schema] is provider JSON carried
    unchanged after normal JSON validation at the Eta_ai boundary. *)

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

(** {1 Credentials}

    Callers pass resolved API keys; this package owns the Authorization header. *)

type credential = Eta_ai.api_key
val credential : string -> credential
val authorization_headers : credential -> Eta_ai.headers
(** [Authorization: Bearer ...] plus JSON content headers. *)

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

(** {1 Native model catalog}

    [GET /v1/models] against the configured provider base URL. Bodies are bounded
    to 5 MiB. Non-2xx responses use the provider error decoder (no credentials). *)

type model_info = { id : string }

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
