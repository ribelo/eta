(** Eio WebSocket transport for OpenAI Realtime. *)

type realtime_error = Eta_http_eio.Ws.Client.ws_error
type t

val connect :
  ?base_url:string ->
  ?safety_identifier:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  model:string ->
  unit ->
  (t, realtime_error) Eta.Effect.t

val send_event :
  t ->
  Eta_ai_openai.Realtime.client_event ->
  (unit, realtime_error) Eta.Effect.t

val events :
  t ->
  (Eta_ai_openai.Realtime.server_event, realtime_error) Eta_stream.Stream.t

val close : t -> (unit, realtime_error) Eta.Effect.t
