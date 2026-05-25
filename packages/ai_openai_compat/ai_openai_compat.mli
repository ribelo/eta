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

type structured_output = Ai_openai_codec.structured_output = {
  name : string;
  schema : Ai.Json.t;
  strict : bool option;
}

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Ai.raw_json ->
  unit ->
  (structured_output, Ai.ai_error) result

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
  ?extra_headers:Ai.headers ->
  base_url:string ->
  unit ->
  Ai.provider
(** Build an OpenAI-compatible Chat Completions provider value. *)

val encode_chat :
  ?structured_output:structured_output ->
  Ai.chat_request ->
  (Ai.raw_json, Ai.ai_error) result

val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
val decode_stream_event :
  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
val decode_error :
  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error

val chat_completions_request :
  ?structured_output:structured_output ->
  provider:Ai.provider ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Http.Request.t, Ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.response, Ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  provider:Ai.provider ->
  Http.Client.t ->
  api_key:Ai.api_key ->
  Ai.chat_request ->
  (Ai.stream, Ai.ai_error) Eta.Effect.t
