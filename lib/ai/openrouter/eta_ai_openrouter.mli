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

module Chat : sig
  include Eta_ai.Provider.Chat

  val encode_responses :
    ?structured_output:structured_output ->
    ?routing:routing ->
    Eta_ai.chat_request ->
    (Eta_ai.raw_json, Eta_ai.ai_error) result

  val responses_request :
    ?structured_output:structured_output ->
    ?routing:routing ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val responses :
    ?structured_output:structured_output ->
    ?routing:routing ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream_responses :
    ?structured_output:structured_output ->
    ?routing:routing ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Embeddings : sig
  include Eta_ai.Provider.Embeddings

  val encode_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    Eta_ai.embedding_request ->
    (Eta_ai.raw_json, Eta_ai.ai_error) result

  val request_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.embedding_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.embedding_request ->
      (Eta_ai.embedding_response, Eta_ai.ai_error) Eta.Effect.t
end

module Speech : Eta_ai.Provider.Speech
module Images : Eta_ai.Provider.Images
module Transcriptions : Eta_ai.Provider.Transcriptions
module Rerank : Eta_ai.Provider.Rerank
module Video : Eta_ai.Provider.Video

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
val encode_embeddings :
  ?routing:routing ->
  ?input_type:string ->
  Eta_ai.embedding_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result
(** Encode eta-ai embeddings requests as OpenRouter Embeddings API requests. *)

val decode_embeddings :
  Eta_ai.raw_json -> (Eta_ai.embedding_response, Eta_ai.ai_error) result
val encode_speech :
  Eta_ai.speech_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val encode_image_generation :
  Eta_ai.image_generation_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_image_generation :
  Eta_ai.raw_json -> (Eta_ai.image_response, Eta_ai.ai_error) result
val encode_transcription :
  Eta_ai.transcription_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_transcription :
  Eta_ai.raw_json -> (Eta_ai.transcription_response, Eta_ai.ai_error) result
val encode_rerank :
  Eta_ai.rerank_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_rerank :
  Eta_ai.raw_json -> (Eta_ai.rerank_response, Eta_ai.ai_error) result
val encode_video :
  Eta_ai.video_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
val decode_video :
  Eta_ai.raw_json -> (Eta_ai.video_response, Eta_ai.ai_error) result
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

val embeddings_request :
  ?routing:routing ->
  ?input_type:string ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.embedding_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val speech_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.speech_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val image_generation_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.image_generation_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val transcription_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.transcription_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val rerank_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.rerank_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.video_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_get_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  job_id:string ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_content_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.video_content_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

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

val embeddings :
  ?routing:routing ->
  ?input_type:string ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.embedding_request ->
  (Eta_ai.embedding_response, Eta_ai.ai_error) Eta.Effect.t

val speech :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.speech_request ->
  (Eta_ai.speech_response, Eta_ai.ai_error) Eta.Effect.t

val image_generation :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.image_generation_request ->
  (Eta_ai.image_response, Eta_ai.ai_error) Eta.Effect.t

val transcription :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.transcription_request ->
  (Eta_ai.transcription_response, Eta_ai.ai_error) Eta.Effect.t

val rerank :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.rerank_request ->
  (Eta_ai.rerank_response, Eta_ai.ai_error) Eta.Effect.t

val video :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.video_request ->
  (Eta_ai.video_response, Eta_ai.ai_error) Eta.Effect.t

val video_get :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  job_id:string ->
  (Eta_ai.video_response, Eta_ai.ai_error) Eta.Effect.t

val video_content :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.video_content_request ->
  (Eta_ai.video_content, Eta_ai.ai_error) Eta.Effect.t

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
