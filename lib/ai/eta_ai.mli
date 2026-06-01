(** Core eta-ai vocabulary.

    This package owns the common AI request/response types. Provider packages
    own provider-specific encoding and decoding. Applications own state. *)

type raw_json = string
(** Provider JSON carried as UTF-8 text. eta-ai v1 keeps tool schemas raw until
    eta-schema gains JSON Eta_schema export. *)

module Json : sig
  type t = Yojson.Safe.t

  val parse : raw_json -> (t, string) result
  val to_string : t -> raw_json
  val compact : t -> raw_json
  val string : string -> t
  val bool : bool -> t
  val int : int -> t
  val float : float -> t option
  val array : t list -> t
  val object_ : (string * t option) list -> t
  val member : string -> t -> t option
  val string_member : string -> t -> string option
  val scalar_string_member : string -> t -> string option
  val int_member : string -> t -> int option
  val array_member : string -> t -> t list option
  val object_member : string -> t -> t option
end
(** Small Yojson-backed helper surface for provider codecs. *)

type headers = Eta_http.Core.Header.t
type api_key = string Eta_redacted.t
val api_key : string -> api_key
(** Wrap a provider key with the standard eta-ai redaction label. *)

type model = string
type provider_name = string

type audio_format = Pcm16 | G711_alaw | G711_ulaw | Mp3 | Opus | Wav

type audio_data = Base64 of string | Bytes of bytes

type audio = {
  data : audio_data;
  format : audio_format;
  transcript : string option;
}

type media = {
  url : string;
  detail : string option;
}

type content =
  | Text of string
  | Json of raw_json
  | Image of media
  | Audio of audio
  | Video of media

val audio_pcm16_base64 : ?transcript:string -> string -> content
(** Build PCM16 audio content from provider-ready base64 data. *)

val url : ?detail:string -> string -> content
(** Build image content from a provider-ready URL or data URL. *)

val video_url : ?detail:string -> string -> content
(** Build video content from a provider-ready URL or data URL. *)

type tool_call = {
  id : string;
  name : string;
  arguments_json : raw_json;
}

type message =
  | System of string
  | User of content list
  | Assistant of {
      content : content list;
      tool_calls : tool_call list;
    }
  | Tool of {
      tool_call_id : string;
      content : content list;
    }

type prompt = message list

type finish_reason =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string

type usage = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  raw : (string * string) list;
}

type response = {
  id : string option;
  model : model option;
  message : message;
  finish_reasons : finish_reason list;
  usage : usage option;
  raw : raw_json option;
}

type tool = {
  name : string;
  description : string option;
  input_schema_json : raw_json;
  strict : bool option;
}

type chat_request = {
  model : model;
  prompt : prompt;
  tools : tool list;
  temperature : float option;
  max_output_tokens : int option;
  stream : bool;
}

type binary_file = {
  filename : string;
  content_type : string;
  data : bytes;
}

