(** OpenAI provider.

    [provider] defaults to the Responses API; use
    {!chat_completions_provider} for the legacy Chat Completions envelope.
    Chat prompt capability flags are conservative: image parts are encoded, but
    audio prompt input belongs to Realtime and video prompt input is not
    advertised. Speech-to-text, text-to-speech, voices, and Realtime are grouped
    under [Audio]; image generation remains a separate endpoint module. *)

module Error = Openai_error

type stream
(** Provider-owned opaque stream handle. *)

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
  (structured_output, Error.t) result

(** {1 Credentials}

    Callers pass resolved API keys; this package owns the Authorization header. *)

type credential = Eta_ai.api_key
val credential : string -> credential
val authorization_headers : credential -> Eta_ai.headers
(** [Authorization: Bearer ...] plus JSON content headers. *)

val provider : ?base_url:string -> unit -> Eta_ai.provider
(** Default Responses API provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/responses].

    The shared [Eta_ai.provider] record remains neutral ([Eta_ai.ai_error]) so
    generic transport helpers can host it. Prefer the nominal OpenAI operations
    below for lossless failures. Nominal runners use configured request and
    success/stream decoder callbacks, but decode non-success HTTP responses with
    [Error.decode] so status, headers, and raw body remain lossless. *)

val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
(** Explicit legacy Chat Completions provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/chat/completions]. *)

val responses_provider :
  ?base_url:string -> unit -> Eta_ai.tool Eta_ai.responses_provider
(** Responses API provider value. The default base URL is
    [https://api.openai.com]. *)

module Chat : sig
  val encode :
    provider:Eta_ai.provider ->
    Eta_ai.chat_request ->
    (Eta_ai.raw_json, Error.t) result

  val decode :
    provider:Eta_ai.provider ->
    Eta_ai.raw_json ->
    (Eta_ai.response, Error.t) result

  val request :
    provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Error.t) result

  val run :
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Error.t) Eta.Effect.t

  val stream :
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (stream, Error.t) Eta.Effect.t

  val responses_request :
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_http.Request.t, Error.t) result

  val responses :
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_ai.response, Error.t) Eta.Effect.t

  val stream_responses :
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (stream, Error.t) Eta.Effect.t
end

module Embeddings : sig
  val encode :
    provider:Eta_ai.provider ->
    Eta_ai.Embedding.request ->
    (Eta_ai.raw_json, Error.t) result

  val decode :
    provider:Eta_ai.provider ->
    Eta_ai.raw_json ->
    (Eta_ai.Embedding.response, Error.t) result

  val request :
    provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.Embedding.request ->
    (Eta_http.Request.t, Error.t) result

  val run :
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.Embedding.request ->
    (Eta_ai.Embedding.response, Error.t) Eta.Effect.t
end

module Images : sig
  val generate :
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.Image.request ->
    (Eta_ai.Image.response, Error.t) Eta.Effect.t
end

module Audio : sig
  module Voices : sig
    type t = string
  end

  module Speech_to_text : sig
    type request = {
      model : Eta_ai.model;
      file : Eta_ai.Audio.upload;
      language : string option;
      prompt : string option;
      response_format : string option;
      temperature : float option;
      extra_fields : (string * string) list;
    }

    type result = {
      text : string option;
      language : string option;
      duration_s : float option;
      usage : Eta_ai.usage option;
      raw : Eta_ai.raw_json option;
    }

    type configuration = {
      model : Eta_ai.model;
      prompt : string option;
      response_format : string option;
      temperature : float option;
      extra_fields : (string * string) list;
    }

    type request_construction

    include
      Eta_ai.Audio.Speech_to_text.Provider
        with type request := request
         and type result := result
         and type error := Error.t
         and type configuration := configuration
         and type request_construction := request_construction

    val decode_response : Eta_ai.raw_json -> (result, Error.t) Stdlib.result

    val request :
      ?provider:Eta_ai.provider ->
      api_key:Eta_ai.api_key ->
      request ->
      (Eta_http.Request.t, Error.t) Stdlib.result

    val create :
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (result, Error.t) Eta.Effect.t
  end

  module Text_to_speech : sig
    type request = {
      model : Eta_ai.model;
      input : string;
      voice : Voices.t;
      response_format : string option;
      speed : float option;
      instructions : string option;
      extra : (string * Eta_ai.Json.t) list;
    }

    type result = {
      content_type : string option;
      audio : bytes;
    }

    type configuration = {
      model : Eta_ai.model;
      instructions : string option;
      extra : (string * Eta_ai.Json.t) list;
    }

    type request_construction

    include
      Eta_ai.Audio.Text_to_speech.Provider
        with type request := request
         and type result := result
         and type error := Error.t
         and type configuration := configuration
         and type request_construction := request_construction

    val encode : request -> (Eta_ai.raw_json, Error.t) Stdlib.result

    val request :
      ?provider:Eta_ai.provider ->
      api_key:Eta_ai.api_key ->
      request ->
      (Eta_http.Request.t, Error.t) Stdlib.result

    val create :
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (result, Error.t) Eta.Effect.t
  end

  module Realtime = Realtime
end

val encode_chat :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Error.t) result

val encode_responses :
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.raw_json, Error.t) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Error.t) result
val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Error.t) result
val encode_embeddings :
  Eta_ai.Embedding.request -> (Eta_ai.raw_json, Error.t) result
val decode_embeddings :
  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Error.t) result
val encode_image_generation :
  Eta_ai.Image.request -> (Eta_ai.raw_json, Error.t) result
val decode_image_response :
  Eta_ai.raw_json -> (Eta_ai.Image.response, Error.t) result
val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Error.t) result
val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Error.t

val chat_completions_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Error.t) result

val responses_request :
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_http.Request.t, Error.t) result

val embeddings_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_http.Request.t, Error.t) result

val image_generation_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_http.Request.t, Error.t) result

val chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Error.t) Eta.Effect.t

val responses :
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.response, Error.t) Eta.Effect.t

val embeddings :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_ai.Embedding.response, Error.t) Eta.Effect.t

val image_generation :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_ai.Image.response, Error.t) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (stream, Error.t) Eta.Effect.t

val stream_responses :
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (stream, Error.t) Eta.Effect.t

val stream_of_body : Eta_ai.provider -> Eta_http.Body.Stream.t -> stream
(** Build a provider stream from an already-open response body (tests/fixtures). *)

val read_stream_event :
  stream -> (Eta_ai.stream_event option, Error.t) Eta.Effect.t
(** Provider callback failures and embedded neutral [Stream_error] values fail
    through [Error.t]. The stream closes exactly once; cleanup diagnostics are
    suppressed beneath the primary provider failure. *)

val read_stream_events :
  stream -> (Eta_ai.stream_event list, Error.t) Eta.Effect.t
(** Read until normal completion or the first nominal failure, with the same
    cleanup semantics as {!read_stream_event}. *)

val close_stream : stream -> (unit, Error.t) Eta.Effect.t

(** {1 Native model catalog}

    [GET /v1/models] against the configured provider base URL. Bodies are bounded
    to 5 MiB. Non-2xx responses use the provider error decoder (no credentials). *)

type model_info = { id : string }

val models_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  unit ->
  (Eta_http.Request.t, Error.t) result

val decode_models : Eta_ai.raw_json -> (model_info list, Error.t) result

val list_models :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (model_info list, Error.t) Eta.Effect.t
