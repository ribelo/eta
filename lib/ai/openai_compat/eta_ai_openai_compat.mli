(** Configurable OpenAI-compatible Chat Completions provider.

    This module is for providers that accept OpenAI-style [/chat/completions]
    JSON. Callers must supply the base URL and may override the path, auth
    header, and extra headers. It does not claim OpenAI-only task endpoints such
    as image generation, speech, or transcription. *)

module Error = Compat_error

type stream
(** Provider-owned stream handle carrying configured identity for nominal
    read/close APIs. *)

type auth = {
  header : string;
  prefix : string option;
}
(** API-key header policy. [prefix] is prepended to the redacted key value when
    present. *)

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
  (structured_output, Error.t) result

val bearer_auth : ?header:string -> unit -> auth
(** Default OpenAI-family bearer auth:
    [Authorization: Bearer <api_key>]. *)

val raw_header_auth : header:string -> unit -> auth
(** Header auth without a prefix. Use for compatible providers that expect the
    API key as the full header value. *)

val provider :
  ?name:string ->
  ?chat_path:string ->
  ?auth:auth ->
  ?extra_headers:Eta_ai.headers ->
  base_url:string ->
  unit ->
  Eta_ai.provider
(** Build an OpenAI-compatible Chat Completions provider value.

    The shared [Eta_ai.provider] record remains neutral ([Eta_ai.ai_error]) so
    generic transport helpers can host it. Prefer the nominal operations below
    for lossless failures. Nominal runners use configured request and
    success/stream decoder callbacks, but decode non-success HTTP responses with
    [Error.decode] so configured identity, status, headers, and raw body remain
    lossless. *)

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

  val chat_completions_request :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Error.t) result

  val chat_completions :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Error.t) Eta.Effect.t

  val stream_chat_completions :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
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

val encode_chat :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider_name ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Error.t) result

val decode_chat :
  ?provider:Eta_ai.provider_name ->
  Eta_ai.raw_json ->
  (Eta_ai.response, Error.t) result

val decode_stream_event :
  ?provider:Eta_ai.provider_name ->
  Eta_ai.sse_event ->
  (Eta_ai.stream_event list, Error.t) result

val decode_error :
  provider:Eta_ai.provider_name ->
  status:int ->
  headers:Eta_ai.headers ->
  Eta_ai.raw_json ->
  Error.t

val chat_completions_request :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Error.t) result

val chat_completions :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Error.t) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (stream, Error.t) Eta.Effect.t

val read_stream_event :
  stream -> (Eta_ai.stream_event option, Error.t) Eta.Effect.t
(** Provider callback failures and embedded neutral [Stream_error] values fail
    through [Error.t] with configured provider identity. The stream closes
    exactly once; cleanup diagnostics are suppressed beneath the primary
    provider failure. *)

val read_stream_events :
  stream -> (Eta_ai.stream_event list, Error.t) Eta.Effect.t
(** Read until normal completion or the first nominal failure, with the same
    cleanup semantics as {!read_stream_event}. *)

val close_stream : stream -> (unit, Error.t) Eta.Effect.t