module Embedding : sig
  type input =
    | Text of string
    | Texts of string list
    | Tokens of int list
    | Token_batches of int list list
    | Raw_json of raw_json

  type request = {
    model : model;
    input : input;
    encoding_format : string option;
    dimensions : int option;
    user : string option;
  }

  type vector =
    | Float of float list
    | Base64 of string

  type item = {
    embedding : vector;
    index : int option;
  }

  type usage = {
    input_tokens : int option;
    total_tokens : int option;
    raw : (string * string) list;
  }

  type response = {
    id : string option;
    model : model option;
    embeddings : item list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Image : sig
  type generated = {
    url : string option;
    base64 : string option;
    revised_prompt : string option;
  }

  type request = {
    model : model option;
    prompt : string;
    n : int option;
    size : string option;
    quality : string option;
    response_format : string option;
    user : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    created : int option;
    images : generated list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Speech : sig
  type request = {
    model : model;
    input : string;
    voice : string;
    response_format : string option;
    speed : float option;
    instructions : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    content_type : string option;
    audio : bytes;
  }
end

module Transcription : sig
  type request = {
    model : model;
    file : binary_file;
    language : string option;
    prompt : string option;
    response_format : string option;
    temperature : float option;
    extra_fields : (string * string) list;
  }

  type response = {
    text : string option;
    usage : usage option;
    raw : raw_json option;
  }
end

module Rerank : sig
  type request = {
    model : model;
    query : string;
    documents : string list;
    top_n : int option;
  }

  type result = {
    index : int;
    score : float option;
    document : string option;
  }

  type response = {
    id : string option;
    model : model option;
    provider : string option;
    results : result list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Video : sig
  type request = {
    model : model;
    prompt : string;
    aspect_ratio : string option;
    duration : int option;
    resolution : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    id : string;
    generation_id : string option;
    status : string option;
    polling_url : string option;
    urls : string list;
    error : string option;
    usage : usage option;
    raw : raw_json option;
  }

  type content_request = {
    job_id : string;
    index : int option;
  }

  type content = {
    content_type : string option;
    bytes : bytes;
  }
end

type ai_error =
  | Eta_http_error of Eta_http.Error.t
  | Provider_error of {
      provider : provider_name;
      status : int option;
      code : string option;
      message : string;
      raw : raw_json option;
    }
  | Decode_error of {
      provider : provider_name;
      message : string;
      raw : raw_json option;
    }
  | Invalid_tool of {
      name : string;
      message : string;
    }
  | Unsupported of {
      provider : provider_name;
      feature : string;
    }

module Json_helpers : sig
  val decode_error_result :
    ?raw:raw_json -> provider:provider_name -> string -> ('a, ai_error) result

  val parse_json : provider:provider_name -> raw_json -> (Json.t, ai_error) result

  val schema_value :
    provider:provider_name -> string -> raw_json -> (Json.t, ai_error) result

  val result_all : ('a, 'err) result list -> ('a list, 'err) result
end

type toolkit
(** Ordered registry of provider tools. v1 stores caller-supplied raw JSON
    schemas; eta-schema integration waits for JSON Eta_schema export. *)

val make_tool :
  ?description:string ->
  ?strict:bool ->
  name:string ->
  input_schema_json:raw_json ->
  unit ->
  (tool, ai_error) result
(** Build one tool after registry-level validation. This trims the stored tool
    name and checks only eta-ai invariants such as non-empty name and schema
    text. It does not validate JSON Eta_schema. *)

val empty_toolkit : toolkit
val make_toolkit : tool list -> (toolkit, ai_error) result
val add_tool : tool -> toolkit -> (toolkit, ai_error) result
val find_tool : string -> toolkit -> tool option
val toolkit_tools : toolkit -> tool list
(** Return tools in registration order. *)

type sse_event = {
  event : string option;
  data : raw_json;
}

type tool_call_delta = {
  index : int option;
  id : string option;
  name : string option;
  arguments_json_delta : string;
}

type stream_event =
  | Stream_message_start of {
      id : string option;
      model : model option;
      raw : raw_json option;
    }
  | Stream_content_delta of string
  | Stream_tool_call_delta of tool_call_delta
  | Stream_finish of finish_reason list
  | Stream_error of ai_error
  | Stream_done

type capabilities = {
  streaming : bool;
  tools : bool;
  tool_choice : bool;
  structured_outputs : bool;
  text : bool;
  image_input : bool;
  audio_input : bool;
  video_input : bool;
  embeddings : bool;
  image_generation : bool;
  speech : bool;
  transcription : bool;
  rerank : bool;
  video_generation : bool;
}

type provider = {
  name : provider_name;
  base_url : string;
  chat_path : string;
  embeddings_path : string option;
  auth_headers : api_key -> headers;
  capabilities : capabilities;
  encode_chat : chat_request -> (raw_json, ai_error) result;
  decode_chat : raw_json -> (response, ai_error) result;
  encode_embeddings : Embedding.request -> (raw_json, ai_error) result;
  decode_embeddings : raw_json -> (Embedding.response, ai_error) result;
  decode_stream_event : sse_event -> (stream_event list, ai_error) result;
  decode_error : status:int -> headers:headers -> raw_json -> ai_error;
}

val provider_request :
  provider -> api_key -> raw_json -> Eta_http.Request.t
(** Build the standard POST request for a provider chat endpoint. *)

val provider_post_request :
  provider -> path:string -> api_key -> raw_json -> Eta_http.Request.t
(** Build a standard JSON POST request for a provider endpoint path. *)

val provider_get_request :
  provider -> path:string -> api_key -> Eta_http.Request.t
(** Build a standard GET request for a provider endpoint path. *)

val provider_embeddings_request :
  provider -> api_key -> raw_json -> (Eta_http.Request.t, ai_error) result
(** Build the standard POST request for a provider embeddings endpoint. *)

val embeddings_request :
  provider ->
  api_key:api_key ->
  Embedding.request ->
  (Eta_http.Request.t, ai_error) result
(** Encode and build a provider embeddings request. *)

val post_request :
  provider ->
  path:string ->
  api_key:api_key ->
  ('a -> (raw_json, ai_error) result) ->
  'a ->
  (Eta_http.Request.t, ai_error) result
(** Encode and build a JSON POST request for a provider endpoint path. *)

val get_request :
  provider ->
  path:string ->
  api_key:api_key ->
  (Eta_http.Request.t, ai_error) result
(** Build a GET request for a provider endpoint path. *)

val chat_request_from_raw :
  provider ->
  api_key:api_key ->
  (raw_json, ai_error) result ->
  (Eta_http.Request.t, ai_error) result
(** Build a provider chat request from an already encoded JSON result. *)

val chat_request :
  provider ->
  api_key:api_key ->
  ('a -> (raw_json, ai_error) result) ->
  'a ->
  (Eta_http.Request.t, ai_error) result
(** Encode and build a provider chat request. *)

val embeddings_request_with :
  provider ->
  api_key:api_key ->
  ('a -> (raw_json, ai_error) result) ->
  'a ->
  (Eta_http.Request.t, ai_error) result
(** Encode and build a provider embeddings request with endpoint-specific
    encoding options. *)

val run_request :
  (Eta_http.Request.t, ai_error) result ->
  (Eta_http.Request.t -> ('a, ai_error) Eta.Effect.t) ->
  ('a, ai_error) Eta.Effect.t
(** Lift request-construction failures into an effect, otherwise perform the
    request. *)

val perform_chat :
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (response, ai_error) Eta.Effect.t
(** Submit a provider request and decode a non-streaming response. *)

val perform_embeddings :
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (Embedding.response, ai_error) Eta.Effect.t
(** Submit a provider request and decode an embeddings response. *)

val perform_raw :
  ?max_bytes:int ->
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (raw_json, ai_error) Eta.Effect.t
(** Submit a provider request and return a successful response body as text. *)

val perform_binary :
  ?max_bytes:int ->
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (bytes * headers, ai_error) Eta.Effect.t
(** Submit a provider request and return a successful response body with
    headers. *)

type stream
(** Pull parser for provider SSE events over an eta-http response body.

    This is intentionally not an eta-stream value: provider streams own HTTP
    body release ordering and decode-error cleanup directly. Eta-stream should
    only become the public carrier once it has an owned effect-reader source
    with the same lifecycle guarantees.

    A stream permits one active read or close operation at a time. Concurrent
    calls fail with [Decode_error] instead of racing the parser state. *)

val stream_of_body :
  ?max_buffer_bytes:int -> provider -> Eta_http.Body.Stream.t -> stream
(** Create a pull parser. [max_buffer_bytes] bounds the unframed SSE buffer and
    each complete SSE record before provider decoding. It defaults to 1 MiB. *)

val perform_stream :
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (stream, ai_error) Eta.Effect.t
(** Submit a provider request and return a provider SSE stream for 2xx
    responses. *)

val run_chat_request :
  provider ->
  Eta_http.Client.t ->
  chat_request ->
  (Eta_http.Request.t, ai_error) result ->
  (response, ai_error) Eta.Effect.t
(** Run a built chat request under the standard provider chat span. *)

val run_stream_request :
  provider ->
  Eta_http.Client.t ->
  chat_request ->
  (Eta_http.Request.t, ai_error) result ->
  (stream, ai_error) Eta.Effect.t
(** Run a built streaming chat request under the standard provider stream span. *)

val run_embeddings_request :
  provider ->
  Eta_http.Client.t ->
  Embedding.request ->
  (Eta_http.Request.t, ai_error) result ->
  (Embedding.response, ai_error) Eta.Effect.t
(** Run a built embeddings request under the standard provider embeddings span. *)

val run_raw_decoded :
  provider ->
  Eta_http.Client.t ->
  (Eta_http.Request.t, ai_error) result ->
  (raw_json -> ('a, ai_error) result) ->
  ('a, ai_error) Eta.Effect.t
(** Run a built request, read a successful text body, and decode it. *)

val run_binary_decoded :
  ?max_bytes:int ->
  provider ->
  Eta_http.Client.t ->
  (Eta_http.Request.t, ai_error) result ->
  (bytes * headers -> 'a) ->
  ('a, ai_error) Eta.Effect.t
(** Run a built request, read a successful binary body, and decode it. *)

val read_stream_event : stream -> (stream_event option, ai_error) Eta.Effect.t
(** Read the next decoded provider stream event, or [None] after EOF. *)

val read_stream_events :
  ?max_events:int -> stream -> (stream_event list, ai_error) Eta.Effect.t
(** Read events until EOF or [max_events]. When [max_events] is reached, the
    underlying body is discarded. *)

val close_stream : stream -> (unit, ai_error) Eta.Effect.t
(** Discard the underlying body. Safe to call more than once. *)

val with_chat_span :
  provider ->
  chat_request ->
  (response, ai_error) Eta.Effect.t ->
  (response, ai_error) Eta.Effect.t
(** Wrap a non-streaming chat effect in an OTel GenAI client span. Sensitive
    prompt and output content are not recorded. *)

val with_stream_span :
  ?time_to_first_chunk_s:float ->
  provider ->
  chat_request ->
  ('a, ai_error) Eta.Effect.t ->
  ('a, ai_error) Eta.Effect.t
(** Wrap a streaming chat effect in an OTel GenAI client span. *)

val with_embeddings_span :
  provider ->
  Embedding.request ->
  (Embedding.response, ai_error) Eta.Effect.t ->
  (Embedding.response, ai_error) Eta.Effect.t
(** Wrap an embeddings effect in an OTel GenAI client span. *)

val with_tool_span :
  ?tool_call_id:string ->
  ?tool_type:string ->
  tool_name:string ->
  ('a, ai_error) Eta.Effect.t ->
  ('a, ai_error) Eta.Effect.t
(** Wrap local tool execution in an OTel GenAI internal span. Sensitive tool
    arguments and results are not recorded. *)

val suppress_provider_transport_observability :
  ('a, 'err) Eta.Effect.t -> ('a, 'err) Eta.Effect.t
(** Suppress nested eta-http transport tracing/logging/metrics inside AI spans.
    Provider packages should use this around their eta-http request subtree by
    default and expose explicit opt-in transport tracing later if needed. *)

module Provider : sig
  module type Chat = sig
    val encode : provider:provider -> chat_request -> (raw_json, ai_error) result
    val decode : provider:provider -> raw_json -> (response, ai_error) result

    val request :
      provider:provider ->
      api_key:api_key ->
      chat_request ->
      (Eta_http.Request.t, ai_error) result

    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      chat_request ->
      (response, ai_error) Eta.Effect.t

    val stream :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      chat_request ->
      (stream, ai_error) Eta.Effect.t
  end

  module type Embeddings = sig
    val encode :
      provider:provider -> Embedding.request -> (raw_json, ai_error) result
    val decode :
      provider:provider -> raw_json -> (Embedding.response, ai_error) result

    val request :
      provider:provider ->
      api_key:api_key ->
      Embedding.request ->
      (Eta_http.Request.t, ai_error) result

    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Embedding.request ->
      (Embedding.response, ai_error) Eta.Effect.t
  end

  module type Images = sig
    val generate :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Image.request ->
      (Image.response, ai_error) Eta.Effect.t
  end

  module type Speech = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Speech.request ->
      (Speech.response, ai_error) Eta.Effect.t
  end

  module type Transcriptions = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Transcription.request ->
      (Transcription.response, ai_error) Eta.Effect.t
  end

  module type Rerank = sig
    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Rerank.request ->
      (Rerank.response, ai_error) Eta.Effect.t
  end

  module type Video = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Video.request ->
      (Video.response, ai_error) Eta.Effect.t

    val get :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      job_id:string ->
      (Video.response, ai_error) Eta.Effect.t

    val content :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Video.content_request ->
      (Video.content, ai_error) Eta.Effect.t
  end

  module Chat : Chat
  module Embeddings : Embeddings
end
