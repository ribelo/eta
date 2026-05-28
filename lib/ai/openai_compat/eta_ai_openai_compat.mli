(** OpenAI-compatible provider package for eta-ai.

    This package owns the configurable OpenAI-compatible Chat Completions
    profile: provider base URL, path, auth policy, extra headers, and local
    OpenAI-style codecs. *)

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
  (structured_output, Eta_ai.ai_error) result

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
(** Build an OpenAI-compatible Chat Completions provider value. *)

module Chat : sig
  include Eta_ai.Provider.Chat

  val chat_completions_request :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val chat_completions :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream_chat_completions :
    ?structured_output:structured_output ->
    provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Embeddings : sig
  include Eta_ai.Provider.Embeddings
end

val encode_chat :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

val chat_completions_request :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
