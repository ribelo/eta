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
    type custom_id = private string

    val custom_id : string -> (custom_id, Error.t) Stdlib.result

    type built_in =
      | Alloy
      | Ash
      | Ballad
      | Coral
      | Echo
      | Fable
      | Onyx
      | Nova
      | Sage
      | Shimmer
      | Verse
      | Marin
      | Cedar
      | Other of string

    type t = Built_in of built_in | Custom of custom_id
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
    type model =
      | Tts_1
      | Tts_1_hd
      | Gpt_4o_mini_tts
      | Gpt_4o_mini_tts_2025_12_15
      | Other of string

    type response_format = Mp3 | Opus | Aac | Flac | Wav | Pcm
    type stream_format = Audio | Sse

    val model_to_string : model -> string

    type request = private {
      model : model;
      input : string;
      voice : Voices.t;
      instructions : string option;
      response_format : response_format option;
      speed : float option;
      stream_format : stream_format option;
      extra : (string * Eta_ai.Json.t) list;
    }

    type result = {
      content_type : string option;
      audio : bytes;
    }

    type configuration = {
      model : model;
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

    val request :
      model:model ->
      input:string ->
      voice:Voices.t ->
      ?instructions:string ->
      ?response_format:response_format ->
      ?speed:float ->
      ?stream_format:stream_format ->
      ?extra:(string * Eta_ai.Json.t) list ->
      unit ->
      (request, Error.t) Stdlib.result
    (** Validates [input] as UTF-8 with the documented 4096-scalar limit.
        Validates [instructions] as UTF-8 with a 4096-scalar limit.
        Validates the inclusive finite 0.25-4.0 speed range.
        Applies known-model instruction and SSE restrictions by canonical wire
        identifier, including identifiers carried by [Other].
        Known [tts-1] and [tts-1-hd] models reject built-in voices outside
        their documented voice set, including known voices carried by [Other].
        Rejects empty built-in and custom voice identifiers.
        Rejects collisions between provider extra fields and owned fields.
        Unknown future model and built-in voice identifiers remain
        representable. *)

    val encode : request -> (Eta_ai.raw_json, Error.t) Stdlib.result

    val http_request :
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

    type audio_stream
    type event_stream

    type event =
      | Unknown of {
          type_ : string;
          raw : Eta_ai.Json.t;
        }
    (** Until OpenAI publishes a Speech SSE schema, every well-formed event is
        preserved as [Unknown] with its event type and complete parsed JSON.
        Framing accepts one leading UTF-8 BOM, CR, LF, CRLF, comments, ignored
        fields, colonless fields, and multiline data according to WHATWG SSE.
        An incomplete event at EOF is discarded. *)

    val default_max_buffer_bytes : int
    val default_max_json_bytes : int
    val default_max_pending_events : int

    val stream_audio :
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (audio_stream, Error.t) Eta.Effect.t

    val read_audio :
      audio_stream -> (bytes option, Error.t) Eta.Effect.t

    val collect_audio :
      max_bytes:int -> audio_stream -> (bytes, Error.t) Eta.Effect.t
    (** Collection requires a caller-supplied nonnegative [max_bytes].
        An over-limit pull fails nominally.
        An invalid or exceeded collection limit releases the stream.
        Streaming itself has no total-audio limit. *)

    val close_audio : audio_stream -> (unit, Error.t) Eta.Effect.t

    val stream_events :
      ?max_buffer_bytes:int ->
      ?max_json_bytes:int ->
      ?max_pending_events:int ->
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (event_stream, Error.t) Eta.Effect.t
    (** An unallocatable [max_buffer_bytes] or [max_json_bytes] override fails
        with [Error.Invalid_request] without issuing an HTTP request. *)

    val read_event :
      event_stream -> (event option, Error.t) Eta.Effect.t

    val close_events : event_stream -> (unit, Error.t) Eta.Effect.t
    (** Constructing a speech stream operation does not mutate stream state,
        acquire its operation gate, or release its response body.
        Each speech stream permits one active read, collection, or close;
        concurrent use fails immediately with [Error.Concurrent_use].
        Normal completion, failure, cancellation, and explicit close release
        the response body exactly once.
        Cleanup failure is suppressed beneath the triggering failure.
        Speech SSE applies positive default bounds to unframed bytes, decoded
        JSON bytes, and pending events.
        Each accepted per-operation override becomes the corresponding Speech
        SSE bound. *)
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
