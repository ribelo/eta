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

type content =
  | Text of string
  | Json of raw_json
  | Audio of audio

val audio_pcm16_base64 : ?transcript:string -> string -> content
(** Build PCM16 audio content from provider-ready base64 data. *)

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

type embedding_request = {
  embedding_model : model;
  encoding_format : string option;
}

type embedding_usage = {
  embedding_input_tokens : int option;
  embedding_raw : (string * string) list;
}

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
}

type provider = {
  name : provider_name;
  base_url : string;
  chat_path : string;
  auth_headers : api_key -> headers;
  capabilities : capabilities;
  encode_chat : chat_request -> (raw_json, ai_error) result;
  decode_chat : raw_json -> (response, ai_error) result;
  decode_stream_event : sse_event -> (stream_event list, ai_error) result;
  decode_error : status:int -> headers:headers -> raw_json -> ai_error;
}

val provider_request :
  provider -> api_key -> raw_json -> Eta_http.Request.t
(** Build the standard POST request for a provider chat endpoint. *)

val perform_chat :
  provider ->
  Eta_http.Client.t ->
  Eta_http.Request.t ->
  (response, ai_error) Eta.Effect.t
(** Submit a provider request and decode a non-streaming response. *)

type stream
(** Pull parser for provider SSE events over an eta-http response body.

    This is intentionally not an eta-stream value. A2 found that eta-stream
    still needs an owned effect-reader source before eta-ai can expose public
    stream ownership through eta-stream. *)

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
  ?usage:embedding_usage ->
  provider ->
  embedding_request ->
  ('a, ai_error) Eta.Effect.t ->
  ('a, ai_error) Eta.Effect.t
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
