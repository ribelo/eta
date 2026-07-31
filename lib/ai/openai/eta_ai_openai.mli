(** OpenAI provider.

    [provider] defaults to the Responses API; use
    {!chat_completions_provider} for the legacy Chat Completions envelope.
    Chat Completions supports buffered audio input and output. Responses remains
    a text-and-image endpoint. Speech-to-text, text-to-speech, voices, and
    Realtime are grouped under [Audio]; image generation remains separate. *)

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
    stream callbacks. Buffered Chat uses its provider-owned decoder. Responses
    uses its configured success decoder. All nominal runners use [Error.decode]
    for non-success responses. Thus, status, headers, and raw body remain
    available. *)

val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
(** Explicit legacy Chat Completions provider value. The default base URL is
    [https://api.openai.com] and the path is [/v1/chat/completions].
    Its neutral encoder applies the same input-audio checks as [Chat.request]. *)

val responses_provider :
  ?base_url:string -> unit -> Eta_ai.tool Eta_ai.responses_provider
(** Responses API provider value. The default base URL is
    [https://api.openai.com]. *)

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

module Chat : sig
  type modality = Text | Audio

  type output_format =
    | Wav
    | Aac
    | Mp3
    | Flac
    | Opus
    | Pcm16

  type output_audio = {
    voice : Voices.t;
    format : output_format;
  }

  type request = private {
    common : Eta_ai.chat_request;
    modalities : modality list;
    audio : output_audio option;
    store : bool option;
    extra_fields : (string * Eta_ai.Json.t) list;
  }

  val request :
    common:Eta_ai.chat_request ->
    ?modalities:modality list ->
    ?audio:output_audio ->
    ?store:bool ->
    ?extra_fields:(string * Eta_ai.Json.t) list ->
    unit ->
    (request, Error.t) result
  (** Audio content is valid only in user messages and only with [Mp3] or [Wav].
      Caller-provided Base64 must use strict canonical standard padding.
      The [Audio] modality and [audio] configuration must occur together.
      Modalities cannot repeat. Extra field names must be unique and cannot use
      provider-owned names. A streaming request with audio output returns
      [Error.Unsupported]. Streamed input audio with text output is valid. *)

  type function_call = {
    name : string;
    arguments : string;
    raw : Eta_ai.Json.t;
  }

  type custom_call = {
    name : string;
    input : string;
    raw : Eta_ai.Json.t;
  }

  type tool_call =
    | Function_tool_call of {
        id : string;
        function_ : function_call;
        raw : Eta_ai.Json.t;
      }
    | Custom_tool_call of {
        id : string;
        custom : custom_call;
        raw : Eta_ai.Json.t;
      }

  type audio = {
    id : string;
    expires_at : int;
    data : string;
    transcript : string;
    raw : Eta_ai.Json.t;
  }

  type content_part =
    | Text_part of {
        text : string;
        raw : Eta_ai.Json.t;
      }
    | Refusal_part of {
        refusal : string;
        raw : Eta_ai.Json.t;
      }

  type message_content =
    | Content_text of string
    | Content_parts of content_part list

  type message = {
    role : string;
    content : message_content option;
    refusal : string option;
    annotations : Eta_ai.Json.t list option;
    function_call : function_call option;
    tool_calls : tool_call list;
    audio : audio option;
    raw : Eta_ai.Json.t;
  }

  type choice = {
    index : int;
    message : message;
    finish_reason : string;
    logprobs : logprobs option;
    raw : Eta_ai.Json.t;
  }

  and logprobs = {
    content : Eta_ai.Json.t list option;
    refusal : Eta_ai.Json.t list option;
    raw : Eta_ai.Json.t;
  }

  type prompt_token_details = {
    audio_tokens : int option;
    cached_tokens : int option;
    cache_write_tokens : int option;
    raw : Eta_ai.Json.t;
  }

  type completion_token_details = {
    accepted_prediction_tokens : int option;
    audio_tokens : int option;
    reasoning_tokens : int option;
    rejected_prediction_tokens : int option;
    raw : Eta_ai.Json.t;
  }

  type usage = {
    prompt_tokens : int;
    completion_tokens : int;
    total_tokens : int;
    prompt_tokens_details : prompt_token_details option;
    completion_tokens_details : completion_token_details option;
    raw : Eta_ai.Json.t;
  }

  type moderation_input_type = Text_input | Image_input

  type moderation_result = {
    categories : (string * bool) list;
    category_applied_input_types :
      (string * moderation_input_type list) list;
    category_scores : (string * float) list;
    flagged : bool;
    model : string;
    type_ : string;
    raw : Eta_ai.Json.t;
  }

  type moderation_success = {
    model : string;
    results : moderation_result list;
    type_ : string;
    raw : Eta_ai.Json.t;
  }

  type moderation_error = {
    code : string;
    message : string;
    type_ : string;
    raw : Eta_ai.Json.t;
  }

  type moderation_outcome =
    | Moderation_success of moderation_success
    | Moderation_error of moderation_error

  type moderation = {
    input : moderation_outcome;
    output : moderation_outcome;
    raw : Eta_ai.Json.t;
  }

  type response = private {
    id : string;
    choices : choice list;
    created : int;
    model : string;
    object_ : string;
    service_tier : string option;
    system_fingerprint : string option;
    usage : usage option;
    moderation : moderation option;
    raw : Eta_ai.Json.t;
    raw_body : Eta_ai.raw_json;
  }

  val encode :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    request ->
    (Eta_ai.raw_json, Error.t) result
  (** Audio requests cannot use [structured_output]. *)

  val decode :
    Eta_ai.raw_json -> (response, Error.t) result
  (** The decoder requires the documented buffered Chat fields, at least one
      choice, and nonnegative integer token counts. Each typed provider record
      keeps its complete JSON object. A malformed success body returns
      [Error.Decode] with the original body. Moderation category scores must be
      finite numbers from [0.0] through [1.0], inclusive. *)

  val audio_bytes : audio -> (bytes, Error.t) result
  (** This function decodes strict canonical standard padded base64 without an
      exception. Invalid data returns [Error.Decode] with the complete audio JSON.
      The [audio] value does not change. *)

  val to_eta_ai : response -> Eta_ai.response
  (** This projection keeps the first choice's common text, tools, and finish
      reason, plus direct usage totals and raw JSON. It removes Chat audio facts
      at this explicit boundary and does not derive missing token facts. *)

  val http_request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    request ->
    (Eta_http.Request.t, Error.t) result

  val run :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    request ->
    (response, Error.t) Eta.Effect.t

  val stream :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    request ->
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
  module Voices = Voices

  module Speech_to_text : sig
    type model =
      | Whisper_1
      | Gpt_transcribe
      | Gpt_4o_transcribe
      | Gpt_4o_mini_transcribe
      | Gpt_4o_mini_transcribe_2025_12_15
      | Gpt_4o_transcribe_diarize
      | Other of string

    type response_format =
      | Json
      | Text
      | Srt
      | Verbose_json
      | Vtt
      | Diarized_json
      | Other_format of string

    type include_item = Logprobs | Other_include of string
    type timestamp_granularity = Word | Segment | Other_timestamp of string

    type vad = {
      prefix_padding_ms : int option;
      silence_duration_ms : int option;
      threshold : float option;
    }

    type chunking_strategy =
      | Auto
      | Server_vad of vad
      | Other_chunking of Eta_ai.Json.t

    type request = private {
      model : model;
      file : Eta_ai.Audio.upload;
      prompt : string option;
      response_format : response_format option;
      temperature : float option;
      stream : bool option;
      include_ : include_item list;
      timestamp_granularities : timestamp_granularity list;
      chunking_strategy : chunking_strategy option;
      known_speaker_names : string list;
      known_speaker_references : string list;
      keywords : string list;
      language : string option;
      languages : string list;
      extra_fields : (string * string) list;
    }

    type token_logprob = {
      token : string option;
      bytes : int list option;
      logprob : float option;
      raw : Eta_ai.Json.t;
    }

    type token_details = {
      audio_tokens : int option;
      text_tokens : int option;
      raw : Eta_ai.Json.t;
    }

    type usage =
      | Tokens of {
          input_tokens : int;
          output_tokens : int;
          total_tokens : int;
          input_token_details : token_details option;
          output_token_details : token_details option;
          raw : Eta_ai.Json.t;
        }
      | Duration of {
          seconds : float;
          raw : Eta_ai.Json.t;
        }

    type language = {
      code : string;
      raw : Eta_ai.Json.t;
    }

    type segment = {
      id : int;
      seek : int;
      start : float;
      end_ : float;
      text : string;
      tokens : int list;
      temperature : float;
      avg_logprob : float;
      compression_ratio : float;
      no_speech_prob : float;
      raw : Eta_ai.Json.t;
    }

    type word = {
      word : string;
      start : float;
      end_ : float;
      raw : Eta_ai.Json.t;
    }

    type diarized_segment = {
      id : string;
      speaker : string;
      start : float;
      end_ : float;
      text : string;
      type_ : string;
      raw : Eta_ai.Json.t;
    }

    type json_result = {
      text : string;
      languages : language list option;
      logprobs : token_logprob list option;
      usage : usage option;
      raw : Eta_ai.Json.t;
    }

    type verbose_result = {
      text : string;
      language : string;
      duration : float;
      segments : segment list option;
      words : word list option;
      usage : usage option;
      raw : Eta_ai.Json.t;
    }

    type diarized_result = {
      text : string;
      duration : float;
      task : string;
      usage : usage option;
      segments : diarized_segment list;
      raw : Eta_ai.Json.t;
    }

    type result =
      | Json_result of json_result
      | Text_result of string
      | Srt_result of string
      | Verbose_json_result of verbose_result
      | Vtt_result of string
      | Diarized_json_result of diarized_result
      | Other_result of {
          format : string;
          body : string;
        }

    type event =
      | Text_delta of {
          delta : string;
          logprobs : token_logprob list option;
          segment_id : string option;
          raw : Eta_ai.Json.t;
        }
      | Text_segment of diarized_segment
      | Text_done of {
          text : string;
          logprobs : token_logprob list option;
          usage : usage option;
          languages : language list option;
          raw : Eta_ai.Json.t;
        }
      | Unknown of {
          type_ : string;
          raw : Eta_ai.Json.t;
        }

    type configuration = {
      model : model;
      prompt : string option;
      response_format : response_format option;
      temperature : float option;
      stream : bool option;
      include_ : include_item list;
      timestamp_granularities : timestamp_granularity list;
      chunking_strategy : chunking_strategy option;
      known_speaker_names : string list;
      known_speaker_references : string list;
      keywords : string list;
      languages : string list;
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

    val model_to_string : model -> string
    val response_format_to_string : response_format -> string

    val request :
      model:model ->
      file:Eta_ai.Audio.upload ->
      ?prompt:string ->
      ?response_format:response_format ->
      ?temperature:float ->
      ?stream:bool ->
      ?include_:include_item list ->
      ?timestamp_granularities:timestamp_granularity list ->
      ?chunking_strategy:chunking_strategy ->
      ?known_speaker_names:string list ->
      ?known_speaker_references:string list ->
      ?keywords:string list ->
      ?language:string ->
      ?languages:string list ->
      ?extra_fields:(string * string) list ->
      unit ->
      (request, Error.t) Stdlib.result

    val decode_response :
      response_format option -> string -> (result, Error.t) Stdlib.result

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

    type event_stream

    val default_max_buffer_bytes : int
    val default_max_json_bytes : int
    val default_max_pending_events : int

    val stream_events :
      ?max_buffer_bytes:int ->
      ?max_json_bytes:int ->
      ?max_pending_events:int ->
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (event_stream, Error.t) Eta.Effect.t

    val read_event : event_stream -> (event option, Error.t) Eta.Effect.t
    val close_events : event_stream -> (unit, Error.t) Eta.Effect.t
  end

  module Translation : sig
    type response_format =
      | Json
      | Text
      | Srt
      | Verbose_json
      | Vtt
      | Other_format of string

    type request = private {
      file : Eta_ai.Audio.upload;
      prompt : string option;
      response_format : response_format option;
      temperature : float option;
      extra_fields : (string * string) list;
    }

    type segment = Speech_to_text.segment = {
      id : int;
      seek : int;
      start : float;
      end_ : float;
      text : string;
      tokens : int list;
      temperature : float;
      avg_logprob : float;
      compression_ratio : float;
      no_speech_prob : float;
      raw : Eta_ai.Json.t;
    }

    type result =
      | Json_result of {
          text : string;
          raw : Eta_ai.Json.t;
        }
      | Text_result of string
      | Srt_result of string
      | Verbose_json_result of {
          language : string;
          duration : float;
          text : string;
          segments : segment list option;
          raw : Eta_ai.Json.t;
        }
      | Vtt_result of string
      | Other_result of {
          format : string;
          body : string;
        }

    val request :
      file:Eta_ai.Audio.upload ->
      ?prompt:string ->
      ?response_format:response_format ->
      ?temperature:float ->
      ?extra_fields:(string * string) list ->
      unit ->
      (request, Error.t) Stdlib.result

    val decode_response :
      response_format option -> string -> (result, Error.t) Stdlib.result

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
  ?provider:Eta_ai.provider ->
  Chat.request ->
  (Eta_ai.raw_json, Error.t) result

val encode_responses :
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.raw_json, Error.t) result

val decode_chat : Eta_ai.raw_json -> (Chat.response, Error.t) result
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
  Chat.request ->
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
  Chat.request ->
  (Chat.response, Error.t) Eta.Effect.t

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
  Chat.request ->
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
