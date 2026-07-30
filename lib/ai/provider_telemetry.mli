(** Shared provider inference, embedding, and tool telemetry.

    This module owns the typed-error GenAI span authoring surface used by
    nominal provider packages. Historical neutral [ai_error] helpers remain
    available for unmigrated callers. *)

open Types

type 'err error_view = {
  error_type : 'err -> string;
  error_pp : Format.formatter -> 'err -> unit;
}
(** Typed error classification/formatting view for provider spans. *)

val ai_error_view : ai_error error_view
(** Default view preserving historical [ai_error] classification. *)

val with_chat_span :
  error_view:'err error_view ->
  provider ->
  chat_request ->
  (response, 'err) Eta.Effect.t ->
  (response, 'err) Eta.Effect.t
(** Records provider/model/server attributes, response id/model, finish reasons,
    and usage. Annotates [error.type] from [error_view]. *)

val with_stream_span :
  error_view:'err error_view ->
  ?time_to_first_chunk_s:float ->
  provider ->
  chat_request ->
  ('a, 'err) Eta.Effect.t ->
  ('a, 'err) Eta.Effect.t
(** Always records [gen_ai.request.stream=true]. *)

val with_responses_span :
  error_view:'err error_view ->
  provider ->
  'tool Responses.request ->
  (response, 'err) Eta.Effect.t ->
  (response, 'err) Eta.Effect.t

val with_responses_stream_span :
  error_view:'err error_view ->
  ?time_to_first_chunk_s:float ->
  provider ->
  'tool Responses.request ->
  ('a, 'err) Eta.Effect.t ->
  ('a, 'err) Eta.Effect.t

val with_embeddings_span :
  error_view:'err error_view ->
  provider ->
  Embedding.request ->
  (Embedding.response, 'err) Eta.Effect.t ->
  (Embedding.response, 'err) Eta.Effect.t
(** Records request encoding format and response usage. *)

val with_tool_span :
  error_view:'err error_view ->
  ?tool_call_id:string ->
  ?tool_type:string ->
  tool_name:string ->
  ('a, 'err) Eta.Effect.t ->
  ('a, 'err) Eta.Effect.t
